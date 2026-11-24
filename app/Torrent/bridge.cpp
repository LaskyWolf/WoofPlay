// WoofPlay's door into libtorrent. Every call catches C++ errors, because they can't cross into Swift.

#include "TorrentNative.h"

#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <set>
#include <sstream>
#include <string>

namespace lt = libtorrent;

struct wp_session {
    lt::session session;
    // Torrents whose files held no video or audio. They're stopped and reported once.
    std::set<std::string> rejected;
    explicit wp_session(lt::settings_pack const &pack) : session(lt::session_params(pack)) {}
};

namespace {

std::string id_of(lt::torrent_handle const &handle) {
    std::ostringstream text;
    text << handle.info_hashes().get_best();
    return text.str();
}

/// Only files the player can open are downloaded. Everything else is skipped.
bool is_media(std::string path) {
    static const std::set<std::string> extensions = {
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ogv", "3gp",
        "mp3", "m4a", "aac", "flac", "opus", "ogg", "wav", "alac", "aiff", "wma", "mka",
    };
    auto dot = path.rfind('.');
    if (dot == std::string::npos) return false;
    std::string extension = path.substr(dot + 1);
    std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
    return extensions.count(extension) > 0;
}

/// Returns how many files are kept.
int keep_media_only(lt::torrent_handle const &handle) {
    auto info = handle.torrent_file();
    if (!info) return 0;
    auto const &files = info->files();
    std::vector<lt::download_priority_t> priorities;
    int kept = 0;
    for (auto index : files.file_range()) {
        bool keep = !files.pad_file_at(index) && is_media(files.file_path(index));
        kept += keep;
        priorities.push_back(keep ? lt::default_priority : lt::dont_download);
    }
    handle.prioritize_files(priorities);
    return kept;
}

void handle_alerts(wp_session *session) {
    std::vector<lt::alert *> alerts;
    session->session.pop_alerts(&alerts);
    for (auto *alert : alerts) {
        if (auto *received = lt::alert_cast<lt::metadata_received_alert>(alert)) {
            if (keep_media_only(received->handle) == 0) {
                session->rejected.insert(id_of(received->handle));
                session->session.remove_torrent(received->handle, lt::session::delete_files);
            }
        } else if (auto *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
            // No uploading once the download is complete.
            finished->handle.unset_flags(lt::torrent_flags::auto_managed);
            finished->handle.pause();
        }
    }
}

void append_json_string(std::string &out, std::string const &text) {
    out += '"';
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char escaped[8];
                std::snprintf(escaped, sizeof escaped, "\\u%04x", c);
                out += escaped;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    out += '"';
}

int copy_out(std::string const &text, char *out, int out_len) {
    if (out && out_len > 0) {
        auto count = std::min(static_cast<size_t>(out_len - 1), text.size());
        std::memcpy(out, text.data(), count);
        out[count] = 0;
    }
    return static_cast<int>(text.size());
}

} // namespace

extern "C" {

wp_session *wp_session_create(void) {
    try {
        lt::settings_pack pack;
        pack.set_int(lt::settings_pack::alert_mask,
                     lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage);
        // Only encrypted connections, both ways, with the stream fully encrypted.
        pack.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_forced);
        pack.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_forced);
        pack.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_rc4);
        pack.set_bool(lt::settings_pack::prefer_rc4, true);
        // No opening ports on the router and no announcing on the local network.
        pack.set_bool(lt::settings_pack::enable_upnp, false);
        pack.set_bool(lt::settings_pack::enable_natpmp, false);
        pack.set_bool(lt::settings_pack::enable_lsd, false);
        pack.set_str(lt::settings_pack::user_agent, "WoofPlay");
        return new wp_session(pack);
    } catch (...) {
        return nullptr;
    }
}

void wp_session_destroy(wp_session *session) {
    delete session;
}

int wp_add_magnet(wp_session *session, const char *magnet, const char *save_path, char *out, int out_len) {
    try {
        lt::error_code error;
        lt::add_torrent_params params = lt::parse_magnet_uri(magnet, error);
        if (error) {
            copy_out(error.message(), out, out_len);
            return -1;
        }
        params.save_path = save_path;
        auto handle = session->session.add_torrent(std::move(params), error);
        if (error) {
            copy_out(error.message(), out, out_len);
            return -1;
        }
        copy_out(id_of(handle), out, out_len);
        return 0;
    } catch (std::exception const &exception) {
        copy_out(exception.what(), out, out_len);
        return -1;
    } catch (...) {
        copy_out("Unknown error", out, out_len);
        return -1;
    }
}

void wp_remove(wp_session *session, const char *id, int delete_files) {
    try {
        session->rejected.erase(id);
        for (auto const &handle : session->session.get_torrents()) {
            if (id_of(handle) != id) continue;
            session->session.remove_torrent(handle, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
        }
    } catch (...) {
    }
}

int wp_status(wp_session *session, char *out, int out_len) {
    try {
        handle_alerts(session);
        std::string json = "[";
        bool first = true;
        for (auto const &id : session->rejected) {
            if (!first) json += ',';
            first = false;
            json += "{\"id\":";
            append_json_string(json, id);
            json += ",\"state\":\"noMedia\",\"name\":\"\",\"progress\":0,\"rate\":0,\"peers\":0,\"files\":[]}";
        }
        for (auto const &handle : session->session.get_torrents()) {
            auto status = handle.status(lt::torrent_handle::query_name | lt::torrent_handle::query_save_path);
            const char *state = !status.has_metadata ? "metadata"
                              : status.errc ? "error"
                              : status.is_finished ? "finished"
                              : "downloading";
            double progress = status.total_wanted > 0
                ? static_cast<double>(status.total_wanted_done) / static_cast<double>(status.total_wanted) : 0;
            if (!first) json += ',';
            first = false;
            json += "{\"id\":";
            append_json_string(json, id_of(handle));
            json += ",\"state\":\"";
            json += state;
            json += "\",\"name\":";
            append_json_string(json, status.name);
            json += ",\"error\":";
            append_json_string(json, status.errc ? status.errc.message() : "");
            json += ",\"progress\":" + std::to_string(progress);
            json += ",\"rate\":" + std::to_string(status.download_payload_rate);
            json += ",\"peers\":" + std::to_string(status.num_peers);
            // Once finished, the kept files, as full paths.
            json += ",\"files\":[";
            if (status.is_finished && status.has_metadata) {
                auto info = handle.torrent_file();
                auto priorities = handle.get_file_priorities();
                bool first_file = true;
                for (auto index : info->files().file_range()) {
                    auto position = static_cast<size_t>(static_cast<int>(index));
                    if (position >= priorities.size() || priorities[position] == lt::dont_download) continue;
                    if (!first_file) json += ',';
                    first_file = false;
                    append_json_string(json, info->files().file_path(index, status.save_path));
                }
            }
            json += "]}";
        }
        json += "]";
        return copy_out(json, out, out_len);
    } catch (...) {
        return copy_out("[]", out, out_len);
    }
}

}

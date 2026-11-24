#pragma once

// A small C door into libtorrent, so Swift never touches C++.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wp_session wp_session;

wp_session *wp_session_create(void);
void wp_session_destroy(wp_session *session);

/// Starts a magnet link. Returns 0 and writes the torrent's id, or -1 and writes why it failed.
int wp_add_magnet(wp_session *session, const char *magnet, const char *save_path, char *out, int out_len);

/// Stops a torrent. With delete_files, its files on disk go too.
void wp_remove(wp_session *session, const char *id, int delete_files);

/// Writes every torrent's state as a JSON array. Returns the length it needed, like snprintf.
int wp_status(wp_session *session, char *out, int out_len);

#ifdef __cplusplus
}
#endif

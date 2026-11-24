# Torrent engine

`build.sh` compiles libtorrent (pinned commit) and `bridge.cpp` into `TorrentNative.xcframework` for iPhone. CI runs it and caches the result.

Settings in `bridge.cpp`:

- Encrypted connections only, both ways.
- Only video and audio files are downloaded.
- A finished torrent is paused, so it doesn't upload.
- No UPnP, NAT-PMP or local peer discovery.

Peers still see the phone's IP address. Only a VPN hides it.

## Test on a computer

Needs Boost headers, CMake and Ninja. Paths are examples.

```bash
git clone https://github.com/arvidn/libtorrent.git /tmp/lt
git -C /tmp/lt checkout 1eb18faeae156d8dbbab42935c082f8b81f50989
git -C /tmp/lt submodule update --init deps/try_signal
cmake -S app/Torrent -B /tmp/lt-build -G Ninja -DLIBTORRENT_SOURCE_DIR=/tmp/lt -DCMAKE_BUILD_TYPE=Release -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=ON -Ddeprecated-functions=OFF
cmake --build /tmp/lt-build
clang -c -Iapp/Torrent/include app/Torrent/smoke.c -o /tmp/smoke.o
clang++ /tmp/smoke.o /tmp/lt-build/libTorrentNative.a /tmp/lt-build/libtorrent/libtorrent-rasterbar.a -lpthread -o /tmp/smoke
/tmp/smoke 'magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce' /tmp/dl
```

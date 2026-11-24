cmake_minimum_required(VERSION 3.25)
project(TorrentNative LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

add_subdirectory("${LIBTORRENT_SOURCE_DIR}" libtorrent)

# Apple's own SHA-1 and SHA-256, instead of libtorrent's built-in copies.
if(APPLE)
    target_compile_definitions(torrent-rasterbar PUBLIC TORRENT_USE_COMMONCRYPTO)
endif()

add_library(TorrentNative STATIC bridge.cpp)
target_include_directories(TorrentNative PUBLIC include)
target_link_libraries(TorrentNative PRIVATE torrent-rasterbar)

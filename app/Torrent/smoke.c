// Manual check of bridge.cpp on a computer: downloads a magnet and prints the engine's state every 2 seconds.
// Build steps are in README.md next to this file.
#include "TorrentNative.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: smoke <magnet> <folder> [seconds]\n"); return 2; }
    int seconds = argc > 3 ? atoi(argv[3]) : 120;
    wp_session *session = wp_session_create();
    if (!session) { fprintf(stderr, "no session\n"); return 1; }
    char id[256];
    if (wp_add_magnet(session, argv[1], argv[2], id, sizeof id) != 0) { fprintf(stderr, "add failed: %s\n", id); return 1; }
    printf("id %s\n", id);
    static char json[1 << 16];
    for (int tick = 0; tick < seconds / 2; tick++) {
        sleep(2);
        wp_status(session, json, sizeof json);
        printf("%s\n", json);
        if (strstr(json, "\"finished\"") || strstr(json, "\"noMedia\"")) break;
    }
    wp_session_destroy(session);
    return 0;
}

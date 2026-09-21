// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone adapter for UxPlay's libairplay. Never link this into made.
#include "raop.h"
#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <set>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
// Protocol: uint32 network-order body length, uint8 kind, body. No text on stdout.
enum Kind : unsigned char {
    ready = 1, pin = 2, video = 3, stopped = 4, heartbeat = 5, peerActivity = 6, discoveryFailure = 7
};
constexpr size_t maxPacket = 8 * 1024 * 1024;
std::mutex outputLock, keysLock;
std::set<std::string> keys;
std::atomic<bool> disconnected{false};
volatile sig_atomic_t quitting = 0;

void signalHandler(int) { quitting = 1; }

void writeAll(const void *bytes, size_t count) {
    const auto *cursor = static_cast<const unsigned char *>(bytes);
    // A stopped/vanished parent must never wedge receiver threads indefinitely.
    // One deadline for the entire message, including pipe backpressure.
    struct timespec started;
    clock_gettime(CLOCK_MONOTONIC, &started);
    while (count) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - started.tv_sec >= 2) _exit(74);
        ssize_t written = write(STDOUT_FILENO, cursor, count);
        if (written > 0) { cursor += written; count -= written; continue; }
        if (errno != EAGAIN && errno != EINTR) _exit(74);
        struct pollfd descriptor{STDOUT_FILENO, POLLOUT, 0};
        poll(&descriptor, 1, 50);
    }
}

void emit(Kind kind, const void *bytes = nullptr, size_t size = 0) {
    if (size > maxPacket - 1) _exit(65);
    std::lock_guard<std::mutex> lock(outputLock);
    uint32_t length = htonl(static_cast<uint32_t>(size + 1));
    writeAll(&length, sizeof(length));
    writeAll(&kind, 1);
    if (size) writeAll(bytes, size);
}

void noop(void *) {}
int discoveryFailed(int error) {
    const uint32_t code = htonl(static_cast<uint32_t>(error));
    emit(discoveryFailure, &code, sizeof(code));
    return 69;
}
void reset(void *, reset_type_t) { disconnected = true; }
void connectionReset(void *, int) { disconnected = true; }
void videoProcess(void *, raop_ntp_t *, video_decode_struct *frame) {
    if (frame && !frame->is_h265 && frame->data_len > 0)
        emit(video, frame->data, static_cast<size_t>(frame->data_len));
}
void showPIN(void *, char *value) {
    if (value && strnlen(value, 5) == 4) emit(pin, value, 4);
}
void registerClient(void *, const char *, const char *key, const char *) {
    std::lock_guard<std::mutex> lock(keysLock);
    if (key && keys.size() < 8) keys.insert(key);
}
bool checkClient(void *, const char *key) {
    std::lock_guard<std::mutex> lock(keysLock);
    return key && keys.count(key) != 0;
}
} // namespace

int main(int argc, char **argv) {
    // The parent supplies an ephemeral private directory; no global dotfiles.
    if (argc != 4 || strcmp(argv[1], "--receive") || strlen(argv[2]) > 63) return 64;
    umask(077);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK);
    const pid_t parent = getppid();
    char address[6];
    arc4random_buf(address, sizeof(address));
    address[0] = (address[0] | 2) & ~1;
    char identifier[18];
    snprintf(identifier, sizeof(identifier), "%02x:%02x:%02x:%02x:%02x:%02x",
             (unsigned char)address[0], (unsigned char)address[1], (unsigned char)address[2],
             (unsigned char)address[3], (unsigned char)address[4], (unsigned char)address[5]);
    int error = 0;
    dnssd_t *discovery = dnssd_init(argv[2], (int)strlen(argv[2]), address, 6, &error, 1);
    if (!discovery || error) return discoveryFailed(error);
    dnssd_set_airplay_features(discovery, 4, 0); // No HLS player.
    dnssd_set_airplay_features(discovery, 42, 0); // H.264 mirroring only.
    raop_callbacks_t callbacks{};
    callbacks.conn_init = noop;
    callbacks.conn_destroy = noop;
    callbacks.conn_feedback = [](void *) { emit(peerActivity); };
    callbacks.conn_reset = connectionReset;
    callbacks.video_reset = reset;
    callbacks.video_process = videoProcess;
    callbacks.video_pause = noop;
    callbacks.video_resume = noop;
    callbacks.video_flush = noop;
    callbacks.audio_flush = noop;
    callbacks.audio_process = [](void *, raop_ntp_t *, audio_decode_struct *) {};
    callbacks.audio_set_client_volume = [](void *) { return -144.0; };
    callbacks.audio_set_volume = [](void *, float) {};
    callbacks.audio_get_format = [](void *, unsigned char *, unsigned short *, bool *, bool *, uint64_t *) {};
    callbacks.video_report_size = [](void *, float *, float *, float *, float *) {};
    callbacks.report_client_request = [](void *, char *, char *, char *, bool *admit) { *admit = true; };
    callbacks.display_pin = showPIN;
    callbacks.register_client = registerClient;
    callbacks.check_register = checkClient;
    callbacks.passwd = [](void *, int *length) -> const char * { *length = 0; return nullptr; };
    callbacks.video_set_codec = [](void *, video_codec_t codec) { return codec == VIDEO_CODEC_H264 ? 0 : -1; };

    raop_t *server = raop_init(&callbacks);
    if (!server) return 70;
    // Suppress upstream logs (some contain authentication material).
    raop_set_log_callback(server, [](void *, int, const char *) {}, nullptr);
    raop_set_log_level(server, 0);
    if (raop_init2(server, 0, identifier, argv[3])) return 70;
    raop_set_plist(server, "pin", 0); // Fresh random on-screen PIN, never unattended access.
    raop_set_plist(server, "width", 1920);
    raop_set_plist(server, "height", 1080);
    raop_set_plist(server, "maxFPS", 30);
    raop_set_plist(server, "hls", 0);
    unsigned short ports[3] = {0, 0, 0};
    raop_set_tcp_ports(server, ports);
    raop_set_udp_ports(server, ports);
    unsigned short port = 0;
    if (raop_start_httpd(server, &port) < 0) return 71;
    raop_set_port(server, port);
    raop_set_dnssd(server, discovery);
    error = dnssd_register_raop(discovery, port);
    if (!error) error = dnssd_register_airplay(discovery, port);
    if (error) return discoveryFailed(error);
    emit(ready);
    unsigned ticks = 0;
    while (!quitting && !disconnected && getppid() == parent) {
        usleep(100000);
        if (++ticks % 10 == 0) emit(heartbeat);
    }
    emit(stopped);
    dnssd_unregister_airplay(discovery);
    dnssd_unregister_raop(discovery);
    // Avoid library thread joins on shutdown. OS closes sockets and private
    // memory on exit; the parent removes the temporary key and reaps the child.
    _exit(0);
}

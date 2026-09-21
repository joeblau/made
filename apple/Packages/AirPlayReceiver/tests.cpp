// SPDX-License-Identifier: GPL-3.0-or-later
#include <cstddef>
extern "C" {
#include "http_request.h"
}
#include <cassert>
#include <cstring>
#include <string>

// These feed the actual patched libairplay parser, not a copy of its checks.
int main() {
    const std::string fragment(16384, 'x');
    for (const char *prefix : {
             "GET /",
             "POST /info HTTP/1.1\r\nVery-Long-",
             "POST /info HTTP/1.1\r\nName: ",
             "POST /info HTTP/1.1\r\nContent-Length: 16777216\r\n\r\n"}) {
        http_request_t *request = http_request_init();
        assert(request);
        http_request_add_data(request, prefix, static_cast<int>(strlen(prefix)));
        int fragments = 0;
        while (!http_request_has_error(request) && fragments < 514) {
            http_request_add_data(request, fragment.data(), static_cast<int>(fragment.size()));
            ++fragments;
        }
        assert(http_request_has_error(request));
        assert(fragments <= 513);
        http_request_destroy(request);
    }
    http_request_t *request = http_request_init();
    const char *valid = "POST /pair-pin-start RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n";
    // Also exercise split protocol headers as they arrive over TCP.
    for (size_t i = 0; i < strlen(valid); ++i) http_request_add_data(request, valid + i, 1);
    assert(!http_request_has_error(request));
    assert(http_request_is_complete(request));
    assert(strcmp(http_request_get_protocol(request), "RTSP/1.0") == 0);
    http_request_destroy(request);
}

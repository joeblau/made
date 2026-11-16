#import "CBHIDSocket.h"
#import <sys/socket.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>

static const void *CBHIDSocketQueueKey = &CBHIDSocketQueueKey;

static NSError *CBHIDSocketError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"CBHIDSocket" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation CBHIDSocket {
    int _descriptor;
    BOOL _closed;
    dispatch_queue_t _queue;
    dispatch_queue_t _callbackQueue;
    dispatch_source_t _reader;
    void (^_onPacket)(NSData *);
    void (^_onClose)(NSError *);
}

- (instancetype)initWithFileDescriptor:(int)descriptor
                        callbackQueue:(dispatch_queue_t)callbackQueue
                             onPacket:(void (^)(NSData *))onPacket
                              onClose:(void (^)(NSError * _Nullable))onClose
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _descriptor = -1;
    int duplicated = descriptor >= 0 ? dup(descriptor) : -1;
    if (duplicated < 0) {
        if (error) *error = CBHIDSocketError(1, @"CoreBluetooth returned an invalid HID channel socket.");
        return nil;
    }
    int socketType = 0;
    socklen_t size = sizeof(socketType);
    if (getsockopt(duplicated, SOL_SOCKET, SO_TYPE, &socketType, &size) != 0 || socketType != SOCK_STREAM) {
        close(duplicated);
        if (error) *error = CBHIDSocketError(2, @"The Bluetooth HID channel is not a stream socket.");
        return nil;
    }
    int enabled = 1;
    if (setsockopt(duplicated, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
        int savedError = errno;
        close(duplicated);
        if (error) *error = CBHIDSocketError(savedError, @"Could not configure the Bluetooth HID socket.");
        return nil;
    }
    _descriptor = duplicated;
    _callbackQueue = callbackQueue;
    _onPacket = [onPacket copy];
    _onClose = [onClose copy];
    _queue = dispatch_queue_create("app.blau.pilot.phone-hid.socket", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, CBHIDSocketQueueKey, (__bridge void *)self, NULL);
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, duplicated, 0, _queue);
    __weak CBHIDSocket *weakSelf = self;
    dispatch_source_set_event_handler(_reader, ^{ [weakSelf readAvailablePackets]; });
    dispatch_source_set_cancel_handler(_reader, ^{ close(duplicated); });
    dispatch_resume(_reader);
    return self;
}

- (void)dealloc {
    if (_reader) dispatch_source_cancel(_reader);
}

- (void)finishWithError:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    dispatch_source_cancel(_reader);
    void (^callback)(NSError *) = _onClose;
    _onClose = nil;
    _onPacket = nil;
    if (callback) dispatch_async(_callbackQueue, ^{ callback(error); });
}

- (void)close {
    if (!_queue) return;
    void (^work)(void) = ^{ [self finishWithError:nil]; };
    if (dispatch_get_specific(CBHIDSocketQueueKey) == (__bridge void *)self) work();
    else dispatch_sync(_queue, work);
}

- (void)readAvailablePackets {
    uint8_t bytes[UINT16_MAX];
    while (!_closed) {
        ssize_t count = recv(_descriptor, bytes, sizeof(bytes), MSG_DONTWAIT);
        if (count > 0) {
            NSData *packet = [NSData dataWithBytes:bytes length:(NSUInteger)count];
            void (^callback)(NSData *) = _onPacket;
            if (callback) dispatch_async(_callbackQueue, ^{ callback(packet); });
        } else if (count == 0) {
            [self finishWithError:nil];
        } else if (errno == EINTR) {
            continue;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        } else {
            int savedError = errno;
            [self finishWithError:CBHIDSocketError(savedError,
                [NSString stringWithFormat:@"Bluetooth HID read failed: %s", strerror(savedError)])];
        }
    }
}

- (BOOL)writePacket:(NSData *)packet maximumSize:(NSUInteger)maximumSize error:(NSError **)error {
    if (packet.length == 0 || packet.length > UINT16_MAX || (maximumSize > 0 && packet.length > maximumSize)) {
        if (error) *error = CBHIDSocketError(3, @"The HID transaction is empty or exceeds the channel packet limit.");
        return NO;
    }
    __block NSError *failure = nil;
    void (^work)(void) = ^{
        if (self->_closed) {
            failure = CBHIDSocketError(4, @"The Bluetooth HID channel has closed.");
            return;
        }
        struct iovec vector = { .iov_base = (void *)packet.bytes, .iov_len = packet.length };
        struct cmsghdr boundary = { .cmsg_len = sizeof(struct cmsghdr), .cmsg_level = SOL_SOCKET, .cmsg_type = SCM_RIGHTS };
        struct msghdr message = { .msg_iov = &vector, .msg_iovlen = 1,
            .msg_control = &boundary, .msg_controllen = sizeof(boundary) };
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 100 * NSEC_PER_MSEC;
        for (;;) {
            ssize_t count = sendmsg(self->_descriptor, &message, MSG_DONTWAIT);
            if (count == (ssize_t)packet.length) return;
            if (count >= 0) {
                failure = CBHIDSocketError(5, @"Bluetooth accepted only part of a HID transaction.");
                break;
            }
            int savedError = errno;
            if (savedError == EINTR) continue;
            if (savedError != EAGAIN && savedError != EWOULDBLOCK) {
                failure = CBHIDSocketError(savedError,
                    [NSString stringWithFormat:@"Bluetooth HID write failed: %s", strerror(savedError)]);
                break;
            }
            uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            if (now >= deadline) {
                failure = CBHIDSocketError(6, @"Bluetooth HID remained busy past its write deadline.");
                break;
            }
            struct pollfd descriptor = { .fd = self->_descriptor, .events = POLLOUT };
            int timeout = (int)((deadline - now + NSEC_PER_MSEC - 1) / NSEC_PER_MSEC);
            int result = poll(&descriptor, 1, timeout);
            if (result < 0 && errno == EINTR) continue;
            if (result <= 0 || (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                failure = CBHIDSocketError(6, @"Bluetooth HID could not finish writing before the channel deadline.");
                break;
            }
        }
        [self finishWithError:failure];
    };
    if (dispatch_get_specific(CBHIDSocketQueueKey) == (__bridge void *)self) work();
    else dispatch_sync(_queue, work);
    if (error && failure) *error = failure;
    return failure == nil;
}

@end

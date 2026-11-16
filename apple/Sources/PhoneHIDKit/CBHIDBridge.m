#import <PhoneHIDKit/PhoneHIDKit.h>
#import "CBHIDSocket.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <ctype.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>

@interface CBClassicManager : CBManager
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(nullable NSDictionary *)options;
- (unsigned int)addServiceWithData:(NSData *)data;
- (void)removeServiceHandle:(unsigned int)handle;
- (void)removeAllServices;
- (nullable id)getLocalSDPDatabase;
- (nullable id)retrievePeerWithAddress:(NSString *)address;
- (void)connectPeer:(id)peer options:(NSDictionary *)options;
- (void)setBTDiscoverable:(BOOL)discoverable;
- (void)setBTConnectable:(BOOL)connectable;
- (void)performTCCCheck;
- (void)setTccApproved:(BOOL)approved;
- (void)setSdpRecordAddedHandler:(nullable void (^)(id serviceUUID, long errorCode))handler;
- (void)setConnectCallback:(nullable void (^)(id peer, long errorCode))callback;
- (void)setDisconnectCallback:(nullable void (^)(id peer, long errorCode))callback;
@property (nonatomic, readonly) BOOL discoverable;
@property (nonatomic, readonly) BOOL connectable;
@property (nonatomic, readonly) long powerState;
@property (nonatomic, readonly) BOOL tccApproved;
@property (nonatomic, readonly) NSMapTable *peers;
@end

@interface CBClassicPeer : CBPeer
- (void)setConnectL2CAPCallback:(nullable void (^)(id channel, long errorCode))callback;
- (void)setDisconnectL2CAPCallback:(nullable void (^)(id channel, long errorCode))callback;
- (nullable id)channelWithPSM:(unsigned short)psm;
- (void)handleL2CAPChannelOpened:(NSDictionary *)args;
- (void)handleL2CAPChannelClosed:(NSDictionary *)args;
- (void)closeL2CAPChannel:(unsigned short)psm;
- (void)openL2CAPChannel:(unsigned short)psm;
@property (nonatomic, readonly) NSInteger state;
@property (nonatomic, readonly) id manager;
@property (nonatomic, readonly) NSString *addressString;
@property (nonatomic, readonly) NSString *name;
@end

@interface CBL2CAPChannel (ClassicPrivate)
- (void)sendData:(NSData *)data withCompletion:(nullable id)completion;
- (void)setIsPacketBased:(BOOL)packetBased;
@property (nonatomic, readonly) unsigned short outgoingMTU;
@property (nonatomic, readonly) int socketFD;
@end

static const unsigned short kHIDControlPSM = 0x0011;
static const unsigned short kHIDInterruptPSM = 0x0013;

@implementation CBHIDPeerState
@end

@interface CBHIDPeerEntry : NSObject
@property (nonatomic, strong) CBClassicPeer *peer;
@property (nonatomic, strong) CBL2CAPChannel *controlChannel;
@property (nonatomic, strong) CBL2CAPChannel *interruptChannel;
@property (nonatomic, strong) CBHIDSocket *controlSocket;
@property (nonatomic, strong) CBHIDSocket *interruptSocket;
@property (nonatomic, strong) HIDControlSession *session;
@end
@implementation CBHIDPeerEntry
@end

@interface CBHIDConnectionRequest : NSObject
@property (nonatomic, strong) CBClassicPeer *peer;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL controlRequested;
@property (nonatomic) BOOL interruptRequested;
@end
@implementation CBHIDConnectionRequest
@end

@interface CBHIDBridge () <CBCentralManagerDelegate>
- (void)attachChannelCallbacksToPeer:(CBClassicPeer *)peer;
@end

static NSMapTable *CBHIDManagers;
static IMP CBHIDOriginalPeerHandleMsg;
static const void *CBHIDBridgeQueueKey = &CBHIDBridgeQueueKey;
static void CBHIDPeerHandleMsg(CBClassicPeer *peer, SEL selector, int message, NSDictionary *args) {
    CBHIDBridge *bridge;
    @synchronized (CBHIDManagers) { bridge = [CBHIDManagers objectForKey:peer.manager]; }
    unsigned short psm = [args[@"kCBMsgArgPSM"] unsignedShortValue];
    if (bridge && (psm == kHIDControlPSM || psm == kHIDInterruptPSM) && (message == 27 || message == 28)) {
        [bridge attachChannelCallbacksToPeer:peer];
        if (message == 27) [peer handleL2CAPChannelOpened:args];
        else if ([peer channelWithPSM:psm]) [peer handleL2CAPChannelClosed:args];
        return;
    }
    ((void (*)(id, SEL, int, NSDictionary *))CBHIDOriginalPeerHandleMsg)(peer, selector, message, args);
}

static BOOL CBHIDInstallPeerHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class peerClass = NSClassFromString(@"CBClassicPeer");
        Method method = class_getInstanceMethod(peerClass, NSSelectorFromString(@"handleMsg:args:"));
        if (!method || ![peerClass instancesRespondToSelector:@selector(handleL2CAPChannelOpened:)] ||
            ![peerClass instancesRespondToSelector:@selector(handleL2CAPChannelClosed:)]) return;
        CBHIDManagers = [NSMapTable weakToWeakObjectsMapTable];
        CBHIDOriginalPeerHandleMsg = method_setImplementation(method, (IMP)CBHIDPeerHandleMsg);
    });
    return CBHIDOriginalPeerHandleMsg != NULL;
}

@implementation CBHIDBridge {
    CBCentralManager *_central;
    CBClassicManager *_manager;
    dispatch_queue_t _queue;
    BOOL _published;
    NSMutableDictionary<NSString *, CBHIDPeerEntry *> *_entries;
    NSMutableDictionary<NSString *, CBHIDConnectionRequest *> *_connectionRequests;
    NSString *_serviceName;
    NSData *_sdpRecord;
    int _publishAttempts;
}

static NSString *CBHIDNormalizeAddress(NSString *address) {
    NSMutableString *out = [NSMutableString stringWithCapacity:address.length];
    for (NSUInteger i = 0; i < address.length; i++) {
        unichar c = [address characterAtIndex:i];
        if (isalnum(c)) [out appendFormat:@"%c", tolower(c)];
    }
    return out;
}

static NSString *CBHIDExactAddress(NSString *address) {
    NSMutableString *result = [NSMutableString stringWithCapacity:12];
    for (NSUInteger i = 0; i < address.length; i++) {
        unichar c = [address characterAtIndex:i];
        if (c == ':' || c == '-') continue;
        if (c > 127 || !isxdigit((unsigned char)c)) return nil;
        [result appendFormat:@"%c", tolower((unsigned char)c)];
    }
    return result.length == 12 ? result : nil;
}

static NSString *CBHIDFormattedAddress(NSString *address) {
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:6];
    for (NSUInteger i = 0; i < address.length; i += 2)
        [parts addObject:[[address substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
    return [parts componentsJoinedByString:@":"];
}

- (void)log:(NSString *)message {
    if (self.onLog) self.onLog(message);
}

- (BOOL)startWithServiceName:(NSString *)serviceName
               serviceRecord:(NSData *)sdpRecord
                       error:(NSError **)error {
    if (_central) return YES;

    if (!NSClassFromString(@"CBClassicManager")) {
        if (error) *error = [NSError errorWithDomain:@"CBHIDBridge" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"CBClassicManager is unavailable on this system"}];
        return NO;
    }

    if (!CBHIDInstallPeerHook()) {
        if (error) *error = [NSError errorWithDomain:@"CBHIDBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"This macOS version does not provide the required Bluetooth HID channel callbacks."}];
        return NO;
    }
    _queue = dispatch_queue_create("app.blau.pilot.phone-hid", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, CBHIDBridgeQueueKey, (__bridge void *)self, NULL);
    _entries = [NSMutableDictionary dictionary];
    _connectionRequests = [NSMutableDictionary dictionary];
    _serviceName = serviceName;
    _sdpRecord = sdpRecord;

    _central = [[CBCentralManager alloc] initWithDelegate:self queue:_queue];
    return YES;
}

- (void)stop {
    if (!_queue) return;
    void (^work)(void) = ^{ [self stopOnQueue]; };
    if (dispatch_get_specific(CBHIDBridgeQueueKey) == (__bridge void *)self) work();
    else dispatch_sync(_queue, work);
}

- (void)stopOnQueue {
    [_connectionRequests removeAllObjects];
    @synchronized (_entries) {
        for (CBHIDPeerEntry *entry in _entries.allValues) {
            [entry.controlSocket close]; [entry.interruptSocket close];
        }
        [_entries removeAllObjects];
    }
    if (_manager) {
        @synchronized (CBHIDManagers) { [CBHIDManagers removeObjectForKey:_manager]; }
        [_manager removeObserver:self forKeyPath:@"state"];
        [_manager setConnectCallback:nil];
        [_manager setDisconnectCallback:nil];
        [_manager setSdpRecordAddedHandler:nil];
        if (_published) {
            [_manager removeAllServices];
            _published = NO;
        }
        [_manager setBTDiscoverable:NO];
        _manager = nil;
    }
    _central.delegate = nil;
    _central = nil;
    _publishAttempts = 0;
}

- (NSArray<NSString *> *)connectedPeerAddresses {
    if (!_queue) return @[];
    NSMutableArray *addresses = [NSMutableArray array];
    void (^work)(void) = ^{
        for (NSString *key in self->_entries) {
            CBHIDPeerEntry *entry = self->_entries[key];
            if (entry.controlSocket && entry.interruptSocket) [addresses addObject:key];
        }
    };
    if (dispatch_get_specific(CBHIDBridgeQueueKey) == (__bridge void *)self) work();
    else dispatch_sync(_queue, work);
    return addresses;
}

- (BOOL)sendReport:(NSData *)report toPeerWithAddress:(NSString *)address error:(NSError **)error {
    __block BOOL sent = NO;
    __block NSError *failure = nil;
    void (^work)(void) = ^{
        CBHIDPeerEntry *entry = self->_entries[CBHIDNormalizeAddress(address)];
        if (!entry.controlSocket || !entry.interruptSocket || entry.session.suspended) {
            failure = [NSError errorWithDomain:@"CBHIDBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The phone's Bluetooth control channels are not ready."}];
            return;
        }
        sent = [entry.interruptSocket writePacket:report maximumSize:entry.interruptChannel.outgoingMTU error:&failure];
        if (sent) [entry.session recordInput:report];
    };
    if (_queue) {
        if (dispatch_get_specific(CBHIDBridgeQueueKey) == (__bridge void *)self) work();
        else dispatch_sync(_queue, work);
    }
    if (!sent && error) *error = failure ?: [NSError errorWithDomain:@"CBHIDBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Bluetooth has not started."}];
    return sent;
}

- (void)disconnectPeerWithAddress:(NSString *)address {
    if (!_queue) return;
    dispatch_async(_queue, ^{
        NSString *key = CBHIDNormalizeAddress(address);
        [self->_connectionRequests removeObjectForKey:key];
        CBHIDPeerEntry *entry = self->_entries[key];
        [entry.peer closeL2CAPChannel:kHIDInterruptPSM];
        [entry.peer closeL2CAPChannel:kHIDControlPSM];
        [entry.interruptSocket close]; [entry.controlSocket close];
        [self->_entries removeObjectForKey:key];
        if (self.onPeerDisconnected) self.onPeerDisconnected(key);
    });
}

#pragma mark - Explicit bonded-peer reconnect

- (void)requestConnectionToPeerWithAddress:(NSString *)address {
    NSString *key = CBHIDExactAddress(address);
    if (!key || !_queue) {
        if (self.onConnectionFailed) self.onConnectionFailed(key ?: CBHIDNormalizeAddress(address),
            [NSError errorWithDomain:@"CBHIDBridge" code:5 userInfo:@{NSLocalizedDescriptionKey:
                key ? @"Bluetooth has not started." : @"This device does not have a valid saved Bluetooth address. Select the phone in Bluetooth discovery again."}]);
        return;
    }
    dispatch_async(_queue, ^{
        CBHIDPeerEntry *entry = self->_entries[key];
        if (entry.controlSocket && entry.interruptSocket) {
            [self notifyChannelsForAddress:key];
            return;
        }
        if (self->_connectionRequests[key]) return;
        self->_connectionRequests[key] = [CBHIDConnectionRequest new];
        [self startConnectionRequestsWhenReady];
    });
}

- (void)cancelConnectionRequestWithAddress:(NSString *)address {
    if (!_queue) return;
    dispatch_async(_queue, ^{ [self cancelConnectionRequestOnQueue:CBHIDNormalizeAddress(address)]; });
}

- (void)cancelConnectionRequestOnQueue:(NSString *)address {
    CBHIDConnectionRequest *request = _connectionRequests[address];
    if (!request) return;
    [_connectionRequests removeObjectForKey:address];
    CBHIDPeerEntry *entry = _entries[address];
    if (entry.controlSocket && entry.interruptSocket) return;
    if (request.interruptRequested) [request.peer closeL2CAPChannel:kHIDInterruptPSM];
    if (request.controlRequested) [request.peer closeL2CAPChannel:kHIDControlPSM];
}

- (void)failConnectionRequest:(NSString *)address code:(NSInteger)code message:(NSString *)message {
    if (!_connectionRequests[address]) return;
    [self cancelConnectionRequestOnQueue:address];
    [self log:message];
    if (self.onConnectionFailed) self.onConnectionFailed(address,
        [NSError errorWithDomain:@"CBHIDBridge" code:code userInfo:@{NSLocalizedDescriptionKey:message}]);
}

- (BOOL)isBondedAddress:(NSString *)address {
    return [[IOBluetoothDevice deviceWithAddressString:CBHIDFormattedAddress(address)] isPaired];
}

- (void)startConnectionRequestsWhenReady {
    if (!_published || !_manager || _manager.state != CBManagerStatePoweredOn) return;
    for (NSString *address in _connectionRequests.allKeys) {
        CBHIDConnectionRequest *request = _connectionRequests[address];
        if (request.started) continue;
        request.started = YES;
        if (![self isBondedAddress:address]) {
            [self failConnectionRequest:address code:6 message:@"The selected phone is no longer paired with this Mac. Pair it from Bluetooth discovery before reconnecting."];
            continue;
        }
        if (![_manager respondsToSelector:@selector(retrievePeerWithAddress:)] ||
            ![_manager respondsToSelector:@selector(connectPeer:options:)]) {
            [self failConnectionRequest:address code:7 message:@"This macOS version cannot initiate a Bluetooth HID reconnect. Connect to this Mac from the phone's AssistiveTouch device list."];
            continue;
        }
        CBClassicPeer *peer = [_manager retrievePeerWithAddress:CBHIDFormattedAddress(address)];
        if (!peer || ![CBHIDExactAddress(peer.addressString) isEqualToString:address]) {
            [self failConnectionRequest:address code:8 message:@"macOS could not retrieve the selected paired phone. Reconnect it from the phone's AssistiveTouch device list."];
            continue;
        }
        if (![peer respondsToSelector:@selector(openL2CAPChannel:)] || ![peer respondsToSelector:@selector(state)]) {
            [self failConnectionRequest:address code:7 message:@"This macOS version cannot open the phone's Bluetooth HID channels."];
            continue;
        }
        request.peer = peer;
        [self attachChannelCallbacksToPeer:peer];
        [self log:[NSString stringWithFormat:@"Requesting bonded HID reconnect for %@ (peer state %ld)", peer.addressString, (long)peer.state]];
        if (peer.state == 2) [self advanceConnectionRequest:address];
        else [_manager connectPeer:peer options:@{}];
    }
}

- (void)advanceConnectionRequest:(NSString *)address {
    CBHIDConnectionRequest *request = _connectionRequests[address];
    if (!request.started || !request.peer || request.peer.state != 2) return;
    CBHIDPeerEntry *entry = _entries[address];
    if (entry.controlSocket && entry.interruptSocket) {
        [_connectionRequests removeObjectForKey:address];
        return;
    }
    BOOL control = !entry.controlSocket;
    unsigned short psm = control ? kHIDControlPSM : kHIDInterruptPSM;
    CBL2CAPChannel *existing = [request.peer channelWithPSM:psm];
    if (existing) {
        [self handleChannel:existing opened:YES peer:request.peer address:address errorCode:0];
        return;
    }
    if (control ? request.controlRequested : request.interruptRequested) return;
    if (control) request.controlRequested = YES;
    else request.interruptRequested = YES;
    [self log:[NSString stringWithFormat:@"Requesting HID L2CAP PSM 0x%04x for %@", psm, address]];
    [request.peer openL2CAPChannel:psm];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self log:[NSString stringWithFormat:@"BLE state %ld, Bluetooth authorization %ld",
               (long)central.state, (long)CBCentralManager.authorization]];
    if (central.state == CBManagerStatePoweredOn) {
        [self setUpClassicManager];
    }
}

- (void)centralManagerDidChangeAuthorization:(CBCentralManager *)central {
    [self log:[NSString stringWithFormat:@"Bluetooth authorization changed to %ld",
               (long)CBCentralManager.authorization]];
    if (central.state == CBManagerStatePoweredOn) {
        [self setUpClassicManager];
    }
}

#pragma mark - Classic manager

- (void)setUpClassicManager {
    if (_manager) return;
    _manager = [[NSClassFromString(@"CBClassicManager") alloc] initWithQueue:_queue options:nil];
    if (!_manager) {
        [self log:@"Failed to create CBClassicManager"];
        return;
    }

    @synchronized (CBHIDManagers) { [CBHIDManagers setObject:self forKey:_manager]; }
    __weak CBHIDBridge *weakSelf = self;
    [_manager setConnectCallback:^(id peer, long errorCode) {
        [weakSelf handlePeerConnected:peer errorCode:errorCode];
    }];
    [_manager setDisconnectCallback:^(id peer, long errorCode) {
        [weakSelf handlePeerDisconnected:peer errorCode:errorCode];
    }];
    [_manager setSdpRecordAddedHandler:^(id serviceUUID, long errorCode) {
        [weakSelf handleServiceRecordAdded:serviceUUID errorCode:errorCode];
    }];
    [_manager addObserver:self forKeyPath:@"state" options:0 context:NULL];

    [self log:[NSString stringWithFormat:@"Classic manager created (state %ld, powerState %ld)",
               (long)_manager.state, _manager.powerState]];
    [self publishServiceWhenReady];
}

- (void)handleServiceRecordAdded:(id)serviceUUID errorCode:(long)errorCode {
    if (errorCode != 0) {
        [self log:[NSString stringWithFormat:@"SDP record rejected (error %ld)", errorCode]];
        return;
    }
    if (_published) return;
    _published = YES;
    [self log:[NSString stringWithFormat:@"Published HID SDP record as \"%@\" (service %@); discoverable %d, connectable %d",
               _serviceName, serviceUUID, _manager.discoverable, _manager.connectable]];

    NSMapTable *peers = _manager.peers;
    for (id peer in [peers objectEnumerator]) {
        [self attachChannelCallbacksToPeer:peer];
    }
    [self startConnectionRequestsWhenReady];
}

- (void)publishServiceWhenReady {
    if (_published || !_manager) return;
    if (_manager.state != CBManagerStatePoweredOn) return;

    [_manager setBTConnectable:YES];
    [_manager setBTDiscoverable:YES];
    [_manager performTCCCheck];

    if (!_manager.tccApproved && CBCentralManager.authorization == CBManagerAuthorizationAllowedAlways) {
        [_manager setTccApproved:YES];
    }

    [_manager addServiceWithData:_sdpRecord];

    if (++_publishAttempts <= 60) {
        __weak CBHIDBridge *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), _queue, ^{
            [weakSelf republishServiceIfNeeded];
        });
    } else {
        [self log:@"Gave up publishing the HID SDP record"];
    }
}

- (void)republishServiceIfNeeded {
    if (_published || !_manager) return;
    if (_manager.state != CBManagerStatePoweredOn) return;

    id db = [_manager getLocalSDPDatabase];
    if ([db isKindOfClass:[NSData class]] &&
        [(NSData *)db rangeOfData:[_serviceName dataUsingEncoding:NSUTF8StringEncoding]
                          options:0
                            range:NSMakeRange(0, [(NSData *)db length])].location != NSNotFound) {
        _published = YES;
        [self log:[NSString stringWithFormat:@"HID SDP record for \"%@\" is live in the local SDP database", _serviceName]];
        NSMapTable *peers = _manager.peers;
        for (id peer in [peers objectEnumerator]) {
            [self attachChannelCallbacksToPeer:peer];
        }
        [self startConnectionRequestsWhenReady];
        return;
    }

    if (++_publishAttempts > 60) {
        [self log:@"Gave up publishing the HID SDP record"];
        return;
    }
    [self log:[NSString stringWithFormat:@"SDP publish not confirmed (attempt %d) — republishing", _publishAttempts]];
    [_manager addServiceWithData:_sdpRecord];
    __weak CBHIDBridge *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), _queue, ^{
        [weakSelf republishServiceIfNeeded];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (object == _manager && [keyPath isEqualToString:@"state"]) {
        [self log:[NSString stringWithFormat:@"Classic manager state → %ld", (long)_manager.state]];
        [self publishServiceWhenReady];
        [self startConnectionRequestsWhenReady];
    }
}

#pragma mark - Peer / channel tracking

- (void)handlePeerConnected:(CBClassicPeer *)peer errorCode:(long)errorCode {
    if (!peer) return;
    NSString *address = CBHIDNormalizeAddress(peer.addressString ?: @"");
    [self log:[NSString stringWithFormat:@"Peer connected: %@ (%@) error=%ld", peer.name, peer.addressString, errorCode]];
    if (errorCode != 0 && _connectionRequests[address].peer == peer) {
        [self failConnectionRequest:address code:errorCode message:[NSString stringWithFormat:@"The Bluetooth connection could not be established (error %ld). Unlock the phone and reconnect this Mac from AssistiveTouch if needed.", errorCode]];
        return;
    }
    if (errorCode == 0) {
        [self attachChannelCallbacksToPeer:peer];
        for (NSNumber *psm in @[@(kHIDControlPSM), @(kHIDInterruptPSM)]) {
            CBL2CAPChannel *channel = [peer channelWithPSM:psm.unsignedShortValue];
            if (channel) [self handleChannel:channel opened:YES peer:peer address:address errorCode:0];
        }
        if (_connectionRequests[address].peer == peer) [self advanceConnectionRequest:address];
    }
}

- (void)handlePeerDisconnected:(CBClassicPeer *)peer errorCode:(long)errorCode {
    if (!peer) return;
    NSString *address = CBHIDNormalizeAddress(peer.addressString ?: @"");
    [self log:[NSString stringWithFormat:@"Peer disconnected: %@ (%@) error=%ld", peer.name, peer.addressString, errorCode]];
    if (_connectionRequests[address].peer == peer)
        [self failConnectionRequest:address code:errorCode ?: 9 message:@"The phone disconnected before both Bluetooth control channels opened. Unlock it and try Connect again."];
    @synchronized (_entries) {
        CBHIDPeerEntry *entry = _entries[address];
        [entry.controlSocket close]; [entry.interruptSocket close];
        [_entries removeObjectForKey:address];
    }
    if (self.onPeerDisconnected) self.onPeerDisconnected(address);
}

- (void)attachChannelCallbacksToPeer:(CBClassicPeer *)peer {
    if (![peer respondsToSelector:@selector(setConnectL2CAPCallback:)]) return;
    NSString *address = CBHIDNormalizeAddress(peer.addressString ?: @"");
    if (address.length == 0) return;

    __weak CBHIDBridge *weakSelf = self;
    __weak CBClassicPeer *weakPeer = peer;
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *channel, long errorCode) {
        [weakSelf handleChannel:channel opened:YES peer:weakPeer address:address errorCode:errorCode];
    }];
    [peer setDisconnectL2CAPCallback:^(CBL2CAPChannel *channel, long errorCode) {
        [weakSelf handleChannel:channel opened:NO peer:weakPeer address:address errorCode:errorCode];
    }];
}

- (void)notifyChannelsForAddress:(NSString *)address {
    CBHIDPeerEntry *entry = _entries[address];
    CBHIDPeerState *state = [CBHIDPeerState new];
    state.address = address;
    state.name = entry.peer.name ?: @"";
    state.hasControlChannel = entry.controlSocket != nil;
    state.hasInterruptChannel = entry.interruptSocket != nil;
    if (self.onPeerChannelsChanged) self.onPeerChannelsChanged(state);
}

- (void)handleChannel:(CBL2CAPChannel *)channel opened:(BOOL)opened peer:(CBClassicPeer *)peer
              address:(NSString *)address errorCode:(long)errorCode {
    unsigned short psm = channel.PSM;
    if (opened && errorCode != 0 && (!channel || psm == kHIDControlPSM || psm == kHIDInterruptPSM)) {
        if (_connectionRequests[address].peer == peer)
            [self failConnectionRequest:address code:errorCode message:[NSString stringWithFormat:@"The phone could not open its Bluetooth HID channel (error %ld). Reconnect this Mac from the phone's AssistiveTouch device list.", errorCode]];
        return;
    }
    if (psm != kHIDControlPSM && psm != kHIDInterruptPSM) return;
    [self log:[NSString stringWithFormat:@"%@ L2CAP PSM 0x%04x %@ error=%ld socket=%d", address, psm, opened ? @"opened" : @"closed", errorCode, channel.socketFD]];
    CBHIDPeerEntry *entry = _entries[address];
    if (!entry) {
        if (!opened || errorCode != 0) return;
        entry = [CBHIDPeerEntry new]; entry.peer = peer; entry.session = [HIDControlSession new];
        _entries[address] = entry;
    }
    BOOL control = psm == kHIDControlPSM;
    CBL2CAPChannel *current = control ? entry.controlChannel : entry.interruptChannel;
    if (opened && errorCode == 0 && current == channel) return;
    if (!opened && current != channel) return;
    if (control) { [entry.controlSocket close]; entry.controlSocket = nil; entry.controlChannel = nil; }
    else { [entry.interruptSocket close]; entry.interruptSocket = nil; entry.interruptChannel = nil; }
    if (opened && errorCode == 0) {
        __weak CBHIDBridge *weakSelf = self;
        __weak CBL2CAPChannel *weakChannel = channel;
        NSError *error = nil;
        CBHIDSocket *socket = [[CBHIDSocket alloc] initWithFileDescriptor:channel.socketFD callbackQueue:_queue onPacket:^(NSData *packet) {
            CBHIDBridge *self = weakSelf;
            if (!self) return;
            CBHIDPeerEntry *live = self->_entries[address];
            if ((control ? live.controlChannel : live.interruptChannel) != weakChannel) return;
            [self log:[NSString stringWithFormat:@"HID received PSM 0x%04x: %@", psm, packet]];
            NSData *response = [live.session responseToPacket:packet];
            if (control && response) {
                NSError *writeError = nil;
                if (![live.controlSocket writePacket:response maximumSize:live.controlChannel.outgoingMTU error:&writeError])
                    [self log:writeError.localizedDescription];
            }
            if (live.session.unplugged) [self disconnectPeerWithAddress:address];
        } onClose:^(NSError *error) {
            CBHIDBridge *self = weakSelf;
            if (!self) return;
            if (error) [self log:error.localizedDescription];
            CBL2CAPChannel *closed = weakChannel;
            if (closed) [self handleChannel:closed opened:NO peer:(CBClassicPeer *)closed.peer address:address errorCode:error.code];
        } error:&error];
        if (socket) {
            if (control) { entry.controlChannel = channel; entry.controlSocket = socket; }
            else { entry.interruptChannel = channel; entry.interruptSocket = socket; }
        } else {
            [self log:error.localizedDescription];
            if (_connectionRequests[address].peer == peer)
                [self failConnectionRequest:address code:error.code ?: 10 message:error.localizedDescription ?: @"The phone's Bluetooth HID socket could not be opened."];
        }
    }
    if (!opened && _connectionRequests[address].peer == peer)
        [self failConnectionRequest:address code:errorCode ?: 9 message:@"The phone closed a Bluetooth HID channel before the connection was ready. Reconnect from its AssistiveTouch device list."];
    if (opened && _connectionRequests[address].peer == peer) [self advanceConnectionRequest:address];
    [self notifyChannelsForAddress:address];
}

@end

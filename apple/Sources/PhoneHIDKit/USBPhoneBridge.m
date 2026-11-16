#import <PhoneHIDKit/PhoneHIDKit.h>
#import <dlfcn.h>

typedef void *USBMobileDeviceRef;
static NSString * const USBPhoneErrorDomain = @"PhoneHIDKit.USBPhone";

typedef NS_ENUM(NSInteger, USBPhoneError) {
    USBPhoneErrorUnavailable = 1,
    USBPhoneErrorNotFound,
    USBPhoneErrorConnect,
    USBPhoneErrorTrustRequired,
    USBPhoneErrorValidate,
    USBPhoneErrorSession,
    USBPhoneErrorPair,
    USBPhoneErrorPreferenceWrite,
    USBPhoneErrorPreferenceRead,
};

typedef struct {
    CFArrayRef (*createDeviceList)(void);
    CFStringRef (*copyIdentifier)(USBMobileDeviceRef);
    int (*interfaceType)(USBMobileDeviceRef);
    int (*connect)(USBMobileDeviceRef);
    int (*disconnect)(USBMobileDeviceRef);
    int (*isPaired)(USBMobileDeviceRef);
    int (*pair)(USBMobileDeviceRef);
    int (*validatePairing)(USBMobileDeviceRef);
    int (*startSession)(USBMobileDeviceRef);
    int (*stopSession)(USBMobileDeviceRef);
    CFTypeRef (*copyValue)(USBMobileDeviceRef, CFStringRef, CFStringRef);
    int (*setValue)(USBMobileDeviceRef, CFStringRef, CFStringRef, CFTypeRef);
    const char *(*errorString)(int);
} USBMobileDeviceAPI;

@interface USBPhoneSnapshot ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite, nullable) NSString *productType;
@property (nonatomic, copy, readwrite, nullable) NSString *bluetoothAddress;
@property (nonatomic, readwrite) BOOL paired;
@property (nonatomic, readwrite) BOOL trusted;
@property (nonatomic, strong, readwrite, nullable) NSNumber *assistiveTouchEnabled;
@property (nonatomic, copy, readwrite, nullable) NSString *statusMessage;
@end
@implementation USBPhoneSnapshot
@end

@implementation USBPhoneBridge {
    dispatch_queue_t _queue;
    void *_library;
    USBMobileDeviceAPI _api;
    NSError *_loadError;
    BOOL _loaded;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("app.blau.pilot.phone-usb", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)loadRuntime {
    if (_loaded) return _loadError == nil;
    _loaded = YES;
    _library = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL);
    if (!_library) {
        _loadError = [self error:USBPhoneErrorUnavailable message:@"Apple's iPhone USB service is unavailable on this Mac." nativeCode:0];
        return NO;
    }
#define LOAD(FIELD, SYMBOL) _api.FIELD = dlsym(_library, SYMBOL)
    LOAD(createDeviceList, "AMDCreateDeviceList");
    LOAD(copyIdentifier, "AMDeviceCopyDeviceIdentifier");
    LOAD(interfaceType, "AMDeviceGetInterfaceType");
    LOAD(connect, "AMDeviceConnect");
    LOAD(disconnect, "AMDeviceDisconnect");
    LOAD(isPaired, "AMDeviceIsPaired");
    LOAD(pair, "AMDevicePair");
    LOAD(validatePairing, "AMDeviceValidatePairing");
    LOAD(startSession, "AMDeviceStartSession");
    LOAD(stopSession, "AMDeviceStopSession");
    LOAD(copyValue, "AMDeviceCopyValue");
    LOAD(setValue, "AMDeviceSetValue");
    LOAD(errorString, "AMDErrorString");
#undef LOAD
    if (!_api.createDeviceList || !_api.copyIdentifier || !_api.connect || !_api.disconnect ||
        !_api.isPaired || !_api.pair || !_api.validatePairing || !_api.startSession ||
        !_api.stopSession || !_api.copyValue || !_api.setValue) {
        _loadError = [self error:USBPhoneErrorUnavailable message:@"This version of Apple's iPhone USB service is missing a required setup function." nativeCode:0];
        return NO;
    }
    return YES;
}

- (NSError *)error:(USBPhoneError)code message:(NSString *)message nativeCode:(int)nativeCode {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (nativeCode) {
        const char *nativeText = _api.errorString ? _api.errorString(nativeCode) : NULL;
        NSString *detail = nativeText ? [NSString stringWithUTF8String:nativeText] : nil;
        info[@"MobileDeviceErrorCode"] = @(nativeCode);
        info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"%@ (%@0x%08x)", message,
            detail.length ? [detail stringByAppendingString:@", "] : @"", (unsigned int)nativeCode];
    }
    return [NSError errorWithDomain:USBPhoneErrorDomain code:code userInfo:info];
}

- (id)valueForDevice:(USBMobileDeviceRef)device domain:(NSString * _Nullable)domain key:(NSString *)key {
    CFTypeRef value = _api.copyValue(device, (__bridge CFStringRef)domain, (__bridge CFStringRef)key);
    return value ? CFBridgingRelease(value) : nil;
}

- (NSString * _Nullable)stringForDevice:(USBMobileDeviceRef)device key:(NSString *)key {
    id value = [self valueForDevice:device domain:nil key:key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (NSNumber * _Nullable)booleanForDevice:(USBMobileDeviceRef)device domain:(NSString * _Nullable)domain key:(NSString *)key {
    id value = [self valueForDevice:device domain:domain key:key];
    return [value isKindOfClass:NSNumber.class] ? @([value boolValue]) : nil;
}

- (USBPhoneSnapshot *)snapshotForDevice:(USBMobileDeviceRef)device
                           requestTrust:(BOOL)requestTrust
                                prepare:(BOOL)prepare
                                  error:(NSError **)error {
    USBPhoneSnapshot *snapshot = [USBPhoneSnapshot new];
    CFStringRef identifier = _api.copyIdentifier(device);
    snapshot.identifier = identifier ? CFBridgingRelease(identifier) : @"";
    snapshot.name = @"iPhone";
    int result = _api.connect(device);
    if (result != 0) {
        *error = [self error:USBPhoneErrorConnect message:@"Could not open the iPhone's USB connection." nativeCode:result];
        snapshot.statusMessage = (*error).localizedDescription;
        return snapshot;
    }
    BOOL sessionStarted = NO;
    @try {
        snapshot.name = [self stringForDevice:device key:@"DeviceName"] ?: snapshot.name;
        snapshot.productType = [self stringForDevice:device key:@"ProductType"];
        snapshot.paired = _api.isPaired(device) != 0;
        if (requestTrust && !snapshot.paired) {
            result = _api.pair(device);
            if (result != 0) {
                *error = [self error:USBPhoneErrorPair message:@"Unlock this iPhone and accept its Trust This Computer prompt, then try again." nativeCode:result];
                snapshot.statusMessage = (*error).localizedDescription;
                return snapshot;
            }
            snapshot.paired = _api.isPaired(device) != 0;
        }
        if (!snapshot.paired) {
            *error = [self error:USBPhoneErrorTrustRequired message:@"This iPhone has not trusted this Mac. Unlock it and accept Trust This Computer to finish setup." nativeCode:0];
            snapshot.statusMessage = (*error).localizedDescription;
            return snapshot;
        }
        result = _api.validatePairing(device);
        if (result != 0) {
            if (requestTrust) {
                result = _api.pair(device);
                if (result == 0) result = _api.validatePairing(device);
            }
            if (result != 0) {
                *error = [self error:USBPhoneErrorValidate message:@"The iPhone could not verify this Mac's trust. Unlock it and accept Trust This Computer." nativeCode:result];
                snapshot.statusMessage = (*error).localizedDescription;
                return snapshot;
            }
        }
        result = _api.startSession(device);
        if (result != 0) {
            *error = [self error:USBPhoneErrorSession message:@"Could not open a trusted iPhone session. Keep the iPhone unlocked." nativeCode:result];
            snapshot.statusMessage = (*error).localizedDescription;
            return snapshot;
        }
        sessionStarted = YES;
        snapshot.trusted = YES;
        snapshot.bluetoothAddress = [self stringForDevice:device key:@"BluetoothAddress"];
        snapshot.assistiveTouchEnabled = [self booleanForDevice:device domain:@"com.apple.Accessibility" key:@"AssistiveTouchEnabledByiTunes"];
        if (prepare && !snapshot.assistiveTouchEnabled.boolValue) {
            result = _api.setValue(device, CFSTR("com.apple.Accessibility"), CFSTR("AssistiveTouchEnabledByiTunes"), kCFBooleanTrue);
            if (result != 0) {
                *error = [self error:USBPhoneErrorPreferenceWrite message:@"Could not enable AssistiveTouch on this iPhone." nativeCode:result];
                snapshot.statusMessage = (*error).localizedDescription;
                return snapshot;
            }
            snapshot.assistiveTouchEnabled = [self booleanForDevice:device domain:@"com.apple.Accessibility" key:@"AssistiveTouchEnabledByiTunes"];
            if (!snapshot.assistiveTouchEnabled.boolValue) {
                *error = [self error:USBPhoneErrorPreferenceRead message:@"The iPhone has not confirmed that AssistiveTouch is enabled. Try again with the phone unlocked." nativeCode:0];
                snapshot.statusMessage = (*error).localizedDescription;
                return snapshot;
            }
        }
        if (prepare && !snapshot.bluetoothAddress.length) {
            *error = [self error:USBPhoneErrorPreferenceRead message:@"This iPhone did not provide its Bluetooth address. Keep it unlocked and try again." nativeCode:0];
            snapshot.statusMessage = (*error).localizedDescription;
        }
        return snapshot;
    } @finally {
        if (sessionStarted) _api.stopSession(device);
        _api.disconnect(device);
    }
}

- (void)fetchConnectedPhonesWithCompletion:(void (^)(NSArray<USBPhoneSnapshot *> *, NSError * _Nullable))completion {
    dispatch_async(_queue, ^{
        if (![self loadRuntime]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], self->_loadError); });
            return;
        }
        CFArrayRef devices = self->_api.createDeviceList();
        NSMutableArray<USBPhoneSnapshot *> *snapshots = [NSMutableArray array];
        for (CFIndex i = 0; devices && i < CFArrayGetCount(devices); i++) {
            USBMobileDeviceRef device = (USBMobileDeviceRef)CFArrayGetValueAtIndex(devices, i);
            if (self->_api.interfaceType && self->_api.interfaceType(device) != 1) continue;
            NSError *phoneError = nil;
            USBPhoneSnapshot *snapshot = [self snapshotForDevice:device requestTrust:NO prepare:NO error:&phoneError];
            if (snapshot.identifier.length && (!snapshot.productType || [snapshot.productType hasPrefix:@"iPhone"])) {
                [snapshots addObject:snapshot];
            }
        }
        if (devices) CFRelease(devices);
        NSArray *result = [snapshots copy];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, nil); });
    });
}

- (void)performForIdentifier:(NSString *)identifier
               requestTrust:(BOOL)requestTrust
                    prepare:(BOOL)prepare
                 completion:(void (^)(USBPhoneSnapshot * _Nullable, NSError * _Nullable))completion {
    NSString *selectedIdentifier = [identifier copy];
    dispatch_async(_queue, ^{
        if (![self loadRuntime]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, self->_loadError); });
            return;
        }
        CFArrayRef devices = self->_api.createDeviceList();
        USBPhoneSnapshot *snapshot = nil;
        NSError *error = nil;
        for (CFIndex i = 0; devices && i < CFArrayGetCount(devices); i++) {
            USBMobileDeviceRef device = (USBMobileDeviceRef)CFArrayGetValueAtIndex(devices, i);
            if (self->_api.interfaceType && self->_api.interfaceType(device) != 1) continue;
            CFStringRef deviceID = self->_api.copyIdentifier(device);
            BOOL matches = deviceID && [(__bridge NSString *)deviceID isEqualToString:selectedIdentifier];
            if (deviceID) CFRelease(deviceID);
            if (!matches) continue;
            snapshot = [self snapshotForDevice:device requestTrust:requestTrust prepare:prepare error:&error];
            break;
        }
        if (devices) CFRelease(devices);
        if (!snapshot && !error) {
            error = [self error:USBPhoneErrorNotFound message:@"The selected iPhone is no longer connected over USB." nativeCode:0];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot, error); });
    });
}

- (void)requestTrustForIdentifier:(NSString *)identifier completion:(void (^)(USBPhoneSnapshot * _Nullable, NSError * _Nullable))completion {
    [self performForIdentifier:identifier requestTrust:YES prepare:NO completion:completion];
}

- (void)preparePhoneWithIdentifier:(NSString *)identifier completion:(void (^)(USBPhoneSnapshot * _Nullable, NSError * _Nullable))completion {
    [self performForIdentifier:identifier requestTrust:NO prepare:YES completion:completion];
}

@end

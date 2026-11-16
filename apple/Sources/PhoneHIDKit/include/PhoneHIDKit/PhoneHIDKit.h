// PhoneHIDKit: drive a physical iPhone from this Mac without Developer Mode.
//
// The Mac publishes a Bluetooth HID pointer + keyboard. With AssistiveTouch
// on, iOS turns that absolute pointer into touches. Ported from ShortReel.
//
// Both halves use private Apple interfaces:
//   - CBHIDBridge: CoreBluetooth's classic-transport classes (CBClassicManager,
//     CBClassicPeer) and a hook on CBClassicPeer's message handler so the HID
//     L2CAP channels (PSM 0x11/0x13) reach us.
//   - USBPhoneBridge: MobileDevice.framework (dlopen) to read the phone's
//     Bluetooth address and turn AssistiveTouch on over a trusted USB session.
// Every entry point fails with an NSError instead of crashing when a symbol
// is missing, so an OS update degrades to "unavailable".

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Bluetooth HID

@interface CBHIDPeerState : NSObject
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL hasControlChannel;
@property (nonatomic) BOOL hasInterruptChannel;
@end

/// Callbacks run on the bridge's private serial queue.
@interface CBHIDBridge : NSObject

@property (nonatomic, copy, nullable) void (^onPeerChannelsChanged)(CBHIDPeerState *peer);
@property (nonatomic, copy, nullable) void (^onPeerDisconnected)(NSString *address);
@property (nonatomic, copy, nullable) void (^onConnectionFailed)(NSString *address, NSError *error);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)startWithServiceName:(NSString *)serviceName
               serviceRecord:(NSData *)sdpRecord
                       error:(NSError **)error;
- (void)stop;
- (void)disconnectPeerWithAddress:(NSString *)address;

- (void)requestConnectionToPeerWithAddress:(NSString *)address NS_SWIFT_NAME(requestConnection(address:));
- (void)cancelConnectionRequestWithAddress:(NSString *)address NS_SWIFT_NAME(cancelConnectionRequest(address:));

- (BOOL)sendReport:(NSData *)report toPeerWithAddress:(NSString *)address error:(NSError **)error;

- (NSArray<NSString *> *)connectedPeerAddresses;

@end

/// Answers the host's HID control-channel transactions (GET_REPORT,
/// SET_REPORT, protocol, suspend/unplug) for one connected phone.
@interface HIDControlSession : NSObject
@property (nonatomic, readonly) BOOL suspended;
@property (nonatomic, readonly) BOOL unplugged;
- (nullable NSData *)responseToPacket:(NSData *)packet;
- (void)recordInput:(NSData *)packet;
@end

#pragma mark - USB setup

@interface USBPhoneSnapshot : NSObject
/// The phone's UDID.
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *productType;
@property (nonatomic, copy, readonly, nullable) NSString *bluetoothAddress;
@property (nonatomic, readonly) BOOL paired;
@property (nonatomic, readonly) BOOL trusted;
@property (nonatomic, strong, readonly, nullable) NSNumber *assistiveTouchEnabled;
@property (nonatomic, copy, readonly, nullable) NSString *statusMessage;
@end

/// Completions run on the main queue.
@interface USBPhoneBridge : NSObject
- (void)fetchConnectedPhonesWithCompletion:(void (^)(NSArray<USBPhoneSnapshot *> *phones, NSError * _Nullable error))completion;

- (void)requestTrustForIdentifier:(NSString *)identifier
                     completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;

/// Turns AssistiveTouch on (if needed) and reads the Bluetooth address.
- (void)preparePhoneWithIdentifier:(NSString *)identifier
                      completion:(void (^)(USBPhoneSnapshot * _Nullable phone, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END

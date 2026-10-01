// Private declarations shared by ChromiumKit's implementation units. Not part
// of the public module: Pilot sees only include/ChromiumKit/ChromiumKit.h.
//
// Thread contract: every declaration here is main-thread only. CEF runs with
// an external message pump on the main queue, so CEF UI-thread callbacks and
// AppKit calls share that one thread; IO-thread callbacks hop to main before
// touching these objects.

#import <ChromiumKit/ChromiumKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSError *ChromiumKitError(ChromiumKitErrorCode code,
                                            NSString *description,
                                            NSDictionary *_Nullable extra);

/// Error returned by the artifact-free implementation for every operation
/// that would require the CEF runtime.
FOUNDATION_EXTERN NSError *ChromiumKitUnavailableError(void);

@interface ChromiumEngine ()
@property (nonatomic, readwrite) ChromiumEngineState state;
@property (nonatomic) NSMutableArray *shutdownCompletions;
- (void)chromiumDidFinishShutdown;
@end

@interface ChromiumBrowserHostView ()
@property (nonatomic, readwrite) ChromiumBrowserLifecycleState lifecycleState;
@property (nonatomic, readwrite, nullable) NSURL *URL;
@property (nonatomic, readwrite, nullable) NSString *title;
@property (nonatomic, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, readwrite) double estimatedProgress;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite) double zoomLevel;
@property (nonatomic) NSUInteger chromiumToken;
@property (nonatomic, nullable) NSURL *pendingURL;
@property (nonatomic) BOOL closeDelivered;
- (void)cefDidCreate;
- (void)cefDidChangeURL:(NSURL *)URL;
- (void)cefDidChangeTitle:(nullable NSString *)title;
- (void)cefDidChangeFaviconURLs:(NSArray<NSURL *> *)URLs;
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward;
- (void)cefDidChangeProgress:(double)progress;
- (void)cefDidFail:(NSError *)error;
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status;
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate;
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state;
- (void)cefDidRejectAuthenticationForURL:(nullable NSURL *)URL;
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(nullable NSURL *)URL;
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port;
- (void)cefWillClose;
- (void)cefDidClose;
@end

@interface ChromiumContextMenuRequest ()
@property (nonatomic, readwrite) NSPoint location;
@property (nonatomic, readwrite, nullable) NSURL *linkURL;
@property (nonatomic, readwrite, nullable) NSURL *sourceURL;
@property (nonatomic, readwrite) NSString *selectedText;
@property (nonatomic, readwrite, getter=isEditable) BOOL editable;
- (instancetype)initWithLocation:(NSPoint)location
                         linkURL:(nullable NSURL *)linkURL
                       sourceURL:(nullable NSURL *)sourceURL
                    selectedText:(NSString *)selectedText
                        editable:(BOOL)editable;
@end

@interface ChromiumPermissionRequest ()
@property (nonatomic, readwrite) NSURL *origin;
@property (nonatomic, readwrite) ChromiumPermissionKind kinds;
@property (nonatomic, readwrite) NSUInteger rawPermissionMask;
@property (nonatomic, copy, nullable)
    void (^decisionHandler)(BOOL allowed);
@property (nonatomic) BOOL resolved;
- (instancetype)initWithOrigin:(NSURL *)origin
                         kinds:(ChromiumPermissionKind)kinds
               rawPermissionMask:(NSUInteger)rawPermissionMask
               decisionHandler:(void (^)(BOOL allowed))decisionHandler;
@end

NS_ASSUME_NONNULL_END

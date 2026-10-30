#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ChromiumKitErrorDomain;

typedef NS_ERROR_ENUM(ChromiumKitErrorDomain, ChromiumKitErrorCode) {
    ChromiumKitErrorRuntimeUnavailable = 1,
    ChromiumKitErrorInvalidProfileDirectory = 2,
    ChromiumKitErrorEngineNotRunning = 3,
    ChromiumKitErrorLibraryLoadFailed = 4,
    ChromiumKitErrorInitializationFailed = 5,
    ChromiumKitErrorBrowserCreationFailed = 6,
    ChromiumKitErrorNavigationFailed = 7,
    ChromiumKitErrorDownloadQuarantineFailed = 8,
};

/// Applies macOS web-download quarantine metadata without persisting the
/// source or origin URL. Returns NO for non-file URLs and non-regular files.
FOUNDATION_EXPORT BOOL ChromiumKitApplyDownloadQuarantine(
    NSURL *fileURL,
    NSError *_Nullable *_Nullable error);

typedef NS_ENUM(NSInteger, ChromiumEngineState) {
    ChromiumEngineStateNotStarted = 0,
    ChromiumEngineStateInitializing = 1,
    ChromiumEngineStateRunning = 2,
    ChromiumEngineStateShuttingDown = 3,
    ChromiumEngineStateShutDown = 4,
    ChromiumEngineStateFailed = 5,
};

typedef NS_ENUM(NSInteger, ChromiumBrowserLifecycleState) {
    ChromiumBrowserLifecycleStateCreating = 0,
    ChromiumBrowserLifecycleStateCreated = 1,
    ChromiumBrowserLifecycleStateClosing = 2,
    ChromiumBrowserLifecycleStateClosed = 3,
};

typedef NS_ENUM(NSInteger, ChromiumRendererTerminationStatus) {
    ChromiumRendererTerminationStatusAbnormal = 0,
    ChromiumRendererTerminationStatusKilled = 1,
    ChromiumRendererTerminationStatusCrashed = 2,
    ChromiumRendererTerminationStatusOutOfMemory = 3,
    ChromiumRendererTerminationStatusLaunchFailed = 4,
    ChromiumRendererTerminationStatusIntegrityFailure = 5,
};

typedef NS_ENUM(NSInteger, ChromiumNavigationDecision) {
    ChromiumNavigationDecisionAllow = 0,
    ChromiumNavigationDecisionCancel = 1,
    ChromiumNavigationDecisionOpenExternally = 2,
};

typedef NS_ENUM(NSInteger, ChromiumPopupDisposition) {
    ChromiumPopupDispositionUnknown = 0,
    ChromiumPopupDispositionForegroundTab = 1,
    ChromiumPopupDispositionBackgroundTab = 2,
    ChromiumPopupDispositionPopup = 3,
    ChromiumPopupDispositionWindow = 4,
};

typedef NS_OPTIONS(NSUInteger, ChromiumPermissionKind) {
    ChromiumPermissionKindOther = 1 << 0,
    ChromiumPermissionKindAudioCapture = 1 << 1,
    ChromiumPermissionKindVideoCapture = 1 << 2,
    ChromiumPermissionKindGeolocation = 1 << 3,
    ChromiumPermissionKindNotifications = 1 << 4,
    ChromiumPermissionKindClipboard = 1 << 5,
    ChromiumPermissionKindMIDISystemExclusive = 1 << 6,
    ChromiumPermissionKindFileSystemAccess = 1 << 7,
};

typedef NS_ENUM(NSInteger, ChromiumDownloadState) {
    ChromiumDownloadStateInProgress = 0,
    ChromiumDownloadStateComplete = 1,
    ChromiumDownloadStateCanceled = 2,
    ChromiumDownloadStateInterrupted = 3,
};

@class ChromiumBrowserHostView;
@class ChromiumContextMenuRequest;
@class ChromiumPermissionRequest;

/// All delegate methods are delivered on the AppKit main thread. The delegate
/// is held weakly, and no delegate method is delivered after didClose.
@protocol ChromiumBrowserHostViewDelegate <NSObject>
@optional
- (void)chromiumBrowserHostViewDidCreate:(ChromiumBrowserHostView *)browserView;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
                   didChangeURL:(NSURL *)URL;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
                 didChangeTitle:(nullable NSString *)title;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
          didChangeFaviconURLs:(NSArray<NSURL *> *)URLs;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
               didChangeLoading:(BOOL)isLoading;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
              didChangeProgress:(double)progress;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
             didChangeCanGoBack:(BOOL)canGoBack;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
        didChangeCanGoForward:(BOOL)canGoForward;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
      didFailNavigationWithError:(NSError *)error;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
 rendererTerminatedWithStatus:(ChromiumRendererTerminationStatus)status;
- (void)chromiumBrowserHostViewDidClose:(ChromiumBrowserHostView *)browserView;
- (ChromiumNavigationDecision)
    chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
      decideNavigationToURL:(NSURL *)URL
                userGesture:(BOOL)userGesture
                 isRedirect:(BOOL)isRedirect;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
             didRequestPopup:(NSURL *)URL
                 disposition:(ChromiumPopupDisposition)disposition
                 userGesture:(BOOL)userGesture;
- (BOOL)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
         shouldOpenExternalURL:(NSURL *)URL;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
           didRequestPermission:(ChromiumPermissionRequest *)request;
- (BOOL)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
             shouldDownloadURL:(NSURL *)URL
             suggestedFilename:(NSString *)suggestedFilename;
- (BOOL)chromiumBrowserHostViewShouldPresentFileChooser:
    (ChromiumBrowserHostView *)browserView;
- (BOOL)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
       shouldPresentContextMenu:(ChromiumContextMenuRequest *)request;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
       didUpdateFindMatchCount:(NSInteger)matchCount
            activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                   finalUpdate:(BOOL)finalUpdate;
- (BOOL)chromiumBrowserHostViewShouldPrint:
    (ChromiumBrowserHostView *)browserView;
- (BOOL)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
             shouldSavePageURL:(NSURL *)URL;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
 didUpdateDownloadWithIdentifier:(NSUInteger)identifier
                            URL:(NSURL *)URL
              suggestedFilename:(NSString *)suggestedFilename
                  receivedBytes:(int64_t)receivedBytes
                     totalBytes:(int64_t)totalBytes
                percentComplete:(NSInteger)percentComplete
                          state:(ChromiumDownloadState)state;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
 didRejectAuthenticationForURL:(nullable NSURL *)URL;
/// Called only for recoverable certificate errors. Returning YES continues
/// this request; absent delegates reject it. Approval must be explicitly
/// scoped to this origin and the supplied leaf certificate.
- (BOOL)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
    shouldAllowCertificateError:(NSInteger)errorCode
                         forURL:(NSURL *)URL
                 certificateDER:(NSData *)certificateDER;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
     didRejectCertificateError:(NSInteger)errorCode
                         forURL:(nullable NSURL *)URL;
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
 didRejectClientCertificateForHost:(NSString *)host
                             port:(NSInteger)port;
@end

/// Immutable metadata for a context menu request. Context menus are suppressed
/// unless the delegate explicitly opts in for each request.
@interface ChromiumContextMenuRequest : NSObject

@property (nonatomic, readonly) NSPoint location;
@property (nonatomic, readonly, nullable) NSURL *linkURL;
@property (nonatomic, readonly, nullable) NSURL *sourceURL;
@property (nonatomic, readonly) NSString *selectedText;
@property (nonatomic, readonly, getter=isEditable) BOOL editable;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// A single-use, origin-scoped permission decision. Requests are denied by the
/// bridge when the delegate is absent.
@interface ChromiumPermissionRequest : NSObject

@property (nonatomic, readonly) NSURL *origin;
@property (nonatomic, readonly) ChromiumPermissionKind kinds;
@property (nonatomic, readonly) NSUInteger rawPermissionMask;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (void)allow;
- (void)deny;

@end

/// Process-wide CEF owner. Start and shutdown must be called on the main thread.
/// CEF cannot be restarted after shutdown in the same process.
@interface ChromiumEngine : NSObject

@property (class, nonatomic, readonly) ChromiumEngine *shared;
/// YES only when this ChromiumKit build contains the verified CEF-backed
/// implementation. The artifact-free bridge returns NO without attempting
/// process-wide initialization.
@property (nonatomic, readonly, getter=isRuntimeAvailable) BOOL runtimeAvailable;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) ChromiumEngineState state;
/// Number of message-pump turns caused by Pilot's liveness watchdog instead of
/// an OnScheduleMessagePumpWork callback since engine start.
@property (nonatomic, readonly) NSUInteger messagePumpWatchdogWorkCount;
/// Includes creating and closing browser hosts until CEF reports that each
/// native browser has actually closed.
@property (nonatomic, readonly) NSUInteger activeBrowserCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Unpacked extension directories to side-load, in load order.
///
/// Must be called before ``start(profileDirectory:)``: CEF reads the command
/// line once during initialization. Chrome derives an unpacked extension's
/// identifier from its absolute path, so these paths also determine the
/// `chrome-extension://` origin its pages are served from.
- (void)setExtensionDirectories:(NSArray<NSURL *> *)directories
    NS_SWIFT_NAME(setExtensionDirectories(_:));

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(profileDirectory:));
- (void)shutdown;
- (void)shutdownWithCompletion:(nullable void (^)(void))completion
    NS_SWIFT_NAME(shutdown(completion:));

@end

/// A native, windowed CEF child view. Commands are main-thread-only. Creation
/// and close are asynchronous; close completion is reported by didClose.
@interface ChromiumBrowserHostView : NSView

@property (nonatomic, weak, nullable) id<ChromiumBrowserHostViewDelegate> delegate;
@property (nonatomic, readonly) ChromiumBrowserLifecycleState lifecycleState;
@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) double zoomLevel;

- (void)loadURL:(NSURL *)URL;
- (void)back;
- (void)forward;
- (void)reload;
- (void)stop;
- (void)focusBrowser;
- (void)setZoom:(double)zoomLevel;
- (void)openDevTools;
- (void)closeDevTools;
- (void)findText:(NSString *)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext;
- (void)stopFindingAndClearSelection:(BOOL)clearSelection;
- (void)printPage;
- (void)savePage;
/// Executes script in the current main frame. The return value only indicates
/// that CEF accepted the command; page-observable effects remain asynchronous.
- (BOOL)executeJavaScript:(NSString *)script
                sourceURL:(nullable NSURL *)sourceURL
                     line:(NSInteger)line
    NS_SWIFT_NAME(executeJavaScript(_:sourceURL:line:));
/// Sends a trusted left-button click at an AppKit-local point. This is intended
/// for native automation and accessibility adapters, not page script.
- (BOOL)sendMouseClickAtPoint:(NSPoint)point
    NS_SWIFT_NAME(sendMouseClick(at:));
- (void)close;

@end

NS_ASSUME_NONNULL_END

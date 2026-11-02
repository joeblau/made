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

typedef NS_ENUM(NSInteger, ChromiumJavaScriptDialogKind) {
    ChromiumJavaScriptDialogKindAlert = 0,
    ChromiumJavaScriptDialogKindConfirm = 1,
    ChromiumJavaScriptDialogKindPrompt = 2,
    ChromiumJavaScriptDialogKindBeforeUnload = 3,
};

typedef NS_ENUM(NSInteger, ChromiumDownloadState) {
    ChromiumDownloadStateInProgress = 0,
    ChromiumDownloadStateComplete = 1,
    ChromiumDownloadStateCanceled = 2,
    ChromiumDownloadStateInterrupted = 3,
};

@class ChromiumBrowserHostView;
@class ChromiumContextMenuRequest;
@class ChromiumJavaScriptDialogRequest;
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
/// Extension popups only: the popup's window stopped being the active
/// window (the user clicked elsewhere or switched apps). Popups dismiss on
/// this the way Chrome's toolbar popups do.
- (void)chromiumBrowserHostViewPopupDidResignActive:
    (ChromiumBrowserHostView *)browserView;
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
/// A page called alert, confirm, or prompt, or a navigation away from it
/// raised beforeunload. Implementing this replaces CEF's free-floating
/// default dialog: the delegate owns the request and must accept or cancel
/// it; an unresolved request is cancelled when it is released. Without this
/// method CEF shows its own dialog.
- (void)chromiumBrowserHostView:(ChromiumBrowserHostView *)browserView
     didRequestJavaScriptDialog:(ChromiumJavaScriptDialogRequest *)request;
/// CEF cancelled every pending JavaScript dialog for this browser (for
/// example, because the page navigated). Dismiss any presented dialog; its
/// request is already resolved and ignores further decisions.
- (void)chromiumBrowserHostViewDidResetJavaScriptDialogs:
    (ChromiumBrowserHostView *)browserView;
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

/// A single-use JavaScript dialog decision. Every string is page-controlled
/// and untrusted: the origin comes from CEF, the message and default prompt
/// text from page script. Decisions are main-thread only and resolve once.
@interface ChromiumJavaScriptDialogRequest : NSObject

@property (nonatomic, readonly) ChromiumJavaScriptDialogKind kind;
/// The requesting frame's URL, or the main frame's URL for beforeunload.
@property (nonatomic, readonly, nullable) NSURL *originURL;
/// Page-provided text. Chromium ignores custom beforeunload text, so pages
/// cannot rely on it being shown.
@property (nonatomic, readonly) NSString *message;
@property (nonatomic, readonly) NSString *defaultPromptText;
/// For beforeunload: whether the user is reloading rather than leaving.
@property (nonatomic, readonly, getter=isReload) BOOL reload;
@property (nonatomic, readonly, getter=isResolved) BOOL resolved;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// OK for alert and confirm, OK with the entered text for prompt, and
/// Leave for beforeunload.
- (void)acceptWithUserInput:(nullable NSString *)userInput
    NS_SWIFT_NAME(accept(userInput:));
- (void)cancel;

@end

/// Process-wide CEF owner. Start and shutdown must be called on the main thread.
/// CEF cannot be restarted after shutdown in the same process.
@interface ChromiumEngine : NSObject

@property (class, nonatomic, readonly) ChromiumEngine *shared;
/// Adds CEF's CefAppProtocol (isHandlingSendEvent/setHandlingSendEvent and a
/// CefScopedSendingEvent around -sendEvent:) to the class of the existing
/// NSApp. SwiftUI's App lifecycle instantiates its own NSApplication subclass,
/// so the app cannot supply one through NSPrincipalClass. Main thread only and
/// idempotent; start(profileDirectory:) also calls it before CEF initializes.
/// Returns NO when NSApp does not exist yet or no CEF runtime is linked.
+ (BOOL)installApplicationIntegration
    NS_SWIFT_NAME(installApplicationIntegration());
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

/// Called on the main thread with the chrome-extension:// URL an extension
/// asked Chrome to show in a new tab or window (chrome.tabs.create,
/// chrome.windows.create, openOptionsPage, ...).
///
/// Chrome would show such a page in a Chrome UI browser window (tab strip,
/// omnibox, menus) that is outside every Pilot pane and request policy.
/// ChromiumKit never lets one load: each such browser is hidden, its
/// navigations are cancelled, and it is closed. Only the extension URL is
/// reported here, so the app can show it in a managed extension window after
/// checking that the extension is one it loaded. Any other URL is dropped.
@property (nonatomic, copy, nullable)
    void (^extensionPageRequestHandler)(NSURL *URL);

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(profileDirectory:));
- (void)shutdown;
- (void)shutdownWithCompletion:(nullable void (^)(void))completion
    NS_SWIFT_NAME(shutdown(completion:));

@end

/// A native, windowed CEF child view. Commands are main-thread-only. Creation
/// and close are asynchronous; close completion is reported by didClose.
///
/// A host made with initWithFrame: embeds an Alloy-style browser as a child of
/// this view: CEF always uses Alloy style for a browser with an application-
/// provided parent view (cef_window_info_t.runtime_style). A host made with
/// initExtensionPopupWithScreenFrame: or initExtensionWindowWithScreenFrame:
/// is instead a Chrome-style browser in its own CEF-owned top-level window;
/// see those initializers.
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
/// YES for a host made with initExtensionPopupWithScreenFrame:.
@property (nonatomic, readonly, getter=isExtensionPopup) BOOL extensionPopup;
/// YES for a host made with initExtensionWindowWithScreenFrame:.
@property (nonatomic, readonly, getter=isExtensionWindow) BOOL extensionWindow;

/// A host for a side-loaded extension's action popup (a chrome-extension://
/// page). Its browser is created through the CEF Views framework as a
/// Chrome-style CefBrowserView in a frameless top-level CefWindow at
/// |screenFrame| (AppKit screen coordinates), with no Chrome toolbar.
///
/// Chrome style is required: CEF 150 runs extensions only through Chrome's
/// own extension system, and an Alloy-style browser renders an extension
/// page in an ordinary renderer without extension bindings, so a popup that
/// talks to its background script never loads. CEF supports Chrome style
/// only for its own windows, never for a child of an application NSView.
///
/// This view is never shown; it is the command and delegate handle for the
/// browser. Every request policy of an embedded host applies unchanged, and
/// Chrome commands (new tab or window, settings, history, DevTools, and the
/// like) are refused so the popup cannot open browser UI of its own.
- (instancetype)initExtensionPopupWithScreenFrame:(NSRect)screenFrame
    NS_SWIFT_NAME(init(extensionPopupScreenFrame:));
/// Like an extension popup, but in an ordinary titled, resizable window that
/// stays open when it loses focus: for full extension pages (onboarding,
/// approval windows) that an extension would otherwise open as a Chrome tab
/// or window. See ChromiumEngine.extensionPageRequestHandler.
- (instancetype)initExtensionWindowWithScreenFrame:(NSRect)screenFrame
    NS_SWIFT_NAME(init(extensionWindowScreenFrame:));

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

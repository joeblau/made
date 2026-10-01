// Artifact-free implementation used by Debug and Release builds that do not
// link CEF. Operations that would need CEF report
// ChromiumKitErrorRuntimeUnavailable; close and stop complete locally.

#import "ChromiumKitInternal.h"

#if !defined(BLAU_CHROMIUM_CEF_ENABLED) || !BLAU_CHROMIUM_CEF_ENABLED

@implementation ChromiumEngine

+ (ChromiumEngine *)shared {
    static ChromiumEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[ChromiumEngine alloc] initPrivate];
    });
    return engine;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) _state = ChromiumEngineStateNotStarted;
    return self;
}

- (BOOL)isRunning {
    return self.state == ChromiumEngineStateInitializing ||
           self.state == ChromiumEngineStateRunning;
}

- (BOOL)isRuntimeAvailable {
    return NO;
}

- (NSUInteger)activeBrowserCount {
    return 0;
}

- (NSUInteger)messagePumpWatchdogWorkCount {
    return 0;
}

- (void)setExtensionDirectories:(NSArray<NSURL *> *)directories {
    // The artifact-free bridge links no CEF, so there is nothing to load.
}

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError **)error {
    if (!profileDirectory.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory must be a file URL.", nil);
        }
        return NO;
    }
    self.state = ChromiumEngineStateFailed;
    if (error) *error = ChromiumKitUnavailableError();
    return NO;
}

- (void)shutdown {
    [self shutdownWithCompletion:nil];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    self.state = ChromiumEngineStateShutDown;
    if (completion) completion();
}

- (void)chromiumDidFinishShutdown {
    self.state = ChromiumEngineStateShutDown;
}

@end

@implementation ChromiumBrowserHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self initializeUnavailableHost];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self initializeUnavailableHost];
    return self;
}
- (void)initializeUnavailableHost {
    _lifecycleState = ChromiumBrowserLifecycleStateCreating;
    _estimatedProgress = 0;
    _zoomLevel = 0;
}
- (void)loadURL:(NSURL *)URL {
    if (self.lifecycleState == ChromiumBrowserLifecycleStateClosed) return;
    self.URL = URL;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeURL:)]) {
        [delegate chromiumBrowserHostView:self didChangeURL:URL];
    }
    [self cefDidFail:ChromiumKitUnavailableError()];
}
- (void)back { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)forward { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)reload { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)stop { self.loading = NO; }
- (void)focusBrowser {}
- (void)setZoom:(double)zoomLevel { self.zoomLevel = zoomLevel; }
- (void)openDevTools { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)closeDevTools {}
- (void)findText:(NSString *)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
    [self cefDidFail:ChromiumKitUnavailableError()];
}
- (void)stopFindingAndClearSelection:(BOOL)clearSelection {}
- (void)printPage { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)savePage { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (BOOL)executeJavaScript:(NSString *)script
                sourceURL:(NSURL *)sourceURL
                     line:(NSInteger)line {
    return NO;
}
- (BOOL)sendMouseClickAtPoint:(NSPoint)point { return NO; }
- (void)close { [self cefDidClose]; }
- (void)cefDidCreate {}
- (void)cefDidChangeURL:(NSURL *)URL {}
- (void)cefDidChangeTitle:(NSString *)title {}
- (void)cefDidChangeFaviconURLs:(NSArray<NSURL *> *)URLs {}
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward {}
- (void)cefDidChangeProgress:(double)progress {}
- (void)cefDidFail:(NSError *)error {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateClosed) {
        id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:
                @selector(chromiumBrowserHostView:
                             didFailNavigationWithError:)]) {
            [delegate chromiumBrowserHostView:self
                  didFailNavigationWithError:error];
        }
    }
}
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status {}
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate {}
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state {}
- (void)cefDidRejectAuthenticationForURL:(NSURL *)URL {}
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(NSURL *)URL {}
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port {}
- (void)cefWillClose {
    self.lifecycleState = ChromiumBrowserLifecycleStateClosing;
}
- (void)cefDidClose {
    if (self.closeDelivered) return;
    self.closeDelivered = YES;
    self.lifecycleState = ChromiumBrowserLifecycleStateClosed;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidClose:)]) {
        [delegate chromiumBrowserHostViewDidClose:self];
    }
}

@end

#endif

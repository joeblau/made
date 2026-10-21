// CEF-backed ChromiumBrowserHostView: forwards public commands to its
// BrowserClient by token and turns CEF callbacks into lifecycle-gated
// delegate calls. The view never owns its client; dealloc detaches it.

#import "ChromiumCEFInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

using namespace chromiumkit;

@implementation ChromiumBrowserHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self initializeHost];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self initializeHost];
    return self;
}

- (void)initializeHost {
    _lifecycleState = ChromiumBrowserLifecycleStateCreating;
    _estimatedProgress = 0;
    _zoomLevel = 0;
    if (g_engine) {
        _chromiumToken = g_engine->AddHost(self);
    }
}

- (CefRefPtr<BrowserClient>)client {
    return g_engine ? g_engine->Client(self.chromiumToken) : nullptr;
}

- (void)loadURL:(NSURL *)URL {
    NSCAssert(NSThread.isMainThread, @"Browser commands require main");
    self.pendingURL = URL;
    if (!self.chromiumToken && g_engine) {
        self.chromiumToken = g_engine->AddHost(self);
    }
    if (CefRefPtr<BrowserClient> client = [self client]) client->Load(URL);
}
- (void)back {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Back();
}
- (void)forward {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Forward();
}
- (void)reload {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Reload();
}
- (void)stop {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Stop();
}
- (void)focusBrowser {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Focus();
}
- (void)setZoom:(double)zoomLevel {
    self.zoomLevel = zoomLevel;
    if (CefRefPtr<BrowserClient> client = [self client]) client->SetZoom(zoomLevel);
}
- (void)openDevTools {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->OpenDevTools();
    }
}
- (void)findText:(NSString *)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->Find(text, forward, matchCase, findNext);
    }
}
- (void)stopFindingAndClearSelection:(BOOL)clearSelection {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->StopFinding(clearSelection);
    }
}
- (void)printPage {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->PrintPage();
    }
}
- (void)savePage {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->SavePage();
    }
}
- (BOOL)executeJavaScript:(NSString *)script
                sourceURL:(NSURL *)sourceURL
                     line:(NSInteger)line {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        return client->ExecuteJavaScript(script, sourceURL, line);
    }
    return NO;
}
- (BOOL)sendMouseClickAtPoint:(NSPoint)point {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        return client->SendMouseClick(point);
    }
    return NO;
}
- (void)closeDevTools {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->CloseDevTools();
    }
}
- (void)close {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->Close(false);
    } else {
        [self cefDidClose];
    }
}

- (void)layout {
    [super layout];
    if (CefRefPtr<BrowserClient> client = [self client]) client->Layout();
}

- (void)dealloc {
    _delegate = nil;
    if (CefRefPtr<BrowserClient> client = [self client]) client->DetachHost();
}

- (void)cefDidCreate {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreating) return;
    self.lifecycleState = ChromiumBrowserLifecycleStateCreated;
    if ([self.delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidCreate:)]) {
        [self.delegate chromiumBrowserHostViewDidCreate:self];
    }
    NSURL *pending = self.pendingURL;
    self.pendingURL = nil;
    if (pending) [self loadURL:pending];
}

- (void)cefDidChangeURL:(NSURL *)URL {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.URL = URL;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeURL:)]) {
        [delegate chromiumBrowserHostView:self didChangeURL:URL];
    }
}
- (void)cefDidChangeTitle:(NSString *)title {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.title = title;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeTitle:)]) {
        [delegate chromiumBrowserHostView:self didChangeTitle:title];
    }
}
- (void)cefDidChangeFaviconURLs:(NSArray<NSURL *> *)URLs {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeFaviconURLs:)]) {
        [delegate chromiumBrowserHostView:self didChangeFaviconURLs:URLs];
    }
}
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.loading = loading;
    self.canGoBack = canGoBack;
    self.canGoForward = canGoForward;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeLoading:)]) {
        [delegate chromiumBrowserHostView:self didChangeLoading:loading];
    }
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeCanGoBack:)]) {
        [delegate chromiumBrowserHostView:self didChangeCanGoBack:canGoBack];
    }
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeCanGoForward:)]) {
        [delegate chromiumBrowserHostView:self
                   didChangeCanGoForward:canGoForward];
    }
}
- (void)cefDidChangeProgress:(double)progress {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.estimatedProgress = progress;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeProgress:)]) {
        [delegate chromiumBrowserHostView:self didChangeProgress:progress];
    }
}
- (void)cefDidFail:(NSError *)error {
    if (self.lifecycleState == ChromiumBrowserLifecycleStateClosed) return;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:
                         didFailNavigationWithError:)]) {
        [delegate chromiumBrowserHostView:self
              didFailNavigationWithError:error];
    }
}
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:
                         rendererTerminatedWithStatus:)]) {
        [delegate chromiumBrowserHostView:self
            rendererTerminatedWithStatus:status];
    }
}
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didUpdateFindMatchCount:
                                              activeMatchOrdinal:finalUpdate:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
                 didUpdateFindMatchCount:matchCount
                      activeMatchOrdinal:activeMatchOrdinal
                             finalUpdate:finalUpdate];
    }
}
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didUpdateDownloadWithIdentifier:
                              URL:suggestedFilename:receivedBytes:totalBytes:
                              percentComplete:state:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
          didUpdateDownloadWithIdentifier:identifier
                                      URL:URL
                        suggestedFilename:suggestedFilename
                            receivedBytes:receivedBytes
                               totalBytes:totalBytes
                          percentComplete:percentComplete
                                    state:state];
    }
}
- (void)cefDidRejectAuthenticationForURL:(NSURL *)URL {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRejectAuthenticationForURL:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
            didRejectAuthenticationForURL:URL];
    }
}
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(NSURL *)URL {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRejectCertificateError:forURL:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
               didRejectCertificateError:errorCode
                                   forURL:URL];
    }
}
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:
                     didRejectClientCertificateForHost:port:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
            didRejectClientCertificateForHost:host
                                        port:port];
    }
}
- (void)cefWillClose {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateClosed) {
        self.lifecycleState = ChromiumBrowserLifecycleStateClosing;
    }
}
- (void)cefDidClose {
    if (self.closeDelivered) return;
    self.closeDelivered = YES;
    self.lifecycleState = ChromiumBrowserLifecycleStateClosed;
    self.loading = NO;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidClose:)]) {
        [delegate chromiumBrowserHostViewDidClose:self];
    }
}

@end

#endif

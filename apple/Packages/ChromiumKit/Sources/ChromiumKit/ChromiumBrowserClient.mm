// BrowserClient lifetime, browser commands, and display/load event delivery
// to the host view. Callbacks for a browser that is not current, or that
// arrive while closing, are dropped so a closed host never sees late events.

#import "ChromiumCEFInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

namespace chromiumkit {

namespace {

/// Chrome style without Chrome's toolbar: the window shows only the extension
/// page, as Chrome's own toolbar popups do.
class ExtensionBrowserViewDelegate final : public CefBrowserViewDelegate {
 public:
    ExtensionBrowserViewDelegate() = default;

    cef_runtime_style_t GetBrowserRuntimeStyle() override {
        return CEF_RUNTIME_STYLE_CHROME;
    }
    ChromeToolbarType GetChromeToolbarType(
        CefRefPtr<CefBrowserView> browser_view) override {
        return CEF_CTT_NONE;
    }

 private:
    IMPLEMENT_REFCOUNTING(ExtensionBrowserViewDelegate);
};

/// The CEF-owned top-level window an extension popup or window lives in.
/// Holds its client until CEF destroys the window, so window callbacks never
/// reach a released client.
class ExtensionWindowDelegate final : public CefWindowDelegate {
 public:
    ExtensionWindowDelegate(CefRefPtr<BrowserClient> client,
                            CefRefPtr<CefBrowserView> browser_view,
                            const CefRect& bounds,
                            bool popup)
        : client_(client),
          browser_view_(browser_view),
          bounds_(bounds),
          popup_(popup) {}

    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        if (client_) client_->ViewsWindowCreated(window);
    }
    void OnWindowDestroyed(CefRefPtr<CefWindow> window) override {
        browser_view_ = nullptr;
        CefRefPtr<BrowserClient> client = client_;
        client_ = nullptr;
        if (client) client->ViewsWindowDestroyed();
    }
    void OnWindowActivationChanged(CefRefPtr<CefWindow> window,
                                   bool active) override {
        if (client_) client_->ViewsWindowActivationChanged(active);
    }
    bool CanClose(CefRefPtr<CefWindow> window) override {
        // The standard Views close handshake: the window may close once the
        // browser has run its unload handlers (DoClose returned false).
        CefRefPtr<CefBrowser> browser =
            browser_view_ ? browser_view_->GetBrowser() : nullptr;
        return browser ? browser->GetHost()->TryCloseBrowser() : true;
    }
    CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override {
        return bounds_;
    }
    bool IsFrameless(CefRefPtr<CefWindow> window) override { return popup_; }
    bool CanResize(CefRefPtr<CefWindow> window) override { return !popup_; }
    bool CanMaximize(CefRefPtr<CefWindow> window) override { return false; }
    bool CanMinimize(CefRefPtr<CefWindow> window) override { return !popup_; }
    cef_runtime_style_t GetWindowRuntimeStyle() override {
        return CEF_RUNTIME_STYLE_CHROME;
    }

 private:
    CefRefPtr<BrowserClient> client_;
    CefRefPtr<CefBrowserView> browser_view_;
    const CefRect bounds_;
    const bool popup_;
    IMPLEMENT_REFCOUNTING(ExtensionWindowDelegate);
};

}  // namespace

bool BrowserClient::CreateViewsBrowser(ChromiumBrowserHostView *host) {
    // Views uses DIP screen coordinates with the origin at the top-left of
    // the primary display; AppKit's origin is that display's bottom-left.
    const NSRect frame = host.extensionScreenFrame;
    NSScreen *primary = NSScreen.screens.firstObject;
    const CGFloat primary_top = primary ? NSMaxY(primary.frame) : NSMaxY(frame);
    const CefRect bounds(
        static_cast<int>(std::lround(NSMinX(frame))),
        static_cast<int>(std::lround(primary_top - NSMaxY(frame))),
        std::max(1, static_cast<int>(std::lround(NSWidth(frame)))),
        std::max(1, static_cast<int>(std::lround(NSHeight(frame)))));
    CefBrowserSettings settings;
    views_browser_view_ = CefBrowserView::CreateBrowserView(
        this, "about:blank", settings, nullptr, nullptr,
        new ExtensionBrowserViewDelegate());
    if (!views_browser_view_) {
        return false;
    }
    views_window_ = CefWindow::CreateTopLevelWindow(new ExtensionWindowDelegate(
        this, views_browser_view_, bounds, views_popup_));
    if (!views_window_) {
        views_browser_view_ = nullptr;
        return false;
    }
    return true;
}

void BrowserClient::ViewsWindowCreated(CefRefPtr<CefWindow> window) {
    CEF_REQUIRE_UI_THREAD();
    if (!views_browser_view_) {
        window->Close();
        return;
    }
    // Adding the view creates the browser (OnAfterCreated follows).
    window->AddChildView(views_browser_view_);
    NSView *handle =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(window->GetWindowHandle());
    NSWindow *native = [handle isKindOfClass:NSWindow.class]
        ? (NSWindow *)handle
        : handle.window;
    if (views_popup_) {
        // Above ordinary windows, and gone when Pilot is not active, so page
        // content in a pane can never draw over or stand in for wallet UI.
        native.level = NSFloatingWindowLevel;
        native.hidesOnDeactivate = YES;
    }
    window->Show();
    // On macOS the window CEF builds from GetInitialBounds came out about a
    // title bar taller than asked and not where asked, even frameless, so
    // the exact AppKit frame Pilot computed is applied once it is shown.
    ChromiumBrowserHostView *host = host_;
    if (native && host) {
        [native setFrame:host.extensionScreenFrame display:YES];
    }
    views_browser_view_->RequestFocus();
}

void BrowserClient::ViewsWindowActivationChanged(bool active) {
    CEF_REQUIRE_UI_THREAD();
    if (views_popup_ && !active && !closing_ && browser_) {
        [host_ cefPopupDidResignActive];
    }
}

void BrowserClient::ViewsWindowDestroyed() {
    CEF_REQUIRE_UI_THREAD();
    views_window_ = nullptr;
    views_browser_view_ = nullptr;
    if (!browser_ && !closed_) {
        // The window went away before a browser was ever created.
        FinishWithoutBrowser(nil);
    }
}

bool BrowserClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                  const CefKeyEvent& event,
                                  CefEventHandle os_event,
                                  bool* is_keyboard_shortcut) {
    CEF_REQUIRE_UI_THREAD();
    // Escape dismisses an extension popup before the page sees it, as
    // Chrome's own toolbar popups do. (Chrome style otherwise maps Escape to
    // its Stop command, which OnChromeCommand refuses.)
    constexpr int kEscapeKeyCode = 0x1B;
    if (views_popup_ && !closing_ && IsCurrent(browser) &&
        event.type == KEYEVENT_RAWKEYDOWN &&
        event.windows_key_code == kEscapeKeyCode &&
        (event.modifiers & (EVENTFLAG_SHIFT_DOWN | EVENTFLAG_CONTROL_DOWN |
                            EVENTFLAG_ALT_DOWN | EVENTFLAG_COMMAND_DOWN)) == 0) {
        Close(false);
        return true;
    }
    return false;
}

bool BrowserClient::OnChromeCommand(CefRefPtr<CefBrowser> browser,
                                    int command_id,
                                    cef_window_open_disposition_t disposition) {
    CEF_REQUIRE_UI_THREAD();
    // Only Chrome-style browsers (extension popups and windows) reach this.
    // Clipboard editing keeps Chrome's implementation; every other Chrome
    // command (new tab/window, incognito, settings, history, downloads,
    // DevTools, print, save, ...) is refused so extension UI cannot open
    // browser UI that bypasses Pilot's panes and policies.
    switch (command_id) {
        case IDC_CUT:
        case IDC_COPY:
        case IDC_PASTE:
            return false;
        default:
            return true;
    }
}

void BrowserClient::Create() {
    CEF_REQUIRE_UI_THREAD();
    if (create_requested_ || closed_) {
        return;
    }
    if (closing_ || host_ == nil) {
        FinishWithoutBrowser(nil);
        return;
    }

    ChromiumBrowserHostView *host = host_;
    if (views_hosted_) {
        create_requested_ = true;
        if (!CreateViewsBrowser(host)) {
            FinishWithoutBrowser(ChromiumKitError(
                ChromiumKitErrorBrowserCreationFailed,
                @"CEF rejected the extension window.", nil));
        }
        return;
    }
    CefWindowInfo window_info;
    const int width = std::max(1, static_cast<int>(NSWidth(host.bounds)));
    const int height = std::max(1, static_cast<int>(NSHeight(host.bounds)));
    window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(host),
                           CefRect(0, 0, width, height));
    // CEF always uses Alloy style for a browser with an application-provided
    // parent view (cef_window_info_t.runtime_style), so say so instead of
    // requesting Chrome style and having CEF log a fallback. Extension UI
    // that needs Chrome style uses an extension popup or window host.
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    create_requested_ = true;
    if (!CefBrowserHost::CreateBrowser(window_info, this, "about:blank",
                                       settings, nullptr, nullptr)) {
        FinishWithoutBrowser(ChromiumKitError(
            ChromiumKitErrorBrowserCreationFailed,
            @"CEF rejected the browser creation request.", nil));
    }
}

void BrowserClient::Close(bool force) {
    CEF_REQUIRE_UI_THREAD();
    if (closed_) {
        return;
    }
    if (closing_) {
        if (force && browser_) {
            browser_->GetHost()->CloseBrowser(true);
        }
        return;
    }
    closing_ = true;
    [host_ cefWillClose];
    if (browser_) {
        browser_->GetHost()->CloseBrowser(force);
    } else if (!create_requested_) {
        FinishWithoutBrowser(nil);
    }
}

void BrowserClient::DetachHost() {
    CEF_REQUIRE_UI_THREAD();
    host_ = nil;
    Close(true);
}

void BrowserClient::FinishWithoutBrowser(NSError *error) {
    CefRefPtr<BrowserClient> keep_alive(this);
    if (closed_) {
        return;
    }
    closed_ = true;
    if (error) {
        [host_ cefDidFail:error];
    }
    [host_ cefDidClose];
    host_ = nil;
    engine_->ClientClosed(token_);
}

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (browser_) {
        return;
    }
    browser_ = browser;
    Layout();
    if (closing_ || host_ == nil) {
        browser_->GetHost()->CloseBrowser(true);
        return;
    }
    [host_ cefDidCreate];
}

bool BrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return false;
    }
    closing_ = true;
    [host_ cefWillClose];
    if (views_hosted_) {
        // Returning false makes CEF close the host's CefWindow, which
        // destroys the browser view; its view hierarchy is CEF's own.
        return false;
    }
    NSView *browser_view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [browser_view removeFromSuperview];
    return false;
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return;
    }
    CefRefPtr<BrowserClient> keep_alive(this);
    browser_ = nullptr;
    closed_ = true;
    [host_ cefDidClose];
    host_ = nil;
    engine_->ClientClosed(token_);
}

void BrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    const CefString& url) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser) && frame->IsMain()) {
        NSURL *URL = [NSURL URLWithString:NSStringFromCef(url)];
        if (URL) {
            [host_ cefDidChangeURL:URL];
        }
        // Same-document navigations (for example, history.pushState in an
        // IDE preview SPA) update the address without necessarily producing
        // an OnLoadingStateChange callback. Refresh the native history state
        // here as well so Back and Forward do not remain incorrectly disabled.
        [host_ cefDidChangeLoading:browser->IsLoading()
                         canGoBack:browser->CanGoBack()
                      canGoForward:browser->CanGoForward()];
    }
}

void BrowserClient::OnFindResult(CefRefPtr<CefBrowser> browser,
                                 int identifier,
                                 int count,
                                 const CefRect& selection_rect,
                                 int active_match_ordinal,
                                 bool final_update) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidUpdateFindMatchCount:count
                      activeMatchOrdinal:active_match_ordinal
                             finalUpdate:final_update];
    }
}

// JavaScript dialogs are presented by the delegate (Pilot attaches them to
// its window) instead of CEF's free-floating default alert. The bridge passes
// page strings through untouched; the delegate treats them as untrusted.
bool BrowserClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                               const CefString& origin_url,
                               JSDialogType dialog_type,
                               const CefString& message_text,
                               const CefString& default_prompt_text,
                               CefRefPtr<CefJSDialogCallback> callback,
                               bool& suppress_message) {
    CEF_REQUIRE_UI_THREAD();
    suppress_message = false;
    ChromiumBrowserHostView *host = host_;
    if (closing_ || !IsCurrent(browser) || host == nil) {
        // A closing or detached browser has no window to attach a dialog
        // to; the page receives the default (false or null) result.
        suppress_message = true;
        return false;
    }
    if (![host cefHandlesJavaScriptDialogs]) {
        return false;
    }
    ChromiumJavaScriptDialogKind kind;
    switch (dialog_type) {
        case JSDIALOGTYPE_ALERT:
            kind = ChromiumJavaScriptDialogKindAlert;
            break;
        case JSDIALOGTYPE_CONFIRM:
            kind = ChromiumJavaScriptDialogKindConfirm;
            break;
        case JSDIALOGTYPE_PROMPT:
            kind = ChromiumJavaScriptDialogKindPrompt;
            break;
        default:
            suppress_message = true;
            return false;
    }
    CefRefPtr<CefJSDialogCallback> retained = callback;
    ChromiumJavaScriptDialogRequest *request =
        [[ChromiumJavaScriptDialogRequest alloc]
                 initWithKind:kind
                    originURL:NSURLFromCef(origin_url)
                      message:NSStringFromCef(message_text)
            defaultPromptText:NSStringFromCef(default_prompt_text)
                       reload:NO
              decisionHandler:^(BOOL accepted, NSString *userInput) {
                  retained->Continue(
                      accepted,
                      CefString(userInput.UTF8String ?: ""));
              }];
    if (![host cefPresentJavaScriptDialog:request]) {
        [request invalidate];
        return false;
    }
    return true;
}

bool BrowserClient::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString& message_text,
    bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_) {
        // Pilot already removed the pane, so there is nowhere to stay: a
        // "Stay" answer would keep an invisible browser alive. Leave.
        callback->Continue(true, CefString());
        return true;
    }
    ChromiumBrowserHostView *host = host_;
    if (!IsCurrent(browser) || host == nil ||
        ![host cefHandlesJavaScriptDialogs]) {
        return false;
    }
    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    NSURL *origin = frame ? NSURLFromCef(frame->GetURL()) : nil;
    CefRefPtr<CefJSDialogCallback> retained = callback;
    ChromiumJavaScriptDialogRequest *request =
        [[ChromiumJavaScriptDialogRequest alloc]
                 initWithKind:ChromiumJavaScriptDialogKindBeforeUnload
                    originURL:origin
                      message:NSStringFromCef(message_text)
            defaultPromptText:@""
                       reload:is_reload
              decisionHandler:^(BOOL accepted, NSString *userInput) {
                  retained->Continue(accepted, CefString());
              }];
    if (![host cefPresentJavaScriptDialog:request]) {
        [request invalidate];
        return false;
    }
    return true;
}

void BrowserClient::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (IsCurrent(browser)) {
        [host_ cefDidResetJavaScriptDialogs];
    }
}

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                  const CefString& title) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeTitle:NSStringFromCef(title)];
    }
}

void BrowserClient::OnFaviconURLChange(
    CefRefPtr<CefBrowser> browser,
    const std::vector<CefString>& icon_urls) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        NSMutableArray<NSURL *> *URLs = [NSMutableArray array];
        for (const CefString& icon_url : icon_urls) {
            NSURL *URL = [NSURL URLWithString:NSStringFromCef(icon_url)];
            if (URL) [URLs addObject:URL];
        }
        [host_ cefDidChangeFaviconURLs:URLs];
    }
}

void BrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                            double progress) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeProgress:progress];
    }
}

void BrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                         bool is_loading,
                                         bool can_go_back,
                                         bool can_go_forward) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeLoading:is_loading
                         canGoBack:can_go_back
                      canGoForward:can_go_forward];
    }
}

void BrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                ErrorCode error_code,
                                const CefString& error_text,
                                const CefString& failed_url) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser) || !frame->IsMain()) {
        return;
    }
    NSString *URLString = NSStringFromCef(failed_url);
    NSURL *URL = [NSURL URLWithString:URLString];
    NSDictionary *details = URL
        ? @{@"ChromiumNetError": @(error_code),
            NSURLErrorFailingURLErrorKey: URL}
        : @{@"ChromiumNetError": @(error_code)};
    [host_ cefDidFail:ChromiumKitError(
                          ChromiumKitErrorNavigationFailed,
                          NSStringFromCef(error_text),
                          details)];
}

void BrowserClient::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser,
    TerminationStatus status,
    int error_code,
    const CefString& error_string) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser)) {
        return;
    }
    ChromiumRendererTerminationStatus mapped =
        ChromiumRendererTerminationStatusAbnormal;
    switch (status) {
        case TS_PROCESS_WAS_KILLED:
            mapped = ChromiumRendererTerminationStatusKilled;
            break;
        case TS_PROCESS_CRASHED:
            mapped = ChromiumRendererTerminationStatusCrashed;
            break;
        case TS_PROCESS_OOM:
            mapped = ChromiumRendererTerminationStatusOutOfMemory;
            break;
        case TS_LAUNCH_FAILED:
            mapped = ChromiumRendererTerminationStatusLaunchFailed;
            break;
        case TS_INTEGRITY_FAILURE:
            mapped = ChromiumRendererTerminationStatusIntegrityFailure;
            break;
        default:
            break;
    }
    [host_ cefRendererTerminated:mapped];
}

void BrowserClient::Load(NSURL *URL) {
    CEF_REQUIRE_UI_THREAD();
    if (browser_ && !closing_) {
        browser_->GetMainFrame()->LoadURL(URL.absoluteString.UTF8String);
    }
}

void BrowserClient::Back() {
    if (!browser_ || closing_) return;
    CefRefPtr<CefFrame> frame = browser_->GetMainFrame();
    if (!frame) {
        browser_->GoBack();
        return;
    }
    // CefBrowser::GoBack does not traverse same-document History API entries
    // in Chrome runtime style. Asking the document history to navigate does,
    // and also covers regular cross-document entries.
    frame->ExecuteJavaScript("window.history.back();",
                             "pilot://browser-command/back", 1);
}
void BrowserClient::Forward() {
    if (!browser_ || closing_) return;
    CefRefPtr<CefFrame> frame = browser_->GetMainFrame();
    if (!frame) {
        browser_->GoForward();
        return;
    }
    frame->ExecuteJavaScript("window.history.forward();",
                             "pilot://browser-command/forward", 1);
}
void BrowserClient::Reload() {
    if (browser_ && !closing_) browser_->Reload();
}
void BrowserClient::Stop() {
    if (browser_ && !closing_) browser_->StopLoad();
}
void BrowserClient::Focus() {
    if (!browser_ || closing_) return;
    if (views_hosted_) {
        if (views_window_) views_window_->Activate();
        if (views_browser_view_) views_browser_view_->RequestFocus();
        return;
    }
    browser_->GetHost()->SetFocus(true);
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    NSWindow *window = host_.window;
    // SetFocus makes Chromium's content view first responder. Claiming it for
    // the browser's container afterwards took keyboard focus back off the
    // page, so only do so when focus is still outside the browser.
    NSResponder *responder = window.firstResponder;
    if (view && [responder isKindOfClass:NSView.class] &&
        [(NSView *)responder isDescendantOf:view]) {
        return;
    }
    [window makeFirstResponder:view];
}
void BrowserClient::SetZoom(double level) {
    if (browser_ && !closing_) browser_->GetHost()->SetZoomLevel(level);
}
void BrowserClient::OpenDevTools() {
    CEF_REQUIRE_UI_THREAD();
    if (!browser_ || closing_) return;
    CefWindowInfo window_info;
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    browser_->GetHost()->ShowDevTools(window_info, this, settings, CefPoint());
}
void BrowserClient::CloseDevTools() {
    if (browser_ && !closing_) browser_->GetHost()->CloseDevTools();
}
void BrowserClient::Find(NSString *text,
                         bool forward,
                         bool match_case,
                         bool find_next) {
    if (browser_ && !closing_) {
        browser_->GetHost()->Find(text.UTF8String, forward, match_case,
                                  find_next);
    }
}
void BrowserClient::StopFinding(bool clear_selection) {
    if (browser_ && !closing_) {
        browser_->GetHost()->StopFinding(clear_selection);
    }
}
void BrowserClient::PrintPage() {
    if (!browser_ || closing_) return;
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector = @selector(chromiumBrowserHostViewShouldPrint:);
    if ([delegate respondsToSelector:selector] &&
        [delegate chromiumBrowserHostViewShouldPrint:host]) {
        browser_->GetHost()->Print();
    }
}
void BrowserClient::SavePage() {
    if (!browser_ || closing_) return;
    CefString page_url = browser_->GetMainFrame()->GetURL();
    NSURL *URL = NSURLFromCef(page_url);
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldSavePageURL:);
    if (URL && [delegate respondsToSelector:selector] &&
        [delegate chromiumBrowserHostView:host shouldSavePageURL:URL]) {
        browser_->GetHost()->StartDownload(page_url);
    }
}
bool BrowserClient::ExecuteJavaScript(NSString *script,
                                      NSURL *source_url,
                                      NSInteger line) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser_ || closing_ || script.length == 0 || line < 1) {
        return false;
    }
    const char *source = source_url
        ? source_url.absoluteString.UTF8String
        : "pilot://chromium-runtime-probe";
    browser_->GetMainFrame()->ExecuteJavaScript(
        script.UTF8String,
        source,
        static_cast<int>(line));
    return true;
}

bool BrowserClient::SendMouseClick(NSPoint point) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    if (!browser_ || closing_ || host == nil ||
        !NSPointInRect(point, host.bounds)) {
        return false;
    }
    CefMouseEvent event;
    event.x = static_cast<int>(std::lround(point.x));
    event.y = static_cast<int>(
        std::lround(NSHeight(host.bounds) - point.y));
    event.modifiers = 0;
    browser_->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, false, 1);
    browser_->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, true, 1);
    return true;
}
void BrowserClient::Layout() {
    // An extension host's CefWindow lays out its own browser view.
    if (!browser_ || views_hosted_) return;
    ChromiumBrowserHostView *host = host_;
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    view.frame = host.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

}  // namespace chromiumkit

#endif

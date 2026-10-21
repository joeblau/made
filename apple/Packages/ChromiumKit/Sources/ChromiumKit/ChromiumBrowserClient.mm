// BrowserClient lifetime, browser commands, and display/load event delivery
// to the host view. Callbacks for a browser that is not current, or that
// arrive while closing, are dropped so a closed host never sees late events.

#import "ChromiumCEFInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

namespace chromiumkit {

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
    CefWindowInfo window_info;
    const int width = std::max(1, static_cast<int>(NSWidth(host.bounds)));
    const int height = std::max(1, static_cast<int>(NSHeight(host.bounds)));
    window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(host),
                           CefRect(0, 0, width, height));
    // SPIKE(rabby-extension): Chrome-style windows so extension UI (action
    // popups, tabs APIs) behaves; was CEF_RUNTIME_STYLE_ALLOY.
    window_info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
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
    browser_->GetHost()->SetFocus(true);
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    [host_.window makeFirstResponder:view];
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
    if (!browser_) return;
    ChromiumBrowserHostView *host = host_;
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    view.frame = host.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

}  // namespace chromiumkit

#endif

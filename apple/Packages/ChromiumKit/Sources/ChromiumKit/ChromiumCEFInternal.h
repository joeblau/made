#pragma once

// Private C++ declarations for the CEF-backed implementation units. Included
// only when BLAU_CHROMIUM_CEF_ENABLED; the artifact-free build never sees CEF.
//
// Ownership: ChromiumEngine owns one EngineCore (g_engine) from start until
// CEF shutdown completes; EngineCore deletes itself after CefShutdown. The
// EngineCore's token map holds the only owning references to BrowserClients;
// a client removes itself through ClientClosed exactly once, which is what
// activeBrowserCount and asynchronous shutdown account for. Clients hold
// their host view weakly.
//
// Thread contract: main thread only, except the CefResourceRequestHandler
// and GetAuthCredentials callbacks noted in ChromiumRequestPolicy.mm.

#import "ChromiumKitInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

#if !__has_include("include/cef_app.h")
#error "BLAU_CHROMIUM_CEF_ENABLED requires the pinned CEF headers"
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>
#include <string>
#include <vector>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace chromiumkit {

class BrowserClient;
class EngineCore;

/// The live engine, or null before start and after shutdown completes.
/// Main thread only.
extern EngineCore *g_engine;

inline NSString *NSStringFromCef(const CefString& value) {
    const std::string utf8 = value.ToString();
    NSString *result =
        [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding];
    return result ?: @"";
}

inline NSURL *NSURLFromCef(const CefString& value) {
    NSString *string = NSStringFromCef(value);
    return string.length ? [NSURL URLWithString:string] : nil;
}

class BrowserClient final : public CefClient,
                            public CefContextMenuHandler,
                            public CefDialogHandler,
                            public CefDisplayHandler,
                            public CefDownloadHandler,
                            public CefFindHandler,
                            public CefLifeSpanHandler,
                            public CefLoadHandler,
                            public CefPermissionHandler,
                            public CefRequestHandler,
                            public CefResourceRequestHandler {
 public:
    BrowserClient(EngineCore *engine,
                  uint64_t token,
                  ChromiumBrowserHostView *host)
        : engine_(engine), token_(token), host_(host) {}

    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
        return this;
    }
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
        return this;
    }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        bool is_navigation,
        bool is_download,
        const CefString& request_initiator,
        bool& disable_default_handling) override {
        disable_default_handling = false;
        return this;
    }

    void Create();
    void Close(bool force);
    void DetachHost();
    void Load(NSURL *URL);
    void Back();
    void Forward();
    void Reload();
    void Stop();
    void Focus();
    void SetZoom(double level);
    void OpenDevTools();
    void CloseDevTools();
    void Find(NSString *text, bool forward, bool match_case, bool find_next);
    void StopFinding(bool clear_selection);
    void PrintPage();
    void SavePage();
    bool ExecuteJavaScript(NSString *script, NSURL *source_url, NSInteger line);
    bool SendMouseClick(NSPoint point);
    void Layout();

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override;
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popup_features,
                       CefWindowInfo& window_info,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override;
    void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefRequest> request,
                             bool& allow_os_execution) override;
    bool OnRequestMediaAccessPermission(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefMediaAccessCallback> callback) override;
    bool OnShowPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefPermissionPromptCallback> callback) override;
    bool CanDownload(CefRefPtr<CefBrowser> browser,
                     const CefString& url,
                     const CefString& request_method) override;
    bool OnBeforeDownload(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefDownloadItem> download_item,
        const CefString& suggested_name,
        CefRefPtr<CefBeforeDownloadCallback> callback) override;
    void OnDownloadUpdated(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefDownloadItem> download_item,
        CefRefPtr<CefDownloadItemCallback> callback) override;
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override;
    bool OnFileDialog(
        CefRefPtr<CefBrowser> browser,
        FileDialogMode mode,
        const CefString& title,
        const CefString& default_file_path,
        const std::vector<CefString>& accept_filters,
        const std::vector<CefString>& accept_extensions,
        const std::vector<CefString>& accept_descriptions,
        CefRefPtr<CefFileDialogCallback> callback) override;
    void OnFindResult(CefRefPtr<CefBrowser> browser,
                      int identifier,
                      int count,
                      const CefRect& selection_rect,
                      int active_match_ordinal,
                      bool final_update) override;
    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                            const CefString& origin_url,
                            bool is_proxy,
                            const CefString& host,
                            int port,
                            const CefString& realm,
                            const CefString& scheme,
                            CefRefPtr<CefAuthCallback> callback) override;
    bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                            cef_errorcode_t cert_error,
                            const CefString& request_url,
                            CefRefPtr<CefSSLInfo> ssl_info,
                            CefRefPtr<CefCallback> callback) override;
    bool OnSelectClientCertificate(
        CefRefPtr<CefBrowser> browser,
        bool is_proxy,
        const CefString& host,
        int port,
        const X509CertificateList& certificates,
        CefRefPtr<CefSelectClientCertificateCallback> callback) override;
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
    bool DoClose(CefRefPtr<CefBrowser> browser) override;
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override;
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override;
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                           const std::vector<CefString>& icon_urls) override;
    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                 double progress) override;
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool is_loading,
                              bool can_go_back,
                              bool can_go_forward) override;
    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode error_code,
                     const CefString& error_text,
                     const CefString& failed_url) override;
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status,
                                   int error_code,
                                   const CefString& error_string) override;

 private:
    bool IsCurrent(CefRefPtr<CefBrowser> browser) const {
        return browser_ && browser_->IsSame(browser);
    }
    void FinishWithoutBrowser(NSError *error);

    EngineCore *engine_;
    const uint64_t token_;
    __weak ChromiumBrowserHostView *host_;
    CefRefPtr<CefBrowser> browser_;
    bool create_requested_ = false;
    bool closing_ = false;
    bool closed_ = false;
    IMPLEMENT_REFCOUNTING(BrowserClient);
};

/// Process-wide CEF lifecycle: library load, CefInitialize, the browser
/// client registry, and asynchronous shutdown once every client has closed.
class EngineCore final {
 public:
    explicit EngineCore(ChromiumEngine *owner) : owner_(owner) {}

    bool Start(NSURL *profile, NSError **error);
    uint64_t AddHost(ChromiumBrowserHostView *host);
    CefRefPtr<BrowserClient> Client(uint64_t token);
    size_t ClientCount() const;
    void ContextReady();
    void ClientClosed(uint64_t token);
    void Shutdown();

 private:
    void FinishShutdownIfReady();
    void FinishShutdown();

    friend class BrowserClient;
    __weak ChromiumEngine *owner_;
    std::unique_ptr<CefScopedLibraryLoader> loader_;
    CefRefPtr<CefApp> app_;
    std::unordered_map<uint64_t, CefRefPtr<BrowserClient>> clients_;
    uint64_t next_token_ = 1;
    bool initialized_ = false;
    bool context_ready_ = false;
    bool shutting_down_ = false;
    bool finish_scheduled_ = false;
};

}  // namespace chromiumkit

#endif

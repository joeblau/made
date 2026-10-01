// Fail-closed request policy: navigation, popups, external protocols,
// permissions, downloads, context menus, file choosers, authentication, and
// certificates. Decisions go to Pilot's delegate where a typed method exists
// and fail closed otherwise; authentication challenges and certificate errors
// are always rejected and only reported.
//
// Thread contract: UI-thread callbacks run on main. OnProtocolExecution runs
// on the CEF IO thread and touches no Objective-C state; GetAuthCredentials
// runs on the IO thread and hops to main before notifying the host.

#import "ChromiumCEFInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

namespace chromiumkit {

namespace {
static ChromiumPermissionKind PermissionKindsFromPrompt(
    uint32_t requested_permissions) {
    ChromiumPermissionKind kinds = 0;
    uint32_t known_permissions = 0;
#define MAP_PERMISSION(cef_kind, chromium_kind) \
    if (requested_permissions & cef_kind) {     \
        kinds |= chromium_kind;                 \
        known_permissions |= cef_kind;          \
    }
    MAP_PERMISSION(CEF_PERMISSION_TYPE_CAMERA_STREAM,
                   ChromiumPermissionKindVideoCapture)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_CLIPBOARD,
                   ChromiumPermissionKindClipboard)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_GEOLOCATION,
                   ChromiumPermissionKindGeolocation)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_MIC_STREAM,
                   ChromiumPermissionKindAudioCapture)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_MIDI_SYSEX,
                   ChromiumPermissionKindMIDISystemExclusive)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_NOTIFICATIONS,
                   ChromiumPermissionKindNotifications)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS,
                   ChromiumPermissionKindFileSystemAccess)
#undef MAP_PERMISSION
    if ((requested_permissions & ~known_permissions) != 0 || kinds == 0) {
        kinds |= ChromiumPermissionKindOther;
    }
    return kinds;
}
}  // namespace

bool BrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   bool user_gesture,
                                   bool is_redirect) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser) || !frame->IsMain()) {
        return false;
    }
    NSURL *URL = [NSURL URLWithString:NSStringFromCef(request->GetURL())];
    if (!URL) {
        return true;
    }

    ChromiumNavigationDecision decision = ChromiumNavigationDecisionAllow;
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:decideNavigationToURL:
                                                userGesture:isRedirect:);
    if ([delegate respondsToSelector:selector]) {
        decision = [delegate chromiumBrowserHostView:host
                              decideNavigationToURL:URL
                                        userGesture:user_gesture
                                         isRedirect:is_redirect];
    }
    if (decision == ChromiumNavigationDecisionOpenExternally) {
        SEL externalSelector =
            @selector(chromiumBrowserHostView:shouldOpenExternalURL:);
        if ([delegate respondsToSelector:externalSelector] &&
            [delegate chromiumBrowserHostView:host
                        shouldOpenExternalURL:URL]) {
            [NSWorkspace.sharedWorkspace openURL:URL];
        }
        return true;
    }
    return decision == ChromiumNavigationDecisionCancel;
}

bool BrowserClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
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
    bool* no_javascript_access) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return true;
    }

    ChromiumPopupDisposition disposition = ChromiumPopupDispositionUnknown;
    switch (target_disposition) {
        case CEF_WOD_NEW_FOREGROUND_TAB:
            disposition = ChromiumPopupDispositionForegroundTab;
            break;
        case CEF_WOD_NEW_BACKGROUND_TAB:
            disposition = ChromiumPopupDispositionBackgroundTab;
            break;
        case CEF_WOD_NEW_POPUP:
            disposition = ChromiumPopupDispositionPopup;
            break;
        case CEF_WOD_NEW_WINDOW:
            disposition = ChromiumPopupDispositionWindow;
            break;
        default:
            break;
    }
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPopup:disposition:
                                                      userGesture:);
    if ([delegate respondsToSelector:selector]) {
        NSString *target = NSStringFromCef(target_url);
        NSURL *URL = target.length ? [NSURL URLWithString:target] : nil;
        if (!URL) {
            return true;
        }
        [delegate chromiumBrowserHostView:host
                         didRequestPopup:URL
                             disposition:disposition
                             userGesture:user_gesture];
    }
    // Popups are always canceled here. Pilot may create a managed pane from
    // the typed delegate callback, but CEF never creates an unmanaged window.
    return true;
}

void BrowserClient::OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefRequest> request,
                                        bool& allow_os_execution) {
    // This CefResourceRequestHandler callback runs on the IO thread. Unknown
    // protocols are always denied here; user-confirmed external opens are
    // performed explicitly from OnBeforeBrowse on the UI thread.
    allow_os_execution = false;
}

bool BrowserClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumPermissionKind kinds = 0;
    uint32_t known_permissions = 0;
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
        kinds |= ChromiumPermissionKindAudioCapture;
        known_permissions |= CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
    }
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
        kinds |= ChromiumPermissionKindVideoCapture;
        known_permissions |= CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    }
    if ((requested_permissions & ~known_permissions) != 0 || kinds == 0) {
        kinds |= ChromiumPermissionKindOther;
    }
    NSURL *origin =
        [NSURL URLWithString:NSStringFromCef(requesting_origin)] ?:
        [NSURL URLWithString:@"about:blank"];
    CefRefPtr<CefMediaAccessCallback> retained = callback;
    ChromiumPermissionRequest *permission =
        [[ChromiumPermissionRequest alloc]
            initWithOrigin:origin
                     kinds:kinds
         rawPermissionMask:requested_permissions
           decisionHandler:^(BOOL allowed) {
               retained->Continue(allowed ? requested_permissions : 0);
           }];
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPermission:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:host
                     didRequestPermission:permission];
    } else {
        [permission deny];
    }
    return true;
}

bool BrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    NSURL *origin =
        [NSURL URLWithString:NSStringFromCef(requesting_origin)] ?:
        [NSURL URLWithString:@"about:blank"];
    CefRefPtr<CefPermissionPromptCallback> retained = callback;
    ChromiumPermissionRequest *permission =
        [[ChromiumPermissionRequest alloc]
            initWithOrigin:origin
                     kinds:PermissionKindsFromPrompt(requested_permissions)
         rawPermissionMask:requested_permissions
           decisionHandler:^(BOOL allowed) {
               retained->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT
                                          : CEF_PERMISSION_RESULT_DENY);
           }];
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPermission:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:host
                     didRequestPermission:permission];
    } else {
        [permission deny];
    }
    return true;
}

bool BrowserClient::CanDownload(CefRefPtr<CefBrowser> browser,
                                const CefString& url,
                                const CefString& request_method) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    return !closing_ && IsCurrent(browser) &&
           [delegate respondsToSelector:
               @selector(chromiumBrowserHostView:shouldDownloadURL:
                                                   suggestedFilename:)];
}

bool BrowserClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldDownloadURL:
                                            suggestedFilename:);
    NSURL *URL = [NSURL URLWithString:NSStringFromCef(download_item->GetURL())];
    NSString *name = NSStringFromCef(suggested_name);
    if (!URL || ![delegate respondsToSelector:selector] ||
        ![delegate chromiumBrowserHostView:host
                        shouldDownloadURL:URL
                        suggestedFilename:name]) {
        return false;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = name.lastPathComponent;
    CefRefPtr<CefBeforeDownloadCallback> retained = callback;
    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) {
            retained->Continue(panel.URL.path.UTF8String, false);
        }
    };
    if (host.window) {
        [panel beginSheetModalForWindow:host.window
                     completionHandler:completion];
    } else {
        [panel beginWithCompletionHandler:completion];
    }
    return true;
}

void BrowserClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    if (closing_ || !host || !IsCurrent(browser)) {
        if (download_item->IsValid() && download_item->IsInProgress()) {
            callback->Cancel();
        }
        return;
    }
    if (!download_item->IsValid()) {
        return;
    }
    NSURL *URL = NSURLFromCef(download_item->GetURL());
    if (!URL) {
        if (download_item->IsInProgress()) {
            callback->Cancel();
        }
        return;
    }
    ChromiumDownloadState state = ChromiumDownloadStateInProgress;
    if (download_item->IsCanceled()) {
        state = ChromiumDownloadStateCanceled;
    } else if (download_item->IsInterrupted()) {
        state = ChromiumDownloadStateInterrupted;
    } else if (download_item->IsComplete()) {
        NSString *fullPath = NSStringFromCef(download_item->GetFullPath());
        NSURL *fileURL = fullPath.length
            ? [NSURL fileURLWithPath:fullPath]
            : nil;
        NSError *quarantineError = nil;
        if (fileURL &&
            ChromiumKitApplyDownloadQuarantine(fileURL, &quarantineError)) {
            state = ChromiumDownloadStateComplete;
        } else {
            if (fileURL) {
                [NSFileManager.defaultManager removeItemAtURL:fileURL
                                                        error:nil];
            }
            state = ChromiumDownloadStateInterrupted;
        }
    }
    [host cefDidUpdateDownloadWithIdentifier:download_item->GetId()
                                         URL:URL
                           suggestedFilename:
                               NSStringFromCef(
                                   download_item->GetSuggestedFileName())
                               receivedBytes:download_item->GetReceivedBytes()
                                  totalBytes:download_item->GetTotalBytes()
                             percentComplete:
                                 download_item->GetPercentComplete()
                                       state:state];
}

void BrowserClient::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldPresentContextMenu:);
    if (closing_ || !host || !IsCurrent(browser) ||
        ![delegate respondsToSelector:selector]) {
        model->Clear();
        return;
    }
    ChromiumContextMenuRequest *request =
        [[ChromiumContextMenuRequest alloc]
            initWithLocation:NSMakePoint(params->GetXCoord(),
                                         params->GetYCoord())
                     linkURL:NSURLFromCef(params->GetLinkUrl())
                   sourceURL:NSURLFromCef(params->GetSourceUrl())
                selectedText:NSStringFromCef(params->GetSelectionText())
                    editable:params->IsEditable()];
    if (![delegate chromiumBrowserHostView:host
                  shouldPresentContextMenu:request]) {
        model->Clear();
        return;
    }
    model->Remove(MENU_ID_FIND);
    model->Remove(MENU_ID_PRINT);
    model->Remove(MENU_ID_VIEW_SOURCE);
    for (int command = MENU_ID_CUSTOM_FIRST;
         command <= MENU_ID_CUSTOM_LAST; ++command) {
        model->Remove(command);
    }
}

bool BrowserClient::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString& title,
    const CefString& default_file_path,
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions,
    const std::vector<CefString>& accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostViewShouldPresentFileChooser:);
    if (![delegate respondsToSelector:selector] ||
        ![delegate chromiumBrowserHostViewShouldPresentFileChooser:host]) {
        callback->Cancel();
        return true;
    }

    const cef_file_dialog_mode_t dialog_type = mode;
    CefRefPtr<CefFileDialogCallback> retained = callback;
    NSString *panelTitle = NSStringFromCef(title);
    NSString *defaultPath = NSStringFromCef(default_file_path);
    if (dialog_type == FILE_DIALOG_SAVE) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = panelTitle;
        panel.nameFieldStringValue = defaultPath.lastPathComponent;
        void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
            if (response == NSModalResponseOK && panel.URL) {
                std::vector<CefString> paths{
                    CefString(panel.URL.path.UTF8String)};
                retained->Continue(paths);
            } else {
                retained->Cancel();
            }
        };
        if (host.window) {
            [panel beginSheetModalForWindow:host.window
                         completionHandler:completion];
        } else {
            [panel beginWithCompletionHandler:completion];
        }
        return true;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = panelTitle;
    panel.allowsMultipleSelection =
        dialog_type == FILE_DIALOG_OPEN_MULTIPLE;
    panel.canChooseDirectories = dialog_type == FILE_DIALOG_OPEN_FOLDER;
    panel.canChooseFiles = dialog_type != FILE_DIALOG_OPEN_FOLDER;
    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            retained->Cancel();
            return;
        }
        std::vector<CefString> paths;
        for (NSURL *URL in panel.URLs) {
            paths.emplace_back(URL.path.UTF8String);
        }
        retained->Continue(paths);
    };
    if (host.window) {
        [panel beginSheetModalForWindow:host.window
                     completionHandler:completion];
    } else {
        [panel beginWithCompletionHandler:completion];
    }
    return true;
}

bool BrowserClient::GetAuthCredentials(
    CefRefPtr<CefBrowser> browser,
    const CefString& origin_url,
    bool is_proxy,
    const CefString& host,
    int port,
    const CefString& realm,
    const CefString& scheme,
    CefRefPtr<CefAuthCallback> callback) {
    CEF_REQUIRE_IO_THREAD();
    ChromiumBrowserHostView *host_view = host_;
    NSURL *URL = NSURLFromCef(origin_url);
    dispatch_async(dispatch_get_main_queue(), ^{
        [host_view cefDidRejectAuthenticationForURL:URL];
    });
    return false;
}

bool BrowserClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                       cef_errorcode_t cert_error,
                                       const CefString& request_url,
                                       CefRefPtr<CefSSLInfo> ssl_info,
                                       CefRefPtr<CefCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    [host_ cefDidRejectCertificateError:cert_error
                                 forURL:NSURLFromCef(request_url)];
    return false;
}

bool BrowserClient::OnSelectClientCertificate(
    CefRefPtr<CefBrowser> browser,
    bool is_proxy,
    const CefString& host,
    int port,
    const X509CertificateList& certificates,
    CefRefPtr<CefSelectClientCertificateCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    [host_ cefDidRejectClientCertificateForHost:NSStringFromCef(host)
                                           port:port];
    callback->Select(nullptr);
    return true;
}

}  // namespace chromiumkit

#endif

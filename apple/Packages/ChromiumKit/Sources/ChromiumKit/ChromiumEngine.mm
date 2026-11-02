// Engine lifecycle: the external message pump, the CefApp, EngineCore, and
// the CEF-backed ChromiumEngine singleton. CEF is initialized at most once
// per process and shut down asynchronously after every browser has closed.

#import "ChromiumCEFInternal.h"

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED

#import <crt_externs.h>
#import <objc/runtime.h>
#include "include/cef_application_mac.h"
#include "include/cef_request_context.h"

namespace chromiumkit {

EngineCore *g_engine = nullptr;

namespace {
/// Comma-separated unpacked extension directories supplied by Pilot before the
/// engine starts. Read once by OnBeforeCommandLineProcessing on the main thread
/// during CefInitialize, so no synchronization is required beyond the documented
/// "set before start" contract.
std::string g_extension_load_paths;
std::string ExtensionLoadPaths() { return g_extension_load_paths; }

/// CEF's CefAppProtocol state for NSApp. SwiftUI's App lifecycle owns NSApp
/// (a private SwiftUI NSApplication subclass, ignoring NSPrincipalClass), so
/// the protocol is grafted onto that class at runtime instead of subclassing.
/// Read and written only on the main thread, where AppKit sends events.
BOOL g_handling_send_event = NO;
BOOL g_application_integration_installed = NO;

BOOL ApplicationIsHandlingSendEvent(id, SEL) {
    return g_handling_send_event;
}

void ApplicationSetHandlingSendEvent(id, SEL, BOOL handling) {
    g_handling_send_event = handling;
}

bool AddProtocolMethod(Class cls, Protocol *protocol, SEL selector, IMP imp) {
    const objc_method_description description =
        protocol_getMethodDescription(protocol, selector, YES, YES);
    if (description.types == nullptr) {
        return false;
    }
    // A class that already implements the selector (an earlier install, or
    // an NSApplication subclass that adopted the protocol itself) keeps it.
    if (class_getInstanceMethod(cls, selector) != nullptr) {
        return true;
    }
    return class_addMethod(cls, selector, imp, description.types);
}

/// Wraps -sendEvent: of NSApp's real class (KVO-safe: -class, not
/// object_getClass) in CefScopedSendingEvent, which Chromium's message pump
/// uses to tell nested run loops started from event dispatch apart. The
/// wrapper is installed on that class only, so the change is confined to the
/// one NSApplication instance the process has.
bool WrapSendEvent(Class cls) {
    const SEL selector = @selector(sendEvent:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == nullptr) {
        return false;
    }
    using SendEventIMP = void (*)(id, SEL, NSEvent *);
    const SendEventIMP original =
        reinterpret_cast<SendEventIMP>(method_getImplementation(method));
    IMP wrapped = imp_implementationWithBlock(^(id application, NSEvent *event) {
        CefScopedSendingEvent sending_event;
        original(application, selector, event);
    });
    // An inherited -sendEvent: gets an override on this class that forwards
    // to the inherited implementation; an own one is replaced in place.
    if (!class_addMethod(cls, selector, wrapped, method_getTypeEncoding(method))) {
        method_setImplementation(method, wrapped);
    }
    return true;
}

BOOL InstallApplicationIntegration() {
    NSCAssert(NSThread.isMainThread, @"NSApp integration requires main");
    if (g_application_integration_installed) {
        return YES;
    }
    // Never create the shared application here: that would preempt the class
    // SwiftUI instantiates. Callers run after NSApp exists.
    NSApplication *application = NSApp;
    if (application == nil) {
        return NO;
    }
    Class cls = [application class];
    if (!AddProtocolMethod(cls, @protocol(CrAppProtocol),
                           @selector(isHandlingSendEvent),
                           reinterpret_cast<IMP>(ApplicationIsHandlingSendEvent)) ||
        !AddProtocolMethod(cls, @protocol(CrAppControlProtocol),
                           @selector(setHandlingSendEvent:),
                           reinterpret_cast<IMP>(ApplicationSetHandlingSendEvent)) ||
        !WrapSendEvent(cls)) {
        return NO;
    }
    class_addProtocol(cls, @protocol(CefAppProtocol));
    g_application_integration_installed = YES;
    return YES;
}

/// Marks the profile's last session as cleanly exited.
///
/// Chrome's ExitTypeService keeps `profile.exit_type` at "Crashed" while a
/// session runs and writes "Normal" when the profile is destroyed after a
/// clean shutdown, except when the previous session crashed. Then it holds
/// "Crashed" until the user responds to Chrome's crash-recovery ("Restore
/// pages?") UI. CEF never shows that UI, so after one unclean exit (kill,
/// logout, quit backstop) every later clean quit still left "Crashed"
/// (observed in the macOS 27 VM). A stale "Crashed" makes Chrome restore
/// the previous session's session cookies at every launch (observed), so
/// session cookies outlived clean quits despite persist_session_cookies
/// being off. Only a clean shutdown calls this: an unclean exit still reads
/// as a crash on the next launch, as it should. Best effort: if the pref
/// cannot be set, the profile keeps Chrome's own value.
void RecordCleanProfileExit() {
    CEF_REQUIRE_UI_THREAD();
    CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
    if (!context) return;
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetString("Normal");
    CefString error;
    context->SetPreference("profile.exit_type", value, error);
}

class ExternalMessagePump final {
 public:
    static ExternalMessagePump& Shared() {
        static ExternalMessagePump *pump = new ExternalMessagePump;
        return *pump;
    }

    void Start() {
        watchdog_work_count_.store(0);
        accepting_.store(true);
        sequence_.fetch_add(1);
        Schedule(0);
    }

    void Stop() {
        accepting_.store(false);
        sequence_.fetch_add(1);
    }

    void Schedule(int64_t delay_ms) {
        if (!accepting_.load()) {
            return;
        }
        const uint64_t token = sequence_.fetch_add(1) + 1;
        Dispatch(token, delay_ms, 0);
    }

    uint64_t WatchdogWorkCount() const {
        return watchdog_work_count_.load();
    }

 private:
    static constexpr int64_t kInitialWatchdogDelayMs = 50;
    static constexpr int64_t kMaximumWatchdogDelayMs = 100;

    void Dispatch(uint64_t token,
                  int64_t delay_ms,
                  int64_t watchdog_delay_ms) {
        dispatch_block_t work = ^{
            ExternalMessagePump::Shared().Run(token, watchdog_delay_ms);
        };
        if (delay_ms <= 0) {
            dispatch_async(dispatch_get_main_queue(), work);
        } else {
            // A newer schedule request invalidates this token. Honor CEF's
            // requested delay exactly instead of installing an idle polling
            // cadence; OnScheduleMessagePumpWork will request the next turn.
            constexpr int64_t maximum_delay_ms =
                std::numeric_limits<int64_t>::max() / NSEC_PER_MSEC;
            const int64_t bounded =
                std::min(delay_ms, maximum_delay_ms);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, bounded * NSEC_PER_MSEC),
                dispatch_get_main_queue(), work);
        }
    }

    void Run(uint64_t token, int64_t watchdog_delay_ms) {
        if (!accepting_.load() || token != sequence_.load()) {
            return;
        }
        NSCAssert(NSThread.isMainThread, @"CEF pump must run on main");
        if (watchdog_delay_ms > 0) {
            watchdog_work_count_.fetch_add(1);
        }
        CefDoMessageLoopWork();

        // CEF's macOS native-host path does not always request a subsequent
        // turn after CefDoMessageLoopWork. Reserve a low-frequency watchdog
        // only when no callback replaced this token while CEF was running.
        // Any later callback invalidates the watchdog before it can execute.
        uint64_t expected = token;
        const uint64_t watchdog_token = token + 1;
        if (!accepting_.load()
            || !sequence_.compare_exchange_strong(
                expected, watchdog_token
            )) {
            return;
        }
        const int64_t next_delay = watchdog_delay_ms > 0
            ? std::min(
                watchdog_delay_ms * 2,
                kMaximumWatchdogDelayMs
            )
            : kInitialWatchdogDelayMs;
        Dispatch(watchdog_token, next_delay, next_delay);
    }

    std::atomic<bool> accepting_{false};
    std::atomic<uint64_t> sequence_{0};
    std::atomic<uint64_t> watchdog_work_count_{0};
};

/// The client CEF gives browsers that Chrome creates by itself in Chrome UI
/// windows (GetDefaultClient). Returning no client would leave them
/// unmanaged, with no callbacks, and block shutdown until someone closed the
/// window by hand. Instead each one is hidden as soon as it exists, every
/// navigation and popup is cancelled, every Chrome command is refused, and
/// the browser is closed once its target URL is known (or after a short
/// fallback delay).
class ChromeUIBrowserClient final : public CefClient,
                                    public CefCommandHandler,
                                    public CefDisplayHandler,
                                    public CefLifeSpanHandler,
                                    public CefRequestHandler {
 public:
    explicit ChromeUIBrowserClient(EngineCore *engine) : engine_(engine) {}

    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        NSView *view =
            CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
        [view.window orderOut:nil];
        if (g_engine != engine_) {
            browser->GetHost()->CloseBrowser(true);
            return;
        }
        engine_->ChromeUIBrowserCreated(browser);
        CefRefPtr<CefFrame> frame = browser->GetMainFrame();
        if (frame) Consider(browser, frame->GetURL());
        // Whatever happens to the navigation, the browser does not stay.
        CefRefPtr<CefBrowser> retained = browser;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (g_engine != nullptr) g_engine->CloseChromeUIBrowser(retained);
        });
    }
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
                       bool* no_javascript_access) override {
        return true;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        if (g_engine == engine_) engine_->ChromeUIBrowserClosed(browser);
    }
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override {
        CEF_REQUIRE_UI_THREAD();
        if (frame->IsMain()) Consider(browser, request->GetURL());
        return true;
    }
    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        CEF_REQUIRE_UI_THREAD();
        if (frame->IsMain()) Consider(browser, url);
    }
    bool OnChromeCommand(CefRefPtr<CefBrowser> browser,
                         int command_id,
                         cef_window_open_disposition_t disposition) override {
        return true;
    }

 private:
    void Consider(CefRefPtr<CefBrowser> browser, const CefString& url) {
        const std::string value = url.ToString();
        if (handled_ || value.empty() || value == "about:blank" ||
            g_engine != engine_) {
            return;
        }
        handled_ = true;
        engine_->ChromeUIBrowserRequested(browser, url);
    }

    EngineCore *engine_;
    bool handled_ = false;
    IMPLEMENT_REFCOUNTING(ChromeUIBrowserClient);
};

class ChromiumApp final : public CefApp,
                          public CefBrowserProcessHandler {
 public:
    explicit ChromiumApp(EngineCore *engine) : engine_(engine) {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        if (process_type.empty()) {
            // Chrome runtime otherwise owns the login prompt and bypasses
            // CefRequestHandler::GetAuthCredentials. Route challenges through
            // our fail-closed handler without accepting external switches.
            command_line->AppendSwitch("disable-chrome-login-prompt");
            // Side-load unpacked wallet extensions through Chrome's own
            // mechanism: CEF 150 exposes no programmatic extension API (see
            // chromiumembedded/cef#3450), so the switch is the only route.
            // App-appended switches are still honored with
            // command_line_args_disabled, which only blocks external/OS-
            // provided arguments.
            //
            // The directories come from Pilot, which discovers them at runtime.
            // They must never be hardcoded: Chrome derives an unpacked
            // extension's ID from its absolute path, so a baked-in path both
            // breaks on every other machine and silently invalidates the IDs
            // used to address the extension's UI.
            const std::string extension_paths = ExtensionLoadPaths();
            if (!extension_paths.empty()) {
                command_line->AppendSwitchWithValue("load-extension",
                                                    extension_paths);
            }
        }
    }

    void OnContextInitialized() override;

    bool OnAlreadyRunningAppRelaunch(
        CefRefPtr<CefCommandLine> command_line,
        const CefString& current_directory) override {
        CEF_REQUIRE_UI_THREAD();
        [NSApp activateIgnoringOtherApps:YES];
        return true;
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        ExternalMessagePump::Shared().Schedule(delay_ms);
    }

    CefRefPtr<CefClient> GetDefaultClient() override {
        return new ChromeUIBrowserClient(engine_);
    }

 private:
    EngineCore *engine_;
    IMPLEMENT_REFCOUNTING(ChromiumApp);
};

}  // namespace

bool EngineCore::Start(NSURL *profile, NSError **error) {
    NSCAssert(NSThread.isMainThread, @"CEF must initialize on main");
    loader_ = std::make_unique<CefScopedLibraryLoader>();
    if (!loader_->LoadInMain()) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorLibraryLoadFailed,
                @"The Chromium Embedded Framework could not be loaded.",
                nil);
        }
        loader_.reset();
        return false;
    }

    CefSettings settings;
    settings.no_sandbox = false;
    settings.multi_threaded_message_loop = false;
    settings.external_message_pump = true;
    settings.windowless_rendering_enabled = false;
    settings.command_line_args_disabled = true;
    // SPIKE(rabby-extension): CEF 150 removed CefSettings::chrome_runtime
    // (Chrome runtime is now the only runtime) and the old
    // CefRequestContext::LoadExtension API; programmatic extension
    // management is still open upstream (chromiumembedded/cef#3450), so
    // extensions load via the load-extension switch below.
    const char *path = profile.path.fileSystemRepresentation;
    CefString(&settings.root_cache_path) = path;
    CefString(&settings.cache_path) = path;

    // CEF's default helper lookup is "<main executable name> Helper.app"
    // under Contents/Frameworks. The helper bundle names are fixed by
    // cef-artifacts.json (helperLayout.helpers, role "base") and are
    // independent of the app's PRODUCT_NAME, so name the base helper
    // explicitly; Chromium derives the (GPU)/(Renderer)/... variants
    // from this path.
    NSURL *helperURL = [NSBundle.mainBundle.bundleURL
        URLByAppendingPathComponent:
            @"Contents/Frameworks/Pilot Helper.app/Contents/MacOS/Pilot Helper"];
    if (![NSFileManager.defaultManager fileExistsAtPath:helperURL.path]) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInitializationFailed,
                @"The Chromium base helper is missing from the app bundle.",
                @{NSFilePathErrorKey: helperURL.path});
        }
        loader_.reset();
        return false;
    }
    CefString(&settings.browser_subprocess_path) =
        helperURL.path.fileSystemRepresentation;

    // Chromium calls -[NSApp isHandlingSendEvent] from its message pump; an
    // NSApp without CefAppProtocol crashes on the first nested event loop.
    if (!InstallApplicationIntegration()) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInitializationFailed,
                @"The application object could not be prepared for Chromium.",
                nil);
        }
        loader_.reset();
        return false;
    }

    app_ = new ChromiumApp(this);
    ExternalMessagePump::Shared().Start();
    CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
    if (!CefInitialize(main_args, settings, app_, nullptr)) {
        const int exit_code = CefGetExitCode();
        ExternalMessagePump::Shared().Stop();
        app_ = nullptr;
        loader_.reset();
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInitializationFailed,
                @"CEF initialization failed.",
                @{@"CEFExitCode": @(exit_code)});
        }
        return false;
    }
    initialized_ = true;
    return true;
}

uint64_t EngineCore::AddHost(ChromiumBrowserHostView *host) {
    if (shutting_down_ || !initialized_) {
        return 0;
    }
    const uint64_t token = next_token_++;
    CefRefPtr<BrowserClient> client =
        new BrowserClient(this, token, host);
    clients_.emplace(token, client);
    if (context_ready_) {
        client->Create();
    }
    return token;
}

CefRefPtr<BrowserClient> EngineCore::Client(uint64_t token) {
    auto found = clients_.find(token);
    return found == clients_.end() ? nullptr : found->second;
}

size_t EngineCore::ClientCount() const {
    return clients_.size();
}

void EngineCore::ContextReady() {
    CEF_REQUIRE_UI_THREAD();
    context_ready_ = true;
    if (shutting_down_) {
        return;
    }
    owner_.state = ChromiumEngineStateRunning;
    std::vector<CefRefPtr<BrowserClient>> pending;
    for (const auto& entry : clients_) {
        pending.push_back(entry.second);
    }
    for (const auto& client : pending) {
        client->Create();
    }
}

void EngineCore::ClientClosed(uint64_t token) {
    clients_.erase(token);
    FinishShutdownIfReady();
}

void EngineCore::ChromeUIBrowserCreated(CefRefPtr<CefBrowser> browser) {
    chrome_ui_browsers_.push_back(browser);
    if (shutting_down_) {
        browser->GetHost()->CloseBrowser(true);
    }
}

void EngineCore::ChromeUIBrowserRequested(CefRefPtr<CefBrowser> browser,
                                          const CefString& url) {
    NSURL *URL = NSURLFromCef(url);
    ChromiumEngine *owner = owner_;
    void (^handler)(NSURL *) = owner.extensionPageRequestHandler;
    if (!shutting_down_ && handler && URL &&
        [URL.scheme.lowercaseString isEqualToString:@"chrome-extension"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(URL);
        });
    }
    // Not from inside the navigation callback that reported the URL.
    CefRefPtr<CefBrowser> retained = browser;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_engine != nullptr) g_engine->CloseChromeUIBrowser(retained);
    });
}

void EngineCore::CloseChromeUIBrowser(CefRefPtr<CefBrowser> browser) {
    for (const auto& candidate : chrome_ui_browsers_) {
        if (candidate->IsSame(browser)) {
            browser->GetHost()->CloseBrowser(true);
            return;
        }
    }
}

void EngineCore::ChromeUIBrowserClosed(CefRefPtr<CefBrowser> browser) {
    chrome_ui_browsers_.erase(
        std::remove_if(chrome_ui_browsers_.begin(), chrome_ui_browsers_.end(),
                       [&](const CefRefPtr<CefBrowser>& candidate) {
                           return candidate->IsSame(browser);
                       }),
        chrome_ui_browsers_.end());
    FinishShutdownIfReady();
}

void EngineCore::Shutdown() {
    NSCAssert(NSThread.isMainThread, @"CEF must shut down on main");
    if (!initialized_ || shutting_down_) {
        return;
    }
    shutting_down_ = true;
    owner_.state = ChromiumEngineStateShuttingDown;
    std::vector<CefRefPtr<BrowserClient>> active;
    for (const auto& entry : clients_) {
        active.push_back(entry.second);
    }
    for (const auto& client : active) {
        client->Close(true);
    }
    const std::vector<CefRefPtr<CefBrowser>> chrome_ui = chrome_ui_browsers_;
    for (const auto& browser : chrome_ui) {
        browser->GetHost()->CloseBrowser(true);
    }
    FinishShutdownIfReady();
}

void EngineCore::FinishShutdownIfReady() {
    if (!shutting_down_ || !clients_.empty() ||
        !chrome_ui_browsers_.empty() || finish_scheduled_) {
        return;
    }
    finish_scheduled_ = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_engine != nullptr) {
            g_engine->FinishShutdown();
        }
    });
}

void EngineCore::FinishShutdown() {
    if (!initialized_ || !clients_.empty() || !chrome_ui_browsers_.empty()) {
        finish_scheduled_ = false;
        return;
    }
    // Every browser has closed: this is a clean exit. Record it before
    // CefShutdown destroys the profile, which commits its preferences. A
    // quit before OnContextInitialized has no initialized profile to mark.
    if (context_ready_) RecordCleanProfileExit();
    ExternalMessagePump::Shared().Stop();
    CefShutdown();
    initialized_ = false;
    context_ready_ = false;
    app_ = nullptr;
    loader_.reset();
    ChromiumEngine *owner = owner_;
    g_engine = nullptr;
    delete this;
    [owner chromiumDidFinishShutdown];
}

void ChromiumApp::OnContextInitialized() {
    CEF_REQUIRE_UI_THREAD();
    CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
    if (!context) return;
    // Chrome persists certificate exceptions in the profile. Clear them at
    // launch so a previous approval cannot silently authorize a new session.
    // In the pinned CEF implementation this runs synchronously on the UI
    // thread once the global context is initialized, before ContextReady()
    // permits any managed browser to be created or open a connection.
    context->ClearCertificateExceptions(nullptr);
    engine_->ContextReady();
}

}  // namespace chromiumkit

using namespace chromiumkit;

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
    if (self) {
        _state = ChromiumEngineStateNotStarted;
        _shutdownCompletions = [NSMutableArray array];
    }
    return self;
}

+ (BOOL)installApplicationIntegration {
    return InstallApplicationIntegration();
}

- (BOOL)isRunning {
    return self.state == ChromiumEngineStateInitializing ||
           self.state == ChromiumEngineStateRunning;
}

- (BOOL)isRuntimeAvailable {
    return YES;
}

- (NSUInteger)activeBrowserCount {
    return g_engine ? g_engine->ClientCount() : 0;
}

- (NSUInteger)messagePumpWatchdogWorkCount {
    return ExternalMessagePump::Shared().WatchdogWorkCount();
}

- (void)setExtensionDirectories:(NSArray<NSURL *> *)directories {
    // Must be set before start: CEF reads the command line once during
    // CefInitialize, and Chrome ties an unpacked extension's identity to the
    // absolute path it was loaded from.
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *directory in directories) {
        if (!directory.isFileURL) { continue; }
        NSString *path = directory.URLByStandardizingPath.path;
        // A comma separates entries in the switch value, so a path containing
        // one cannot be expressed and is dropped rather than silently splitting
        // into two bogus directories.
        if (path.length == 0 || [path containsString:@","]) { continue; }
        [paths addObject:path];
    }
    g_extension_load_paths =
        [[paths componentsJoinedByString:@","] UTF8String] ?: "";
}

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError **)error {
    NSCAssert(NSThread.isMainThread, @"CEF must initialize on main");
    if (!profileDirectory.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory must be a file URL.", nil);
        }
        return NO;
    }
    if (self.state == ChromiumEngineStateInitializing ||
        self.state == ChromiumEngineStateRunning) {
        return YES;
    }
    if (self.state != ChromiumEngineStateNotStarted) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInitializationFailed,
                @"CEF cannot be restarted in this process.", nil);
        }
        return NO;
    }

    NSError *directoryError;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:profileDirectory
     withIntermediateDirectories:YES
                      attributes:nil
                           error:&directoryError]) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory could not be created.",
                @{NSUnderlyingErrorKey: directoryError});
        }
        return NO;
    }

    self.state = ChromiumEngineStateInitializing;
    g_engine = new EngineCore(self);
    if (!g_engine->Start(profileDirectory, error)) {
        EngineCore *failed_engine = g_engine;
        g_engine = nullptr;
        delete failed_engine;
        self.state = ChromiumEngineStateFailed;
        return NO;
    }
    return YES;
}

- (void)shutdown {
    [self shutdownWithCompletion:nil];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    NSCAssert(NSThread.isMainThread, @"CEF must shut down on main");
    if (completion) {
        [self.shutdownCompletions addObject:[completion copy]];
    }
    if (g_engine) {
        g_engine->Shutdown();
        return;
    }
    if (self.state == ChromiumEngineStateNotStarted) {
        self.state = ChromiumEngineStateShutDown;
    }
    [self chromiumDidFinishShutdown];
}

- (void)chromiumDidFinishShutdown {
    NSCAssert(NSThread.isMainThread, @"CEF shutdown completion requires main");
    self.state = ChromiumEngineStateShutDown;
    NSArray *completions = [self.shutdownCompletions copy];
    [self.shutdownCompletions removeAllObjects];
    for (void (^completion)(void) in completions) {
        completion();
    }
}

@end

#endif

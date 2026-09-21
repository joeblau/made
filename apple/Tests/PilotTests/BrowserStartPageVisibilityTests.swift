import Foundation
import Testing
import WebKit
@testable import Pilot

@Suite("Browser engine persistence and commands")
struct BrowserEngineTests {

    @Test
    func webKitIsTheBackwardCompatibleDefault() {
        let state = BrowserState()
        #expect(state.engine == .webKit)

        state.engineRaw = "unknown-future-engine"
        #expect(state.engine == .webKit)
    }

    @Test
    func chromiumSelectionRoundTripsThroughThePersistedRawValue() {
        let state = BrowserState(engine: .chromium)
        #expect(state.engineRaw == BrowserEngine.chromium.rawValue)
        #expect(state.engine == .chromium)

        state.engine = .webKit
        #expect(state.engineRaw == BrowserEngine.webKit.rawValue)
    }

    @Test
    func chromiumStartsWithOnlyEngineNeutralCapabilities() {
        #expect(BrowserEngine.chromium.supports(.navigation))
        #expect(BrowserEngine.chromium.supports(.addressFocus))
        #expect(!BrowserEngine.chromium.supports(.appearanceOverride))
        #expect(BrowserEngine.chromium.supports(.developerTools))
        #expect(!BrowserEngine.chromium.supports(.annotation))
        #expect(!BrowserEngine.chromium.supports(.websiteDataReset))
    }

    @Test
    func chromiumNavigationUsesTheSharedPendingRequestContract() {
        let state = BrowserState(engine: .chromium)
        let initialRequestID = state.navigationRequestID

        #expect(state.perform(.reload))
        #expect(state.pendingURL?.absoluteString == "blau://reload")
        #expect(state.navigationRequestID == initialRequestID + 1)

        #expect(state.perform(.focusAddress))
        #expect(state.needsAddressFocus)

        #expect(!state.perform(.toggleAnnotation))
        #expect(!state.annotateMode)
    }

    @Test
    func committedNavigationDoesNotOverwriteANewerAddressDraft() throws {
        let state = BrowserState(engine: .chromium)
        state.urlText = "https://submitted.example"
        state.isAddressEditing = true
        state.navigate()
        state.urlText = "https://new-draft.example"

        state.acceptCommittedURL(
            try #require(URL(string: "https://submitted.example/redirect"))
        )
        #expect(state.urlText == "https://new-draft.example")

        state.isAddressEditing = false
        state.acceptCommittedURL(
            try #require(URL(string: "https://committed.example"))
        )
        #expect(state.urlText == "https://committed.example")
    }

    @Test
    func chromiumPaneCommandsAndRetryRemainPaneLocal() {
        let first = BrowserState(engine: .chromium)
        let second = BrowserState(engine: .chromium)

        #expect(first.perform(.back))
        #expect(first.pendingURL?.absoluteString == "blau://back")
        #expect(second.pendingURL == nil)

        let retryID = first.runtimeRetryRequestID
        first.requestRuntimeRetry()
        #expect(first.runtimeRetryRequestID == retryID + 1)
        #expect(first.engine == .chromium)
        #expect(second.runtimeRetryRequestID == 0)
    }

    @Test("Address drafts do not change the loaded page's favicon")
    func faviconFollowsCommittedPageWhileEditingAddress() throws {
        let state = BrowserState()
        let page = try #require(URL(string: "https://loaded.example/page"))
        let icon = try #require(URL(string: "https://loaded.example/icon.png"))
        state.commitFaviconPage(page)
        state.updateFaviconURLs([icon], for: page)

        state.isAddressEditing = true
        state.urlText = "https://draft.example"

        #expect(state.faviconPageURL == page.absoluteString)
        #expect(state.faviconURLs == [icon.absoluteString])
    }

    @Test("Navigation clears old icons and rejects late metadata from the previous page")
    func faviconRejectsPreviousNavigation() throws {
        let state = BrowserState()
        let oldPage = try #require(URL(string: "https://old.example"))
        let newPage = try #require(URL(string: "https://new.example"))
        let oldIcon = try #require(URL(string: "https://old.example/icon.png"))
        state.commitFaviconPage(oldPage)
        state.updateFaviconURLs([oldIcon], for: oldPage)

        state.commitFaviconPage(newPage)
        #expect(state.faviconURLs.isEmpty)
        state.updateFaviconURLs([oldIcon], for: oldPage)
        #expect(state.faviconURLs.isEmpty)
        #expect(state.faviconPageURL == newPage.absoluteString)
    }

    @Test("Screenshot demo state includes Chromium without a network URL")
    @MainActor
    func demoStateKeepsChromiumOfflineAndDeterministic() throws {
        let workspaces = WorkspaceStore.makeDemoWorkspaces()

        #expect(workspaces.map(\.name) == ["made", "web", "infra"])
        #expect(workspaces.map(\.workspaceSortOrder) == [0, 1, 2])
        #expect(workspaces.map(\.isPinned) == [true, false, false])

        let web = try #require(
            workspaces.first(where: { $0.name == "web" })
        )
        let chromiumStates = web.panes.compactMap(\.browserState).filter {
            $0.engine == .chromium
        }
        #expect(chromiumStates.count == 1)
        let chromium = try #require(chromiumStates.first)
        #expect(chromium.urlText.isEmpty)
        #expect(chromium.pendingURL == nil)
        #expect(!chromium.isLoading)
    }
}

@Suite("Browser start page visibility")
struct BrowserStartPageVisibilityTests {

    @Test
    func blankBrowserKeepsStartPageWhileAddressBarTextIsDrafted() {
        #expect(BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "g",
            hasPendingPageNavigation: false
        ))
    }

    @Test
    func submittedDraftHidesStartPageForNavigation() {
        #expect(!BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "google.com",
            hasPendingPageNavigation: true
        ))
    }

    @Test
    func browserCommandDoesNotHideBlankStartPage() {
        #expect(BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: true,
            urlText: "",
            hasPendingPageNavigation: false
        ))
    }

    @Test
    func restoredURLSkipsStartPage() {
        #expect(!BrowserStartPageVisibility.shouldShow(
            hasLoadedAnyURL: false,
            openedWithBlankURL: nil,
            urlText: "https://example.com",
            hasPendingPageNavigation: false
        ))
    }
}

@Suite("Browser website data reset")
struct BrowserWebsiteDataResetTests {

    @Test
    func resetRequestRecreatesTheBrowserAndClearsNavigationState() {
        let state = BrowserState()
        state.urlText = "http://localhost:3000"
        state.pendingURL = URL(string: "http://localhost:3001")
        state.canGoBack = true
        state.canGoForward = true
        let initialRequestID = state.websiteDataResetRequestID

        state.requestWebsiteDataReset()

        #expect(state.websiteDataResetRequestID == initialRequestID + 1)
        #expect(state.pendingURL == nil)
        #expect(!state.canGoBack)
        #expect(!state.canGoForward)
        #expect(state.isLoading)
    }

    @Test
    @MainActor
    func resetIncludesCachesAndBrowserStorage() {
        let dataTypes = BrowserWebsiteData.allDataTypes

        #expect(dataTypes.contains(WKWebsiteDataTypeDiskCache))
        #expect(dataTypes.contains(WKWebsiteDataTypeMemoryCache))
        #expect(dataTypes.contains(WKWebsiteDataTypeLocalStorage))
        #expect(dataTypes.contains(WKWebsiteDataTypeSessionStorage))
    }
}

@Suite("Browser lasso state and script contracts")
struct BrowserLassoTests {

    @Test
    func settingAndTogglingLassoPublishesOnlyRealStateChanges() {
        let state = BrowserState()
        let initialRequestID = state.annotateToggleRequestID

        state.setAnnotateMode(true)
        #expect(state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 1)

        state.setAnnotateMode(true)
        #expect(state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 1)

        state.toggleAnnotateMode()
        #expect(!state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 2)

        state.setAnnotateMode(false)
        #expect(!state.annotateMode)
        #expect(state.annotateToggleRequestID == initialRequestID + 2)
    }

    @Test
    func enableScriptsPersistDesiredStateBeforeTouchingInjectedController() {
        let enable = BrowserAnnotate.setEnabledScript(true).filter { !$0.isWhitespace }
        let disable = BrowserAnnotate.setEnabledScript(false).filter { !$0.isWhitespace }

        let enableDesired = enable.range(of: "__pilotAnnotateDesiredEnabled=true")
        let enableController = enable.range(of: "__pilotAnnotate.setEnabled(true,null)")
        let disableDesired = disable.range(of: "__pilotAnnotateDesiredEnabled=false")
        let disableController = disable.range(of: "__pilotAnnotate.setEnabled(false,null)")

        #expect(enableDesired != nil)
        #expect(enableController != nil)
        #expect(disableDesired != nil)
        #expect(disableController != nil)
        if let enableDesired, let enableController {
            #expect(enableDesired.lowerBound < enableController.lowerBound)
        }
        if let disableDesired, let disableController {
            #expect(disableDesired.lowerBound < disableController.lowerBound)
        }
    }

    @Test
    func injectedScriptExposesStableSelectionLockAndOverlayMarkers() {
        let script = BrowserAnnotate.userScript

        #expect(script.contains("data-pilot-annotate-highlight"))
        #expect(script.contains("data-pilot-annotate-box"))
        #expect(script.contains("hovered"))
        #expect(script.contains("selected"))
        #expect(script.contains("finishSend"))
    }

    @Test
    func finishScriptUsesTheInjectedControllerLifecycleHook() {
        let script = BrowserAnnotate.finishSendScript(selectionID: "selection-42")

        #expect(script.contains("__pilotAnnotate"))
        #expect(script.contains("finishSend(\"selection-42\")"))
        #expect(BrowserAnnotate.userScript.contains("crypto.randomUUID"))
        #expect(BrowserAnnotate.userScript.contains("completedSelectionID !== sendingID"))
    }

    @Test
    func dispatchKeepsTheTerminalCapturedBeforeAnAsyncSnapshot() {
        let intendedTerminal = UUID()
        var currentlyActiveTerminal = intendedTerminal
        let dispatch = BrowserAnnotate.DispatchContext(targetPaneID: currentlyActiveTerminal)

        // Models a click into another terminal while takeSnapshot is in flight.
        currentlyActiveTerminal = UUID()
        let userInfo = dispatch.notificationUserInfo(prompt: "Fix this element")

        #expect(BrowserAnnotate.hasCapturedTarget(in: userInfo))
        #expect(BrowserAnnotate.targetPaneID(in: userInfo) == intendedTerminal)
        #expect(BrowserAnnotate.targetPaneID(in: userInfo) != currentlyActiveTerminal)
        #expect(userInfo[BrowserAnnotate.promptUserInfoKey] as? String == "Fix this element")

        let noTerminal = BrowserAnnotate.DispatchContext(targetPaneID: nil)
            .notificationUserInfo(prompt: "No target")
        #expect(BrowserAnnotate.hasCapturedTarget(in: noTerminal))
        #expect(BrowserAnnotate.targetPaneID(in: noTerminal) == nil)
        #expect(!BrowserAnnotate.hasCapturedTarget(in: [BrowserAnnotate.promptUserInfoKey: "Legacy issue"]))
    }

    @Test
    func shiftedCommandAIsReservedForLasso() {
        #expect(BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "a",
            hasShift: false
        ))
        #expect(!BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "a",
            hasShift: true
        ))
        #expect(BrowserWebShortcutPolicy.keepsNativeEditingShortcut(
            characters: "z",
            hasShift: true
        ))
    }

    @Test
    func reloadShortcutTargetsOnlyTheSelectedBrowser() {
        #expect(BrowserWebShortcutPolicy.handlesReload(
            isPaneSelected: true,
            hasCommand: true,
            hasControl: false,
            hasOption: false,
            characters: "r"
        ))
        #expect(!BrowserWebShortcutPolicy.handlesReload(
            isPaneSelected: false,
            hasCommand: true,
            hasControl: false,
            hasOption: false,
            characters: "r"
        ))
        #expect(!BrowserWebShortcutPolicy.handlesReload(
            isPaneSelected: true,
            hasCommand: true,
            hasControl: true,
            hasOption: false,
            characters: "r"
        ))
    }

    @Test
    func bridgeGrantIsStrictNavigationBoundAndSingleUse() throws {
        let body: [String: Any] = [
            "action": "send",
            "instruction": "Fix the button",
            "url": "https://example.com/page",
            "selector": "#save",
            "outerHTML": "<button id=\"save\">Save</button>",
            "selectionID": "selection-1",
            "bridgeToken": "grant-1",
            "rect": ["x": 10, "y": 20, "w": 100, "h": 40],
        ]
        let payload = try #require(BrowserAnnotate.MessagePayload.parse(body))
        var grant = BrowserAnnotate.BridgeGrant(
            token: "grant-1",
            navigationURL: "https://example.com/page",
            expiresAt: Date(timeIntervalSinceNow: 60)
        )

        let firstConsume = grant.consume(payload, currentURL: "https://example.com/page")
        let secondConsume = grant.consume(payload, currentURL: "https://example.com/page")
        #expect(firstConsume)
        #expect(!secondConsume)
        #expect(BrowserAnnotate.MessagePayload.parse(body.merging(["extra": true]) { _, new in new }) == nil)
    }

    @Test
    @MainActor
    func injectedLassoLocksAndClearsTheSelectedElement() async throws {
        let configuration = WKWebViewConfiguration()
        let messageSink = BrowserLassoMessageSink()
        configuration.userContentController.add(
            messageSink,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAnnotate.userScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: BrowserAnnotate.contentWorld
        ))
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let loader = BrowserLassoTestLoader()
        webView.navigationDelegate = loader
        let loaded = await loader.load(
            """
            <!doctype html><html><head><style>
            html,body { margin:0; width:400px; height:300px; }
            #a,#b { position:absolute; top:20px; width:100px; height:50px; }
            #a { left:10px; } #b { left:200px; }
            </style></head><body><div id="a">A</div><div id="b">B</div></body></html>
            """,
            in: webView
        )
        #expect(loaded)
        guard loaded else { return }

        let forged = try await evaluateString(in: webView, script: """
        try {
          window.webkit.messageHandlers.pilotAnnotate.postMessage({action:'send'});
          'exposed';
        } catch (_) { 'blocked'; }
        """)
        #expect(forged == "blocked")
        #expect(messageSink.selectionIDs.isEmpty)

        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(true, token: "test-grant-1")
        )
        let hoverA = try await evaluateString(in: webView, script: """
        var a = document.getElementById('a');
        a.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:20, clientY:30}));
        document.querySelector('[data-pilot-annotate-highlight]').style.left;
        """)
        let selectedA = try await evaluateString(in: webView, script: """
        window.pageClicks = 0;
        a.addEventListener('click', function () { window.pageClicks += 1; });
        a.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:20, clientY:30}));
        a.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, clientX:20, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]'), clicks:window.pageClicks});
        """)
        let lockedAfterMovingToB = try await evaluateString(in: webView, script: """
        var b = document.getElementById('b');
        b.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:220, clientY:30}));
        document.querySelector('[data-pilot-annotate-highlight]').style.left;
        """)
        let replacedWithB = try await evaluateString(in: webView, script: """
        b.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:220, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)

        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(false)
        )
        let disabled = try await evaluateString(in: webView, script: """
        JSON.stringify({display:document.querySelector('[data-pilot-annotate-highlight]').style.display, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)

        // Re-enable and click B without a preceding mousemove. A stale hover
        // from before the toggle must never select A again.
        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(true, token: "test-grant-2")
        )
        let selectedB = try await evaluateString(in: webView, script: """
        b.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:220, clientY:30}));
        b.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, clientX:220, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.finishSendScript(selectionID: "stale-selection")
        )
        let afterStaleFinish = try await evaluateString(in: webView, script: """
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        let sendingB = try await evaluateString(in: webView, script: """
        var selectedBox = document.querySelector('[data-pilot-annotate-box]');
        selectedBox.querySelector('textarea').value = 'Fix B';
        selectedBox.querySelectorAll('button')[1].click();
        JSON.stringify({display:document.querySelector('[data-pilot-annotate-highlight]').style.display, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        let sentBSelectionID = try #require(messageSink.selectionIDs.last)
        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.finishSendScript(selectionID: sentBSelectionID)
        )
        let afterSendFinished = try await evaluateString(in: webView, script: """
        JSON.stringify({display:document.querySelector('[data-pilot-annotate-highlight]').style.display, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        let selectedAAgain = try await evaluateString(in: webView, script: """
        a.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:20, clientY:30}));
        a.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, clientX:20, clientY:30}));
        JSON.stringify({left:document.querySelector('[data-pilot-annotate-highlight]').style.left, box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        _ = try await evaluateString(in: webView, script: """
        var secondBox = document.querySelector('[data-pilot-annotate-box]');
        secondBox.querySelector('textarea').value = 'Fix A next';
        secondBox.querySelectorAll('button')[1].click();
        'sent';
        """)
        let sentASelectionID = try #require(messageSink.selectionIDs.last)

        #expect(hoverA == "10px")
        #expect(selectedA.contains("\"left\":\"10px\""))
        #expect(selectedA.contains("\"box\":true"))
        #expect(selectedA.contains("\"clicks\":0"))
        #expect(lockedAfterMovingToB == "10px")
        #expect(replacedWithB.contains("\"left\":\"200px\""))
        #expect(replacedWithB.contains("\"box\":true"))
        #expect(disabled.contains("\"display\":\"none\""))
        #expect(disabled.contains("\"box\":false"))
        #expect(selectedB.contains("\"left\":\"200px\""))
        #expect(selectedB.contains("\"box\":true"))
        #expect(afterStaleFinish.contains("\"left\":\"200px\""))
        #expect(afterStaleFinish.contains("\"box\":true"))
        #expect(sendingB.contains("\"display\":\"block\""))
        #expect(sendingB.contains("\"box\":false"))
        #expect(afterSendFinished.contains("\"display\":\"none\""))
        #expect(afterSendFinished.contains("\"box\":false"))
        #expect(selectedAAgain.contains("\"left\":\"10px\""))
        #expect(selectedAAgain.contains("\"box\":true"))
        #expect(messageSink.selectionIDs.count == 2)
        #expect(sentBSelectionID != sentASelectionID)
        #expect(messageSink.selectionIDs.allSatisfy { !$0.isEmpty })
    }

    @Test
    @MainActor
    func injectedLassoImmediatelyHighlightsSmartDOMTarget() async throws {
        let configuration = WKWebViewConfiguration()
        let messageSink = BrowserLassoMessageSink()
        configuration.userContentController.add(
            messageSink,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAnnotate.userScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: BrowserAnnotate.contentWorld
        ))
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let loader = BrowserLassoTestLoader()
        webView.navigationDelegate = loader
        let loaded = await loader.load(
            """
            <!doctype html><html><head><style>
            html,body { margin:0; width:400px; height:300px; }
            #viewport-shell { position:absolute; inset:0; }
            #card { position:absolute; left:20px; top:30px; width:180px; height:100px; }
            #label { position:absolute; left:12px; top:10px; width:90px; height:24px; }
            #icon { width:16px; height:16px; }
            #action { position:absolute; left:230px; top:30px; width:120px; height:40px; }
            #bare { position:absolute; left:250px; top:150px; width:60px; height:24px; display:block; }
            </style></head><body><div id="viewport-shell">
              <div id="card"><span id="label">Card <svg id="icon" viewBox="0 0 16 16"><path id="glyph" d="M0 0h16v16H0z"/></svg></span></div>
              <button id="action"><span id="button-label">Save</span></button>
              <span id="bare">Standalone</span>
            </div></body></html>
            """,
            in: webView
        )
        #expect(loaded)
        guard loaded else { return }

        // Pilot must remember where the pointer was while Lasso was disabled.
        // Turning it on should immediately resolve and paint that target; the
        // user should not have to jiggle the mouse after clicking the toolbar.
        let beforeEnable = try await evaluateString(in: webView, script: """
        var label = document.getElementById('label');
        label.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:45, clientY:50}));
        document.querySelector('[data-pilot-annotate-highlight]') ? 'present' : 'absent';
        """)
        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(true, token: "smart-target-grant")
        )
        let immediatelyHighlighted = try await highlightGeometry(in: webView)

        // A deeply nested SVG leaf still represents the card. Conversely, an
        // interactive control is useful on its own and must not be promoted to
        // an ancestor DIV.
        _ = try await evaluateString(in: webView, script: """
        var glyph = document.getElementById('glyph');
        glyph.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:120, clientY:50}));
        'moved';
        """)
        try await Task.sleep(for: .milliseconds(40))
        let nestedSVG = try await highlightGeometry(in: webView)
        _ = try await evaluateString(in: webView, script: """
        var buttonLabel = document.getElementById('button-label');
        buttonLabel.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:260, clientY:50}));
        'moved';
        """)
        try await Task.sleep(for: .milliseconds(40))
        let interactiveChild = try await highlightGeometry(in: webView)

        // The full-viewport DIV is a layout shell, not a useful annotation
        // target. With no better bounded container, retain the precise leaf.
        _ = try await evaluateString(in: webView, script: """
        var bare = document.getElementById('bare');
        bare.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:270, clientY:160}));
        'moved';
        """)
        try await Task.sleep(for: .milliseconds(40))
        let boundedLeaf = try await highlightGeometry(in: webView)

        // Pointer-down must lock the same smart target that hover advertised.
        let selectedCard = try await evaluateString(in: webView, script: """
        label.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:45, clientY:50}));
        label.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:45, clientY:50}));
        var h = document.querySelector('[data-pilot-annotate-highlight]');
        JSON.stringify({geometry:[h.style.left,h.style.top,h.style.width,h.style.height].join('|'), box:!!document.querySelector('[data-pilot-annotate-box]')});
        """)
        _ = try await evaluateString(in: webView, script: """
        var selectedBox = document.querySelector('[data-pilot-annotate-box]');
        selectedBox.querySelector('textarea').value = 'Adjust this card';
        selectedBox.querySelectorAll('button')[1].click();
        'sent';
        """)

        #expect(beforeEnable == "absent")
        #expect(immediatelyHighlighted == "20px|30px|180px|100px")
        #expect(nestedSVG == "20px|30px|180px|100px")
        #expect(interactiveChild == "230px|30px|120px|40px")
        #expect(boundedLeaf == "250px|150px|60px|24px")
        #expect(selectedCard.contains("\"geometry\":\"20px|30px|180px|100px\""))
        #expect(selectedCard.contains("\"box\":true"))
        #expect(messageSink.selectors.last == "#card")
    }

    @Test
    @MainActor
    func injectedLassoWinsCaptureAgainstPageEventBlockers() async throws {
        let configuration = WKWebViewConfiguration()
        let messageSink = BrowserLassoMessageSink()
        configuration.userContentController.add(
            messageSink,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAnnotate.userScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: BrowserAnnotate.contentWorld
        ))
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let loader = BrowserLassoTestLoader()
        webView.navigationDelegate = loader
        let loaded = await loader.load(
            """
            <!doctype html><html><head><style>
            html,body { margin:0; width:400px; height:300px; }
            #action { position:absolute; left:40px; top:30px; width:140px; height:48px; }
            </style><script>
            window.pagePointerDowns = 0;
            window.addEventListener('mousemove', function (event) {
              event.stopImmediatePropagation();
            }, true);
            window.addEventListener('pointerdown', function (event) {
              window.pagePointerDowns += 1;
              event.stopImmediatePropagation();
            }, true);
            </script></head><body><button id="action">Blocked page control</button></body></html>
            """,
            in: webView
        )
        #expect(loaded)
        guard loaded else { return }

        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(true, token: "capture-grant")
        )
        let result = try await evaluateString(in: webView, script: """
        var action = document.getElementById('action');
        action.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:80, clientY:50}));
        action.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, composed:true, clientX:80, clientY:50}));
        var h = document.querySelector('[data-pilot-annotate-highlight]');
        JSON.stringify({display:h ? h.style.display : 'missing', box:!!document.querySelector('[data-pilot-annotate-box]'), pagePointerDowns:window.pagePointerDowns});
        """)

        #expect(result.contains("\"display\":\"block\""))
        #expect(result.contains("\"box\":true"))
        #expect(result.contains("\"pagePointerDowns\":0"))
    }

    @Test
    @MainActor
    func injectedLassoCoalescesPointerStormsToTheLatestTarget() async throws {
        let configuration = WKWebViewConfiguration()
        let messageSink = BrowserLassoMessageSink()
        configuration.userContentController.add(
            messageSink,
            contentWorld: BrowserAnnotate.contentWorld,
            name: BrowserAnnotate.messageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: BrowserAnnotate.userScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: BrowserAnnotate.contentWorld
        ))
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let loader = BrowserLassoTestLoader()
        webView.navigationDelegate = loader
        let loaded = await loader.load(
            """
            <!doctype html><html><head><style>
            html,body { margin:0; width:400px; height:300px; }
            #a,#b { position:absolute; top:20px; width:100px; height:50px; }
            #a { left:10px; } #b { left:200px; }
            </style></head><body><button id="a">A</button><button id="b">B</button></body></html>
            """,
            in: webView
        )
        #expect(loaded)
        guard loaded else { return }

        _ = try await evaluateIsolated(
            in: webView,
            script: BrowserAnnotate.setEnabledScript(true, token: "storm-grant")
        )
        _ = try await evaluateIsolated(
            in: webView,
            script: """
            window.__pilotOriginalGetComputedStyle = window.getComputedStyle;
            window.__pilotStyleReads = 0;
            window.getComputedStyle = function () {
              window.__pilotStyleReads += 1;
              return window.__pilotOriginalGetComputedStyle.apply(window, arguments);
            };
            'installed';
            """
        )
        _ = try await evaluateString(in: webView, script: """
        var a = document.getElementById('a');
        var b = document.getElementById('b');
        for (var i = 0; i < 200; i += 1) {
          var target = i % 2 === 0 ? a : b;
          var x = i % 2 === 0 ? 20 : 220;
          target.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:x, clientY:30}));
        }
        'dispatched';
        """)
        try await Task.sleep(for: .milliseconds(50))

        let styleReads = try await evaluateIsolatedInt(
            in: webView,
            script: "window.__pilotStyleReads"
        )
        let finalGeometry = try await highlightGeometry(in: webView)

        #expect(styleReads <= 4)
        #expect(finalGeometry == "200px|20px|100px|50px")
    }

    @MainActor
    private func evaluateString(in webView: WKWebView, script: String) async throws -> String {
        try await webView.evaluateJavaScript(script) as? String ?? ""
    }

    @MainActor
    private func evaluateIsolated(in webView: WKWebView, script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(
                script,
                in: nil,
                in: BrowserAnnotate.contentWorld
            ) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func evaluateIsolatedInt(in webView: WKWebView, script: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(
                script,
                in: nil,
                in: BrowserAnnotate.contentWorld
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? NSNumber)?.intValue ?? 0)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func highlightGeometry(in webView: WKWebView) async throws -> String {
        try await evaluateString(in: webView, script: """
        var h = document.querySelector('[data-pilot-annotate-highlight]');
        h ? [h.style.left,h.style.top,h.style.width,h.style.height].join('|') : '';
        """)
    }
}

@MainActor
private final class BrowserLassoMessageSink: NSObject, WKScriptMessageHandler {
    private(set) var selectionIDs: [String] = []
    private(set) var selectors: [String] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let selectionID = body["selectionID"] as? String else { return }
        selectionIDs.append(selectionID)
        selectors.append(body["selector"] as? String ?? "")
    }
}

@MainActor
private final class BrowserLassoTestLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func load(_ html: String, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(false)
    }

    private func finish(_ loaded: Bool) {
        continuation?.resume(returning: loaded)
        continuation = nil
    }
}

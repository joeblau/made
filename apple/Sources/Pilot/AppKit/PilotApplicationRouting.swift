import AppKit

@MainActor
extension PilotApp {
    func remoteInputSurface() -> WorkspacePaneSurface {
        // A sheet or Settings can be key while its parent workspace window is
        // still AppKit's main window, so consult both while Cockpit is active.
        // Once the phone takes focus, rely on activation events remembered by
        // `CockpitWindowController`; AppKit may no longer expose a key window.
        var activeWindows = [NSApp.keyWindow].compactMap { $0 }
        if NSApp.isActive, let mainWindow = NSApp.mainWindow {
            activeWindows.append(mainWindow)
        }
        for window in activeWindows {
            let windowID = CGWindowID(window.windowNumber)
            if let surface = PilotRemoteInputRoutingPolicy.surface(
                activeWindowID: windowID,
                mainWindowID: mainWindowID,
                extensionWindowID: extensionWindowID
            ) {
                lastRemoteInputSurface = surface
                return surface
            }
        }
        return lastRemoteInputSurface
    }

    func activeTerminalPane(
        in workspaceID: UUID?,
        on surface: WorkspacePaneSurface
    ) -> Pane? {
        guard let workspaceID,
              let mainWorkspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }

        var extensionWorkspace: Workspace?
        if surface == .extension {
            if extensionWorkspaceController.selectedSourceID != workspaceID
                || extensionWorkspaceController.workspace(forSourceID: workspaceID) == nil {
                // Keep Extendo's companion selection in lockstep before capturing
                // the target. Deferred presentation could otherwise update one
                // run-loop later and speech could land in the previous project.
                extensionWorkspaceController.synchronize(with: mainWorkspace)
            }
            extensionWorkspace = extensionWorkspaceController.workspace(forSourceID: workspaceID)
        }

        return PilotRemoteInputRoutingPolicy.terminalPane(
            on: surface,
            mainWorkspace: mainWorkspace,
            extensionWorkspace: extensionWorkspace
        )
    }

    func terminalView(for paneID: UUID?) -> GhosttyMetalView? {
        guard let paneID else { return nil }
        return GhosttyMetalView.view(for: paneID)
    }

    func activeTerminalView() -> GhosttyMetalView? {
        let surface = remoteInputSurface()
        return terminalView(for: activeTerminalPane(
            in: store.selectedWorkspaceID,
            on: surface
        )?.id)
    }

    var walkieDelivery: PilotWalkieDelivery {
        PilotWalkieDelivery(store: store, terminalPaneID: { [self] workspaceID in
            activeTerminalPane(in: workspaceID, on: remoteInputSurface())?.id
        })
    }

    func selectRemoteWorkspace(_ workspaceID: UUID, on surface: WorkspacePaneSurface) {
        if workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
            store.enterRemoteDesktopMode()
            return
        }
        store.selectWorkspace(workspaceID)
        guard let terminalPane = activeTerminalPane(in: workspaceID, on: surface) else { return }
        terminalPane.workspace?.selectedPaneID = terminalPane.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            // Rapid volume taps can select another workspace before the native controller
            // attaches its view. An older delayed focus must not undo them.
            guard store.selectedWorkspaceID == workspaceID,
                  terminalPane.workspace?.selectedPaneID == terminalPane.id,
                  remoteInputSurface() == surface else { return }
            _ = GhosttyMetalView.focus(paneID: terminalPane.id)
        }
    }

    var selectedTerminalView: GhosttyMetalView? {
        guard let pane = keyWindowController?.selectedPane,
              pane.kind == .terminal else { return nil }
        return terminalView(for: pane.id)
    }

    func copyOrCaptureScreenshot() {
        // If a text editor (sheet field, address bar, etc.) is the
        // first responder, let it handle the standard copy.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.copy(_:)))
            return
        }

        // In a device, Simulator, or Android pane: ⌘C grabs a screenshot to
        // the clipboard, and each session's `clipboardCopyCount` drives its
        // toast. The menu command owns ⌘C, so the panes never see the key.
        if let pane = keyWindowController?.selectedPane {
            switch pane.kind {
            case .device:
                DeviceCaptureRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .simulator:
                SimulatorRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .android:
                AndroidDeviceRegistry.shared.session(for: pane.id).copyScreenshotToClipboard()
                return
            case .terminal, .browser, .editor, .agentChat:
                break
            }
        }

        sendStandardEditAction(#selector(NSText.copy(_:)))
    }

    func pasteIntoSelectedPane() {
        // If a text editor (sheet field, alert, address bar, etc.) is the
        // first responder, let it handle paste normally — otherwise the
        // terminal beneath the sheet would steal the keystroke.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.paste(_:)))
            return
        }

        // In an Android pane: ⌘V types the clipboard on the device. Must be
        // handled here — the menu command owns the key equivalent, so the
        // pane's host view never sees the keystroke.
        if let pane = keyWindowController?.selectedPane,
           pane.kind == .android {
            AndroidDeviceRegistry.shared.session(for: pane.id)
                .pasteFromClipboard()
            return
        }

        if let terminal = selectedTerminalView {
            terminal.paste(nil)
            return
        }

        sendStandardEditAction(#selector(NSText.paste(_:)))
    }

    func sendStandardEditAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    func setupSync() {
        guard !didSetupSync else {
            syncService.start()
            return
        }
        didSetupSync = true

        secureIdentity.send = { [weak self] in self?.syncService.send($0) }
        syncService.onReceive = { [weak self] (message: SyncMessage) in
            guard let self else { return }
            defer { self.refreshPresentations() }
            switch message {
            case .selectWorkspace(let sel):
                // Workspace selection follows the active Cockpit window.
                selectRemoteWorkspace(sel.workspaceID, on: remoteInputSurface())
            case .selectTab(let sel):
                if sel.workspaceID == WorkspaceStore.remoteDesktopWorkspaceID {
                    _ = store.selectRemoteDesktopTab(sel.tabID)
                    return
                }
                // Focus the workspace and tab selected on Copilot.
                store.selectWorkspace(sel.workspaceID)
                if let workspace = store.workspaces.first(where: { $0.id == sel.workspaceID }),
                   workspace.panes.contains(where: { $0.id == sel.tabID }) {
                    workspace.selectedPaneID = sel.tabID
                    // Ghostty focus is a no-op for browser/device panes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
                        guard store.selectedWorkspaceID == sel.workspaceID,
                              workspace.selectedPaneID == sel.tabID else { return }
                        _ = GhosttyMetalView.focus(paneID: sel.tabID)
                    }
                }
            case .workspaceState:
                break
            case .deviceStatus(let status):
                peerDeviceStatus = status
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
            case .voiceRecord(let command):
                switch command.control {
                case .start:
                    walkieDelivery.start(command, state: &walkieInput)
                case .stop:
                    walkieInput.stop(recordingID: command.recordingID, workspaceID: command.workspaceID)
                }
            case .transcribedSpeech(let speech):
                if !walkieDelivery.receive(speech, state: &walkieInput), !speech.text.isEmpty {
                    NSSound.beep()
                }
            case .executeTranscript(let command):
                walkieDelivery.execute(command, state: &walkieInput)
            case .followBuild(let request):
                buildPush.follow(request, available: actionWatcher.recentRuns)
            case .unfollowBuild(let request):
                buildPush.stop(runKey: request.runKey)
            case .buildRunUpdate:
                break
            case .terminalInput(.enter):
                walkieDelivery.enterSelection()
            case .deviceKey(let announce):
                // Auto-exchange device keys with Copilot (issue #51).
                secureIdentity.receive(announce)
            }
        }
        syncService.start()

        // Re-broadcast workspace state only when it actually changed; the 1s
        // tick otherwise encoded + sent an identical payload to Copilot every
        // second for the whole session. Reset on disconnect so a reconnecting
        // peer always gets a fresh snapshot.
        @MainActor final class LastBroadcast {
            var summaries: [WorkspaceSummary]?
            var selectedID: UUID?
            var runs: [BuildWorkflowRun]?
            var dashboard: DashboardSnapshotEnvelope?
        }
        let lastBroadcast = LastBroadcast()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard syncService.isConnected else {
                    lastBroadcast.summaries = nil
                    lastBroadcast.selectedID = nil
                    lastBroadcast.runs = nil
                    lastBroadcast.dashboard = nil
                    return
                }
                let summaries = store.syncSummaries
                let selectedID = store.selectedSyncWorkspaceID
                let runs = actionWatcher.recentRuns
                let dashboard = dashboardPublisher.envelope
                guard summaries != lastBroadcast.summaries
                        || selectedID != lastBroadcast.selectedID
                        || runs != lastBroadcast.runs
                        || dashboard != lastBroadcast.dashboard else { return }
                lastBroadcast.summaries = summaries
                lastBroadcast.selectedID = selectedID
                lastBroadcast.runs = runs
                lastBroadcast.dashboard = dashboard
                let state = WorkspaceState(
                    workspaces: summaries,
                    selectedWorkspaceID: selectedID,
                    workflowRuns: runs,
                    actionsDashboard: dashboard.actions,
                    usageDashboard: dashboard.usage,
                    runnersDashboard: dashboard.runners
                )
                syncService.send(.workspaceState(state))
            }
        }
    }

    func openDashboard(_ url: URL) {
        guard DashboardDeepLink.open(url, store: store) else { return }
        showMain()
        mainWindow?.refresh()
        NSApp.activate(ignoringOtherApps: true)
    }

    func sendLocalDeviceStatus() {
        let status = DeviceStatus(audioOutput: headphoneDetector.audioOutput)
        syncService.send(.deviceStatus(status))
    }
}

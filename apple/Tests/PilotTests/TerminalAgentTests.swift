import Foundation
import Testing
@testable import Pilot

/// The rules deciding whether a process running under a terminal pane's shell
/// is a coding agent. Real installs vary a lot in shape — native binaries,
/// version-numbered executables, and npm shims that exec a JS runtime — and a
/// false positive puts a wrong badge on the tab, so the negative cases matter
/// as much as the positive ones.
@Suite("Terminal agent process matching")
struct TerminalAgentTests {
    // MARK: - Native installs

    @Test
    func matchesNativeBinaryByName() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.local/bin/claude",
            arguments: ["/Users/j/.local/bin/claude"]
        )
        #expect(agent == .claude)
    }

    /// Claude Code's native install execs a version-numbered file, so the
    /// basename carries no agent name at all — only the enclosing directory.
    @Test
    func matchesVersionedNativeBinaryByDirectory() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.local/share/claude/versions/2.1.215",
            arguments: ["/Users/j/.local/share/claude/versions/2.1.215"]
        )
        #expect(agent == .claude)
    }

    @Test
    func matchesCodexVendorBinary() {
        let path = "/Users/j/.nvm/versions/node/v24.10.0/lib/node_modules/@openai/codex"
            + "/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #expect(TerminalAgent.match(executablePath: path, arguments: [path]) == .codex)
    }

    // MARK: - Script-runtime installs

    /// An npm install execs `node …/claude-code/cli.js`: the executable is the
    /// runtime, and only argv[1] names the agent.
    @Test
    func matchesNpmShimThroughScriptRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
        )
        #expect(agent == .claude)
    }

    @Test
    func matchesAiderThroughPython() {
        let agent = TerminalAgent.match(
            executablePath: "/opt/homebrew/bin/python3",
            arguments: ["python3", "/opt/homebrew/lib/python3.12/site-packages/aider/main.py"]
        )
        #expect(agent == .aider)
    }

    // MARK: - Kimi

    /// Kimi installs to `~/.kimi-code/bin/kimi` but execs with argv[0]
    /// `kimi-code`, so the executable basename and the argument vector
    /// disagree about its name. Both spellings have to resolve.
    @Test
    func matchesKimiByExecutablePath() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.kimi-code/bin/kimi",
            arguments: ["kimi-code"]
        )
        #expect(agent == .kimi)
    }

    @Test
    func matchesKimiByArgvName() {
        let agent = TerminalAgent.match(
            executablePath: nil,
            arguments: ["kimi-code"]
        )
        #expect(agent == .kimi)
    }

    // MARK: - Grok

    @Test
    func matchesGrokByExecutablePath() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/.local/bin/grok",
            arguments: ["/Users/j/.local/bin/grok"]
        )
        #expect(agent == .grok)
    }

    @Test
    func matchesGrokThroughScriptRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/lib/node_modules/grok-cli/dist/cli.js"]
        )
        #expect(agent == .grok)
    }

    // MARK: - Non-agents

    /// The case that motivates restricting argv inspection to script runtimes:
    /// an editor opened on a file named after an agent is not the agent.
    @Test
    func doesNotMatchEditorOpenedOnAgentNamedFile() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/bin/vim",
            arguments: ["vim", "/Users/j/project/claude.md"]
        )
        #expect(agent == nil)
    }

    @Test
    func doesNotMatchArbitraryArgumentsOfNonRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/bin/cat",
            arguments: ["cat", "/Users/j/.claude/settings.json"]
        )
        #expect(agent == nil)
    }

    /// Component matching must not fire on a directory that merely embeds an
    /// agent name inside a longer word.
    @Test
    func doesNotMatchSubstringOfLongerPathComponent() {
        let agent = TerminalAgent.match(
            executablePath: "/Users/j/src/notclaude/build/run",
            arguments: ["/Users/j/src/notclaude/build/run"]
        )
        #expect(agent == nil)
    }

    @Test
    func doesNotMatchIdleShell() {
        #expect(TerminalAgent.match(executablePath: "/bin/zsh", arguments: ["-zsh"]) == nil)
    }

    @Test
    func doesNotMatchBareScriptRuntime() {
        let agent = TerminalAgent.match(
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/Users/j/src/app/server.js"]
        )
        #expect(agent == nil)
    }

    @Test
    func returnsNilWithoutAnyProcessInformation() {
        #expect(TerminalAgent.match(executablePath: nil, arguments: []) == nil)
    }
}

@Suite("Terminal foreground activity")
struct TerminalProcessActivityTests {
    @Test("Interactive shells are idle")
    func classifiesInteractiveShellsAsIdle() {
        #expect(TerminalProcessActivity.classify(currentCommand: "zsh") == .idle)
        #expect(TerminalProcessActivity.classify(currentCommand: "-bash") == .idle)
        #expect(TerminalProcessActivity.classify(currentCommand: "/opt/homebrew/bin/fish") == .idle)
    }

    @Test("Foreground commands are running")
    func classifiesForegroundCommandsAsRunning() {
        #expect(TerminalProcessActivity.classify(currentCommand: "turbo") == .running)
        #expect(TerminalProcessActivity.classify(currentCommand: "bun") == .running)
        #expect(TerminalProcessActivity.classify(currentCommand: "/usr/local/bin/node") == .running)
    }

    @Test("Missing tmux output is idle")
    func classifiesMissingCommandAsIdle() {
        #expect(TerminalProcessActivity.classify(currentCommand: nil) == .idle)
        #expect(TerminalProcessActivity.classify(currentCommand: " \n") == .idle)
    }

    @Test("Native cursor distinguishes working agents from agents awaiting input")
    func classifiesAgentCursorActivity() {
        #expect(TerminalAgent.claude.activity(cursorVisible: true) == .idle)
        #expect(TerminalAgent.claude.activity(cursorVisible: false) == .running)
    }

    @Test("Claude background work is active even while its composer cursor is visible")
    func classifiesClaudeBackgroundActivity() {
        let contents = """
        · Slithering… (1m 36s · ↓ 1.0k tokens)
        ───────────────────────────────────────
        ❯
        ───────────────────────────────────────
        ⏵⏵ bypass permissions on · esc to interrupt · ← 2 agents
        """
        #expect(
            TerminalAgent.claude.activity(
                cursorVisible: true,
                visibleTerminalContents: contents
            ) == .running
        )
    }

    @Test("An idle Grok composer has no active status")
    func classifiesIdleGrokComposer() {
        let contents = """
        Worked for 16m27s           stop  [hooks: 1]

        ╭──────────────────────────────╮
        │ ❯ Build anything             │
        ╰──────── Grok 4.6 (xhigh) ─────╯
        Space:prompt  │  Enter:open  │  Ctrl+e:expand thinking
        """
        #expect(
            TerminalAgent.grok.activity(
                cursorVisible: false,
                visibleTerminalContents: contents
            ) == .idle
        )
    }

    @Test("A Grok background command counts as active work")
    func classifiesGrokBackgroundActivity() {
        let contents = """
        Worked for 16m27s           stop  [hooks: 1]

        ○ 1 command still running

        ╭──────────────────────────────╮
        │ ❯ Build anything             │
        ╰──────── Grok 4.6 (xhigh) ─────╯
        """
        #expect(
            TerminalAgent.grok.activity(
                cursorVisible: false,
                visibleTerminalContents: contents
            ) == .running
        )
    }

    @Test("Grok working statuses are active")
    func classifiesActiveGrokStatus() {
        let contents = """
        ╭──────────────────────────────╮
        │ ❯ Add the terminal counter   │
        ╰──────────────────────────────╯
        ⠋ Running tool
        """
        #expect(
            TerminalAgent.grok.activity(
                cursorVisible: false,
                visibleTerminalContents: contents
            ) == .running
        )
    }

    @Test("Kimi status distinguishes an active coder from its idle model label")
    func classifiesKimiStatus() {
        let idleContents = """
        ╭──────────────────────────────╮
        │ >                            │
        ╰──────────────────────────────╯
        auto  K3 thinking: high
        """
        let activeContents = """
        ⠸ thinking...
        Coder Agent Running (Fix IMG-1 icon system)
        """
        #expect(
            TerminalAgent.kimi.activity(
                cursorVisible: false,
                visibleTerminalContents: idleContents
            ) == .idle
        )
        #expect(
            TerminalAgent.kimi.activity(
                cursorVisible: false,
                visibleTerminalContents: activeContents
            ) == .running
        )
    }
}

@Suite("Terminal fast commands")
struct TerminalFastCommandTests {
    @Test("Commands persist independently for each terminal pane")
    func commandsAreStoredPerPane() throws {
        let suiteName = "TerminalFastCommandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPaneID = UUID()
        let secondPaneID = UUID()

        TerminalFastCommandStore.setCommand("bun dev", for: firstPaneID, defaults: defaults)
        TerminalFastCommandStore.setCommand("swift test", for: secondPaneID, defaults: defaults)

        #expect(TerminalFastCommandStore.command(for: firstPaneID, defaults: defaults) == "bun dev")
        #expect(TerminalFastCommandStore.command(for: secondPaneID, defaults: defaults) == "swift test")

        TerminalFastCommandStore.removeCommand(for: firstPaneID, defaults: defaults)
        #expect(TerminalFastCommandStore.command(for: firstPaneID, defaults: defaults).isEmpty)
        #expect(TerminalFastCommandStore.command(for: secondPaneID, defaults: defaults) == "swift test")
    }

    @Test("Only non-empty commands can execute")
    func executableCommandsAreTrimmed() {
        #expect(TerminalFastCommandStore.executableCommand(from: "  bun dev  ") == "bun dev")
        #expect(TerminalFastCommandStore.executableCommand(from: "\n\t ") == nil)
    }

    @Test("A running process turns the run button into restart")
    @MainActor
    func runButtonShowsRestartWhileRunning() {
        let idle = TerminalFastCommandToolbarActions.runButtonPresentation(command: "bun dev", activity: .idle)
        #expect(idle.symbol == "play.fill" && idle.label == "Run Fast Command")
        let running = TerminalFastCommandToolbarActions.runButtonPresentation(command: "bun dev", activity: .running)
        #expect(running.symbol == "arrow.clockwise" && running.label == "Restart Fast Command")
        #expect(running.toolTip.contains("bun dev"))
        let unset = TerminalFastCommandToolbarActions.runButtonPresentation(command: nil, activity: .running)
        #expect(unset.symbol == "play.fill")
    }

    @Test("Clearing a command removes its preference")
    func clearingCommandRemovesPreference() throws {
        let suiteName = "TerminalFastCommandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let paneID = UUID()

        TerminalFastCommandStore.setCommand("make serve", for: paneID, defaults: defaults)
        TerminalFastCommandStore.setCommand("", for: paneID, defaults: defaults)

        #expect(TerminalFastCommandStore.command(for: paneID, defaults: defaults).isEmpty)
    }
}

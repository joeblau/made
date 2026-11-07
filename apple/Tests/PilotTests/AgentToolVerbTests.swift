import Foundation
import Testing
@testable import Pilot

/// verbForTool mapping per agent shape, fallbacks, and the Thought reservation.
@Suite("Agent tool verbs")
struct AgentToolVerbTests {
    private func tool(
        _ name: String? = nil,
        title: String = "",
        kind: ACPToolKind? = nil,
        locations: [String] = [],
        edits: [AgentEditSummary] = [],
        subject: String? = nil
    ) -> AgentChatItem.ToolCall {
        var call = AgentChatItem.ToolCall(title: title, kind: kind, status: .completed, content: "")
        call.toolName = name
        call.locations = locations.map { ACPToolLocation(path: $0, line: nil) }
        call.edits = edits
        call.subject = subject
        return call
    }

    private func verb(
        _ name: String? = nil,
        _ input: JSONValue? = nil,
        title: String = "",
        kind: ACPToolKind? = nil,
        locations: [String] = [],
        edits: [AgentEditSummary] = [],
        subject: String? = nil
    ) -> AgentToolVerb {
        let call = tool(name, title: title, kind: kind, locations: locations, edits: edits, subject: subject)
        let result = verbForTool(call, input: input)
        #expect(AgentToolVerb.glyph(for: call, input: input) == result.glyph, "cheap glyph matches")
        #expect(result.settled != "Thought" && result.live != "Thought", "Thought is reserved for reasoning")
        return result
    }

    @Test
    func unknownToolFallsBackToItsTitle() {
        let tool = AgentChatItem.ToolCall(title: "Frobnicate", kind: nil, status: .completed, content: "")
        let verb = verbForTool(tool, input: nil)
        #expect(verb.glyph == .other)
        #expect(verb.settled == "Frobnicate")
    }

    // MARK: Shell

    @Test
    func claudeBashRunsTheCommand() {
        let result = verb("Bash", ["command": "git status", "description": "Show working tree status"], title: "git status", kind: .execute)
        #expect(result == AgentToolVerb(
            glyph: .shell, live: "Running git status", settled: "Ran git status",
            detail: "Show working tree status", exactInput: "git status"
        ))
    }

    static let shellCases: [(String, JSONValue)] = [
        ("exec_command", ["cmd": "make test"]),
        ("run_terminal_command", ["command": "make test"]),
        ("Shell", ["command": "make test"]),
        ("shell", ["command": ["bash", "-lc", "make test"]]),
        ("execute", ["command": "make test"]),
        ("run_shell_command", ["command": "make test"]),
        ("run_terminal_cmd", ["command": "make test"]),
    ]

    @Test(arguments: shellCases)
    func shellNamesAcrossAgents(name: String, input: JSONValue) {
        let result = verb(name, input)
        #expect(result.glyph == .shell)
        #expect(result.settled == "Ran make test")
        #expect(result.live == "Running make test")
    }

    @Test
    func codexArgvAndTitleOnlyShells() {
        #expect(verb(nil, ["command": ["bash", "-lc", "ls -la"]], title: "ls -la", kind: .execute).settled == "Ran ls -la")
        #expect(verb(nil, ["command": ["git", "commit", "-m", "two words"]], kind: .execute).settled == "Ran git commit -m 'two words'")
        #expect(verb(nil, nil, title: "npm test", kind: .execute).settled == "Ran npm test")
        #expect(verb(nil, nil, title: "find . -name '*.swift'", kind: .execute).settled == "Ran find . -name '*.swift'")
        #expect(verb(nil, nil, title: "Run swift build").settled == "Ran swift build")
        #expect(verb(nil, nil, kind: .execute).settled == "Ran a command")
    }

    @Test
    func shellLabelsShowTheFirstLineClippedAndExactInputShowsAll() {
        let result = verb("Bash", ["command": "git add .\ngit commit -m wip"])
        #expect(result.settled == "Ran git add .")
        #expect(result.exactInput == "git add .\ngit commit -m wip")
        let long = String(repeating: "x", count: 100)
        let clipped = verb("Bash", ["command": .string(long)])
        #expect(clipped.settled == "Ran " + String(repeating: "x", count: 59) + "…")
    }

    @Test
    func shellSecretsAreRedactedEverywhere() {
        let secret = "abcdefghijklmnopqrstuvwx"
        let result = verb(
            "Bash", ["command": .string("curl -H 'Authorization: Bearer \(secret)' https://api.io"), "description": .string("token=\(secret)")]
        )
        for text in [result.settled, result.live, result.detail ?? "", result.exactInput ?? ""] {
            #expect(!text.contains(secret), "\(text)")
            #expect(text.contains("••••"), "\(text)")
        }
    }

    @Test
    func exactInputEscapesControlAndBidiCharacters() {
        let result = verb("Bash", ["command": "echo \u{202E}txt.exe\u{0007}\tok"])
        #expect(result.exactInput == "echo \\u{202E}txt.exe\\u{7}\tok")
        #expect(result.settled == "Ran echo \\u{202E}txt.exe ok")
        let hidden = verb("Bash", ["command": "rm -rf ./build\u{200B}\u{E0041} /"])
        #expect(hidden.exactInput == "rm -rf ./build\\u{200B}\\u{E0041} /", "invisible format characters show")
    }

    @Test
    func secretFileContentIsMaskedInTheExactInput() throws {
        let input: JSONValue = ["file_path": "/repo/.env", "content": "DB_PASS=hunter2\nPGPASSWORD=s3cr3t\nSECRET_KEY_BASE=abc"]
        let write = verb("Write", input)
        let exact = try #require(write.exactInput)
        #expect(exact.contains("/repo/.env"))
        #expect(exact.contains("content: ••••"))
        for secret in ["hunter2", "s3cr3t", "abc"] { #expect(!exact.contains(secret), "\(secret)") }
        let edit = verb("Edit", ["file_path": "/u/.ssh/id_rsa", "old_string": "a", "new_string": "PRIVATE-BODY"])
        #expect(edit.exactInput?.contains("PRIVATE-BODY") == false)
        #expect(verb("Write", ["file_path": "/repo/a.txt", "content": "hello"]).exactInput?.contains("hello") == true)
    }

    @Test
    func approvalsDescribeTheRequestWithoutClaimingItRuns() {
        #expect(ApprovalCardView.requestPhrase(verb("Bash", ["command": "git push origin main"])) == "Run git push origin main")
        #expect(ApprovalCardView.requestPhrase(verb("Read", ["file_path": "/a/b.swift"])) == "Read b.swift")
        #expect(ApprovalCardView.requestPhrase(verb("Edit", ["file_path": "/a/b.swift"])) == "Edit b.swift")
        let unknown = verb(title: "Frobnicate widgets")
        #expect(ApprovalCardView.requestPhrase(unknown) == unknown.live)
    }

    @Test
    func exactInputIsBoundedAndRedactedBeforeTheCut() throws {
        let secret = "sk-ant-api03-" + String(repeating: "q7", count: 20)
        let longCommand = "export ANTHROPIC_API_KEY=\(secret) && " + String(repeating: "x", count: 100_000) + " " + secret
        let shell = verb("Bash", ["command": .string(longCommand)])
        let exact = try #require(shell.exactInput)
        #expect(exact.count <= AgentToolResolver.maximumExactInputLength + 1)
        #expect(exact.hasSuffix("…"))
        #expect(!exact.contains("q7q7"))
        #expect(exact.hasPrefix("export ANTHROPIC_API_KEY=sk-a•••• && xxx"))
        let content = String(repeating: "line\n", count: 40_000) + "token=abcdef"
        let write = verb("Write", ["file_path": "/a/new.txt", "content": .string(content)])
        #expect((write.exactInput?.count ?? .max) <= AgentToolResolver.maximumExactInputLength + 1)
        #expect(write.exactInput?.contains("abcdef") == false)
    }

    @Test
    func labelOnlyVerbsSkipTheExactInput() {
        let call = tool("Bash")
        let input: JSONValue = ["command": "git status"]
        let full = verbForTool(call, input: input)
        let labels = verbForTool(call, input: input, includeExactInput: false)
        #expect(labels.exactInput == nil)
        #expect(labels.live == full.live)
        #expect(labels.settled == full.settled)
        #expect(full.exactInput == "git status")
    }

    // MARK: Read

    static let readCases: [(String, JSONValue)] = [
        ("Read", ["file_path": "/repo/Sources/README.md"]),
        ("read_file", ["path": "Sources/README.md"]),
        ("ReadFile", ["path": "README.md"]),
        ("view", ["path": "/x/README.md"]),
    ]

    @Test(arguments: readCases)
    func readNamesAcrossAgents(name: String, input: JSONValue) {
        let result = verb(name, input)
        #expect(result.glyph == .read)
        #expect(result.settled == "Read README.md")
        #expect(result.live == "Reading README.md")
        #expect(result.detail == nil)
    }

    @Test
    func readingManyFilesListsTwoBasenames() {
        let result = verb("read_many_files", ["paths": ["/a/one.swift", "/a/two.swift", "/b/three.swift", "/c/four.swift"]])
        #expect(result.settled == "Read 4 files")
        #expect(result.live == "Reading 4 files")
        #expect(result.detail == "one.swift, two.swift +2")
        let pair = verb("Read", ["file_path": "/a/one.swift"], locations: ["/a/two.swift"])
        #expect(pair.settled == "Read 2 files")
        #expect(pair.detail == "one.swift, two.swift")
    }

    @Test
    func readByShapeTitleAndKind() {
        #expect(verb(nil, ["file_path": "/a/Package.swift"]).settled == "Read Package.swift")
        #expect(verb(nil, nil, title: "Read Notes.md", locations: ["/n/Notes.md"]).settled == "Read Notes.md")
        #expect(verb(nil, nil, title: "Open", kind: .read, subject: "notes.md").settled == "Read notes.md")
        #expect(verb(nil, nil, title: "Open", kind: .read).settled == "Read a file")
    }

    // MARK: Search

    @Test
    func searchesShowPatternAndRoot() {
        #expect(verb("Grep", ["pattern": "chain|protocol", "path": "/src/hyperevm"]).settled == #"Searched "chain|protocol" in hyperevm"#)
        #expect(verb("Glob", ["pattern": "**/*.swift"]).settled == #"Searched "**/*.swift" in repo"#)
        #expect(verb("grep", ["pattern": "TODO", "path": "src/"]).live == #"Searching "TODO" in src"#)
        #expect(verb("codebase_search", ["query": "transport fallback"]).settled == #"Searched "transport fallback" in repo"#)
        #expect(verb("Grep", ["pattern": "x"]).glyph == .search)
        #expect(verb(nil, ["pattern": "foo"]).settled == #"Searched "foo" in repo"#)
        #expect(verb(nil, nil, title: "Locate", kind: .search, subject: "Foo").settled == #"Searched "Foo" in repo"#)
        #expect(verb(nil, nil, title: "Locate", kind: .search).settled == "Searched repo")
        let long = verb("Grep", ["pattern": .string(String(repeating: "p", count: 50))])
        #expect(long.settled == #"Searched ""# + String(repeating: "p", count: 39) + #"…" in repo"#)
    }

    // MARK: Edit and create

    @Test(arguments: ["Edit", "MultiEdit", "search_replace", "hashline_edit", "apply_patch", "str_replace", "StrReplaceFile"])
    func editNamesAcrossAgents(name: String) {
        let edits = [AgentEditSummary(path: "/src/transport.ts", added: 42, removed: 7, created: false)]
        let result = verb(name, ["file_path": "/src/transport.ts", "old_string": "a", "new_string": "b"], edits: edits)
        #expect(result.glyph == .edit)
        #expect(result.settled == "Edited transport.ts (+42 \u{2212}7)")
        #expect(result.live == "Editing transport.ts")
    }

    @Test
    func editsWithoutCountsAndAcrossFiles() {
        #expect(verb("Edit", ["file_path": "/a/x.swift"]).settled == "Edited x.swift")
        let unknown = [AgentEditSummary(path: "/a/x.swift", added: nil, removed: nil, created: false)]
        #expect(verb("Edit", ["file_path": "/a/x.swift"], edits: unknown).settled == "Edited x.swift")
        let codex = verb(nil, ["changes": ["/a/x.swift": ["type": "update"], "/a/y.swift": ["type": "add"]]], title: "Edit files", kind: .edit)
        #expect(codex.settled == "Edited 2 files")
        #expect(codex.detail == "x.swift, y.swift")
        #expect(verb(nil, nil, title: "Modify", kind: .edit).settled == "Edited a file")
        #expect(verb(nil, ["file_path": "/a/z.swift", "old_string": "a", "new_string": "b"]).glyph == .edit)
    }

    @Test
    func writesCreateNewFilesAndEditExistingOnes() {
        let created = [AgentEditSummary(path: "/a/new.swift", added: 10, removed: 0, created: true)]
        #expect(verb("Write", ["file_path": "/a/new.swift", "content": "x"], edits: created).settled == "Created new.swift")
        #expect(verb("Write", ["file_path": "/a/new.swift", "content": "x"], edits: created).live == "Creating new.swift")
        #expect(verb("WriteFile", ["path": "/a/kimi.txt", "content": "x"]).settled == "Created kimi.txt")
        #expect(verb("create_file", ["path": "/a/grok.txt", "content": "x"]).glyph == .create)
        let overwrite = [AgentEditSummary(path: "/a/old.swift", added: 1, removed: 1, created: false)]
        let result = verb("Write", ["file_path": "/a/old.swift", "content": "x"], edits: overwrite)
        #expect(result.glyph == .edit)
        #expect(result.settled == "Edited old.swift (+1 \u{2212}1)")
        #expect(verb(nil, ["file_path": "/a/s.txt", "content": "x"]).glyph == .create)
    }

    // MARK: Network

    @Test(arguments: ["WebFetch", "fetch", "FetchURL", "web_fetch"])
    func fetchShowsHostAndPathOnly(name: String) {
        let result = verb(name, ["url": "https://example.com/docs/page?token=abc#frag"])
        #expect(result.glyph == .fetch)
        #expect(result.settled == "Fetched example.com/docs/page")
        #expect(result.live == "Fetching example.com/docs/page")
        #expect(result.exactInput == "url: https://example.com/docs/page?token=••••")
    }

    @Test
    func fetchClipsAndFallsBack() {
        let long = verb(nil, ["url": .string("https://example.com/" + String(repeating: "a", count: 80))])
        #expect(long.settled.count == "Fetched ".count + 48)
        #expect(long.settled.hasSuffix("…"))
        #expect(verb(nil, nil, title: "Get", kind: .fetch).settled == "Fetched a page")
        #expect(verb(nil, nil, title: "Fetch https://x.io/a").glyph == .fetch)
        #expect(verb("WebFetch", ["url": "https://bob:hunter2@x.io/a"]).settled == "Fetched x.io/a")
        #expect(AgentToolResolver.urlLabel("bob:hunter2@x.io/a?q=1") == "x.io/a", "unparsed URLs drop user info")
    }

    @Test(arguments: ["WebSearch", "web_search", "SearchWeb"])
    func webSearchQuotesTheQuery(name: String) {
        let result = verb(name, ["query": "swift actors reentrancy"])
        #expect(result.glyph == .web)
        #expect(result.settled == #"Searched the web for "swift actors reentrancy""#)
        #expect(result.live == #"Searching the web for "swift actors reentrancy""#)
    }

    @Test
    func webSearchByShapeNeedsAWebHint() {
        #expect(verb(nil, ["query": "x"], kind: .fetch).glyph == .web)
        #expect(verb(nil, ["query": "x"], title: "Web search").glyph == .web)
        #expect(verb(nil, ["query": "x"]).glyph == .search)
        #expect(verb("WebSearch").settled == "Searched the web")
    }

    // MARK: Plan, agents, MCP, skills, compact

    @Test(arguments: ["TodoWrite", "todo_write", "update_plan", "SetTodoList"])
    func planUpdates(name: String) {
        let result = verb(name, ["todos": [["status": "completed"], ["status": "in_progress"], ["status": "pending"]]])
        #expect(result.glyph == .plan)
        #expect(result.settled == "Updated plan")
        #expect(result.live == "Updating plan")
        #expect(result.detail == "1/3 done")
    }

    @Test(arguments: ["Task", "Agent"])
    func delegation(name: String) {
        let result = verb(name, ["description": "Research ethereum", "prompt": "Find…", "subagent_type": "general-purpose"])
        #expect(result.glyph == .agent)
        #expect(result.settled == "Delegated: Research ethereum")
        #expect(result.live == "Delegating: Research ethereum")
        #expect(result.detail == "general-purpose")
    }

    @Test
    func delegationByShapeAndTitle() {
        #expect(verb(nil, ["description": "Audit", "prompt": "p"]).settled == "Delegated: Audit")
        #expect(verb("Task", nil, title: "Review the diff").settled == "Delegated: Review the diff")
        let long = verb("Task", ["description": .string(String(repeating: "d", count: 60))])
        #expect(long.settled == "Delegated: " + String(repeating: "d", count: 47) + "…")
    }

    @Test
    func mcpToolsNameServerAndTool() {
        let result = verb("mcp__github__create_issue", ["title": "Bug"])
        #expect(result == AgentToolVerb(
            glyph: .mcp, live: "Using github · create_issue", settled: "Used github · create_issue",
            detail: nil, exactInput: "title: Bug"
        ))
        #expect(verb("mcp__plugin_x__tool__nested").settled == "Used plugin_x · tool__nested")
        #expect(verb(nil, nil, title: "mcp__linear__list_issues").settled == "Used linear · list_issues")
    }

    @Test
    func bareToolNameTitlesResolveLikeNames() {
        #expect(verb(nil, nil, title: "spawn_subagent").glyph == .agent, "Grok's spawn call")
        #expect(verb(nil, nil, title: "read_file", locations: ["/a/b.swift"]).settled == "Read b.swift")
        #expect(verb(nil, nil, title: "spawn_subagent").settled == "Delegated", "a bare tool name is no description")
        #expect(verb(nil, nil, title: "update_todo_list").glyph == .plan)
        #expect(verb("str_replace_editor", ["path": "/a/c.swift", "old_str": "a"]).glyph == .edit)
        #expect(verb("create_todo_list", ["todos": [["status": "pending"]]]).settled == "Updated plan")
        #expect(verb(nil, nil, title: "frobnicate_widget").settled == "frobnicate_widget", "unknown names fall back")
    }

    @Test
    func skillsAndCompaction() {
        #expect(verb("Skill", ["skill": "pdf"]).settled == "Used skill pdf")
        #expect(verb("Skill", ["skill": "pdf"]).glyph == .other)
        #expect(verb(nil, ["skill": "xlsx"]).live == "Using skill xlsx")
        #expect(verb(nil, nil, title: "Compact conversation").settled == "Compacted conversation")
        #expect(verb("compact").live == "Compacting conversation")
    }

    // MARK: Kind fallbacks

    @Test
    func kindFallbacksUseGenericVerbs() {
        #expect(verb(nil, nil, title: "rm out", kind: .delete, locations: ["/b/out.o"]).settled == "Deleted out.o")
        #expect(verb(nil, nil, title: "mv a b", kind: .move, locations: ["/b/a.txt"]).settled == "Moved a.txt")
        #expect(verb(nil, nil, title: "Plan mode", kind: .switchMode).settled == "Switched mode")
        let think = verb(nil, nil, title: "Pondering", kind: .think)
        #expect(think.glyph == .think)
        #expect(think.settled == "Reasoned")
        #expect(verb(nil, nil, title: "Do a thing", kind: .other).settled == "Do a thing")
    }

    // MARK: Resolution order

    @Test
    func resolutionOrder() {
        #expect(verb("Read", ["command": "x", "file_path": "/a/b.txt"]).glyph == .read, "name beats shape")
        #expect(verb(nil, ["command": "ls"], title: "Read file").glyph == .shell, "shape beats title")
        #expect(verb(nil, nil, title: "Read notes.md", kind: .other).glyph == .read, "title beats kind")
        #expect(verb("custom_runner", ["command": "ls"]).glyph == .shell, "unknown name falls to shape")
        #expect(verb(nil, nil, title: "grep foo", kind: .execute).glyph == .shell, "execute titles are commands")
    }

    // MARK: Fallbacks

    @Test
    func fallbacksNeverShowThoughtOrRawJSON() {
        #expect(verb("frobnicate").settled == "frobnicate")
        #expect(verb(nil, nil, title: "").settled == "Tool call")
        #expect(verb(nil, nil, title: #"{"command":"ls"}"#).settled == "Tool call")
        #expect(verb(nil, nil, title: "[1,2]", kind: .other).settled == "Tool call")
        #expect(verb(nil, nil, title: "Thought").settled == "Thought step")
        #expect(verb(nil, nil, title: "Tool call").settled == "Tool call")
        let secretTitle = verb(nil, nil, title: "Deploy with ghp_\(String(repeating: "Z", count: 36))")
        #expect(secretTitle.settled == "Deploy with ghp_••••")
    }

    @Test
    func labelsAreSingleLineAndRedacted() {
        let result = verb(nil, nil, title: "Line one\nline two token=abc")
        #expect(result.settled == "Line one")
        let paths = verb("Read", ["file_path": "/a/\u{202E}gpj.exe"])
        #expect(paths.settled == "Read \\u{202E}gpj.exe")
    }

    @Test
    func genericExactInputIsSortedRedactedKeyValues() {
        let result = verb("Read", ["file_path": "/a/b.txt", "limit": 20, "api_key": "abc"])
        #expect(result.exactInput == "api_key: ••••\nfile_path: /a/b.txt\nlimit: 20")
        #expect(verb("Read", nil, title: "Read b").exactInput == nil)
    }

    // MARK: Thoughts

    @Test
    func thoughtsReportTheirDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(100)
        let settled = verbForThought(.init(text: "x", startedAt: start, endedAt: start.addingTimeInterval(12)), now: now)
        #expect(settled == AgentToolVerb(glyph: .think, live: "Thinking", settled: "Thought for 12s", detail: nil, exactInput: nil))
        #expect(verbForThought(.init(text: "x", startedAt: start, endedAt: start.addingTimeInterval(75)), now: now).settled == "Thought for 1m 15s")
        #expect(verbForThought(.init(text: "x", startedAt: start, endedAt: start.addingTimeInterval(0.2)), now: now).settled == "Thought for 1s")
        #expect(verbForThought(.init(text: "x"), now: now).settled == "Thought")
        let open = verbForThought(.init(text: "x", startedAt: now.addingTimeInterval(-5)), now: now)
        #expect(open.live == "Thinking for 5s")
        #expect(open.settled == "Thought")
    }

    @Test
    func itemVerbsCoverToolsAndThoughtsOnly() {
        let now = Date(timeIntervalSince1970: 0)
        let toolItem = AgentChatItem(id: "tool-1", content: .tool(tool("Bash")))
        #expect(verbForItem(toolItem, input: ["command": "ls"], now: now)?.settled == "Ran ls")
        let thoughtItem = AgentChatItem(id: "t", content: .thought(.init(text: "hm")))
        #expect(verbForItem(thoughtItem, input: nil, now: now)?.settled == "Thought")
        #expect(verbForItem(AgentChatItem(id: "u", content: .user("hi")), input: nil, now: now) == nil)
    }

    @Test
    func durationsFormat() {
        #expect(AgentActivityFormat.duration(0) == "0s")
        #expect(AgentActivityFormat.duration(42.4) == "42s")
        #expect(AgentActivityFormat.duration(185) == "3m 05s")
        #expect(AgentActivityFormat.duration(3_725) == "1h 02m")
        #expect(AgentActivityFormat.duration(-.infinity) == "0s")
    }
}

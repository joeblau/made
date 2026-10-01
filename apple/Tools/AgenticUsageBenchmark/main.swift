import Foundation

// Synthetic multi-provider corpus benchmark for AgenticUsageLoader: cold
// load, unchanged refresh, small append (with parity against a full rescan),
// and cancellation latency. Build and run it with `run.sh`, which can compile
// the loader from any revision; only the loader's `load()` API is used so
// revisions stay comparable.

let claudeUsage = #"{"type":"assistant","requestId":"req_%d","timestamp":"2026-08-14T10:%02d:%02d.000Z","message":{"id":"msg_%d","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000,"output_tokens":%d}}}"#
let codexContext = #"{"timestamp":"2026-08-14T02:34:00.000Z","ordinal":%d,"type":"turn_context","payload":{"turn_id":"t%d","model":"gpt-5.6-sol"}}"#
let codexCount = #"{"timestamp":"2026-08-14T02:%02d:%02d.653Z","ordinal":%d,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":%d,"cache_write_input_tokens":0,"output_tokens":%d,"reasoning_output_tokens":71,"total_tokens":1},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":71,"total_tokens":1100}}}}"#
let grokTurn = #"{"timestamp":%d,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":30596,"outputTokens":3338,"totalTokens":33934,"cachedReadTokens":1024,"reasoningTokens":307,"costUsdTicks":794792000}}}}"#
let kimiTurn = #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":2134,"output":99,"inputCacheRead":18944,"inputCacheCreation":0},"usageScope":"turn","time":%d}"#
let filler = "{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "lorem ipsum dolor sit amet ", count: 70) + "\"}}"

final class Writer {
    var serial = 0
    func claudeLines(_ count: Int) -> String {
        var out = ""
        for _ in 0..<count {
            serial += 1
            out += String(format: claudeUsage, serial, serial % 60, serial % 60, serial, 50 + serial % 300) + "\n"
            out += filler + "\n" + filler + "\n"
        }
        return out
    }
    var codexTotal = 0
    func codexLines(_ count: Int) -> String {
        var out = String(format: codexContext, serial, serial) + "\n"
        for _ in 0..<count {
            serial += 1
            codexTotal += 1000
            out += String(format: codexCount, serial % 60, serial % 60, serial, codexTotal, codexTotal / 2, codexTotal / 10) + "\n"
            out += filler + "\n" + filler + "\n"
        }
        return out
    }
    func grokLines(_ count: Int) -> String {
        var out = ""
        for _ in 0..<count {
            serial += 1
            out += String(format: grokTurn, 1_784_526_657 + serial) + "\n" + filler + "\n"
        }
        return out
    }
    func kimiLines(_ count: Int) -> String {
        var out = ""
        for _ in 0..<count {
            serial += 1
            out += String(format: kimiTurn, 1_785_821_544_387 + serial) + "\n" + filler + "\n"
        }
        return out
    }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

func generate(root: URL) throws {
    try? FileManager.default.removeItem(at: root)
    let writer = Writer()
    // ~4 KB per Claude/Codex usage triple. Large files approximate long-lived
    // sessions; many small files approximate the typical corpus.
    try write(writer.claudeLines(32_000), to: root.appendingPathComponent("claude/projects/big/session-big.jsonl"))
    for index in 0..<200 {
        try write(writer.claudeLines(250), to: root.appendingPathComponent("claude/projects/p\(index % 20)/s\(index).jsonl"))
    }
    try write(writer.codexLines(32_000), to: root.appendingPathComponent("codex/sessions/2026/08/14/rollout-big.jsonl"))
    for index in 0..<100 {
        try write(writer.codexLines(250), to: root.appendingPathComponent("codex/sessions/2026/08/\(index % 28)/rollout-\(index).jsonl"))
    }
    for index in 0..<50 {
        try write(writer.grokLines(120), to: root.appendingPathComponent("grok/sessions/s\(index)/updates.jsonl"))
        try write(writer.kimiLines(120), to: root.appendingPathComponent("kimi/sessions/s\(index)/wire.jsonl"))
    }
}

func sources(_ root: URL) -> [AgenticUsageLoader.Source] {
    [
        .init(provider: .claude, rootDirectory: root.appendingPathComponent("claude/projects")),
        .init(provider: .codex, rootDirectory: root.appendingPathComponent("codex/sessions")),
        .init(provider: .codex, rootDirectory: root.appendingPathComponent("codex/archived_sessions")),
        .init(provider: .grok, rootDirectory: root.appendingPathComponent("grok/sessions"), fileName: "updates.jsonl"),
        .init(provider: .kimi, rootDirectory: root.appendingPathComponent("kimi"), fileName: "wire.jsonl"),
    ]
}

func corpusBytes(_ root: URL) -> Int {
    var total = 0
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
    while let url = enumerator?.nextObject() as? URL {
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return total
}

@MainActor func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = ContinuousClock.now
    let value = try await body()
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return (value, seconds * 1000)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func cpuMilliseconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
    let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
    return user + system
}

@main
struct Bench {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let runs = 3
        try generate(root: root)
        let bytes = corpusBytes(root)
        print(String(format: "corpus: %.1f MB", Double(bytes) / 1_048_576))

        var cold: [Double] = []
        var unchanged: [Double] = []
        var appended: [Double] = []
        var parity = true
        var recordCount = 0
        for run in 0..<runs {
            try generate(root: root)
            let loader = AgenticUsageLoader(sources: sources(root))
            let (first, coldMs) = try await time { try await loader.load() }
            cold.append(coldMs)
            recordCount = first.records.count
            let (_, unchangedMs) = try await time { try await loader.load() }
            unchanged.append(unchangedMs)

            // Small append: a few new calls to the two big logs and one
            // small file, including a partial trailing line completed later.
            let writer = Writer()
            writer.serial = 10_000_000 + run * 1000
            writer.codexTotal = 32_000 * 1000 + 250 * 100 * 1000
            try append(writer.claudeLines(5), to: root.appendingPathComponent("claude/projects/big/session-big.jsonl"))
            try append(writer.codexLines(5), to: root.appendingPathComponent("codex/sessions/2026/08/14/rollout-big.jsonl"))
            try append(writer.kimiLines(3), to: root.appendingPathComponent("kimi/sessions/s0/wire.jsonl"))
            let (incremental, appendMs) = try await time { try await loader.load() }
            appended.append(appendMs)
            let rescan = try await AgenticUsageLoader(sources: sources(root)).load()
            if incremental.records != rescan.records { parity = false }
        }
        print(String(format: "records: %d", recordCount))
        print(String(format: "cold load median: %.1f ms  (%@)", median(cold), cold.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        print(String(format: "unchanged refresh median: %.2f ms  (%@)", median(unchanged), unchanged.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
        print(String(format: "small append median: %.1f ms  (%@)", median(appended), appended.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        print("append parity with full rescan: \(parity)")

        // Cancellation: start a cold load, cancel after 150 ms, and measure
        // how long the cancelled task keeps running and burning CPU.
        var latencies: [Double] = []
        var cpuAfterCancel: [Double] = []
        for _ in 0..<runs {
            let loader = AgenticUsageLoader(sources: sources(root))
            let task = Task { try await loader.load() }
            try await Task.sleep(for: .milliseconds(150))
            let cpuAtCancel = cpuMilliseconds()
            let (_, latency) = await time {
                task.cancel()
                _ = try? await task.value
            }
            cpuAfterCancel.append(cpuMilliseconds() - cpuAtCancel)
            latencies.append(latency)
        }
        print(String(format: "cancel-to-stop median: %.1f ms  (%@)", median(latencies), latencies.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        print(String(format: "CPU after cancel median: %.1f ms  (%@)", median(cpuAfterCancel), cpuAfterCancel.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        try? FileManager.default.removeItem(at: root)
    }
}

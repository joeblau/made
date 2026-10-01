// Synthetic H264AnnexBAssembler benchmark (GitHub issue #265).
//
// Build and run with apple/bin/benchmark-annexb.sh. The input is one large
// access unit — a 4-byte start code, an IDR header (65 80), and 262,144 bytes
// of 0x55 — fed to eight independent parser instances in fixed-size chunks,
// followed by flushTrailing(). This measures the parser alone, not device
// latency.

import Darwin
import Foundation

// MARK: - Allocation counting

// libmalloc invokes `malloc_logger` (the stack-logging hook) for every
// allocation and free while it is non-nil. Counting through it needs no
// private headers, and the hook itself never allocates.
typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) var allocationCount = 0
nonisolated(unsafe) var allocatedBytes = 0
let mallocLogTypeAllocate: UInt32 = 2
let mallocLogTypeDeallocate: UInt32 = 4
let mallocLogTypeHasZone: UInt32 = 8

let countingLogger: MallocLogger = { type, arg1, arg2, arg3, _, _ in
    guard type & mallocLogTypeAllocate != 0 else { return }
    allocationCount += 1
    // With a zone argument the size is arg2 (malloc) or arg3 (realloc).
    let hasZone = type & mallocLogTypeHasZone != 0
    if type & mallocLogTypeDeallocate != 0 {
        allocatedBytes += Int(hasZone ? arg3 : arg2)
    } else {
        allocatedBytes += Int(hasZone ? arg2 : arg1)
    }
}

nonisolated(unsafe) let loggerSlot: UnsafeMutablePointer<MallocLogger?>? = {
    // RTLD_DEFAULT
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    return symbol.assumingMemoryBound(to: MallocLogger?.self)
}()

// MARK: - Workload

let parserInstances = 8
let payloadBytes = 262_144
var input = Data([0, 0, 0, 1, 0x65, 0x80])
input.append(Data(repeating: 0x55, count: payloadBytes))

struct Measurement {
    var seconds: Double
    var events: Int
    var allocations: Int
    var allocatedBytes: Int
}

@MainActor func run(chunkSize: Int) throws -> Measurement {
    let chunks = stride(from: 0, to: input.count, by: chunkSize).map {
        input.subdata(in: $0..<min($0 + chunkSize, input.count))
    }
    var events = 0
    allocationCount = 0
    allocatedBytes = 0
    loggerSlot?.pointee = countingLogger
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<parserInstances {
        var assembler = H264AnnexBAssembler()
        for chunk in chunks {
            events += try assembler.feed(chunk).count
        }
        events += try assembler.flushTrailing().count
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    loggerSlot?.pointee = nil
    return Measurement(
        seconds: Double(elapsed) / 1e9,
        events: events,
        allocations: allocationCount,
        allocatedBytes: allocatedBytes
    )
}

let repetitions = Int(ProcessInfo.processInfo.environment["ANNEXB_BENCH_REPETITIONS"] ?? "") ?? 5
print("H264AnnexBAssembler: \(parserInstances) instances x \(input.count) bytes, median of \(repetitions) runs")
if loggerSlot == nil { print("(allocation counting unavailable: malloc_logger not found)") }
print("chunk_bytes\tseconds\tevents\tallocations\tallocated_bytes")
for chunkSize in [1_024, 4_096, 65_536] {
    var samples: [Measurement] = []
    for _ in 0..<repetitions {
        samples.append(try run(chunkSize: chunkSize))
    }
    samples.sort { $0.seconds < $1.seconds }
    let median = samples[samples.count / 2]
    print(String(
        format: "%d\t%.5f\t%d\t%d\t%d",
        chunkSize, median.seconds, median.events, median.allocations, median.allocatedBytes
    ))
}

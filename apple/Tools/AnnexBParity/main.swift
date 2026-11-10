// Annex-B parser parity check on a captured device stream (GitHub issue #265).
//
// Build and run with apple/bin/check-annexb-parity.sh. Feeds one raw
// `screenrecord --output-format=h264` capture to `H264AnnexBAssembler` in
// fixed 1 KiB/4 KiB/64 KiB/1 MiB chunks, and in deterministic pseudo-random chunk sizes
// (1 byte to 64 KiB, so start codes land across every kind of boundary), then
// prints one event digest per chunking. Every line must match within a run,
// and the digests must match across assembler revisions compiled against the
// same harness.

import CryptoKit
import Foundation

struct Digest {
    var hasher = SHA256()
    var parameterSets = 0
    var accessUnits = 0
    var idrUnits = 0
    var bytes = 0

    mutating func add(_ events: [H264AnnexBAssembler.Event]) {
        for event in events {
            switch event {
            case .parameterSets(let sps, let pps):
                parameterSets += 1
                hasher.update(data: Data("P\(sps.count):\(pps.count):".utf8))
                hasher.update(data: sps)
                hasher.update(data: pps)
            case .accessUnit(let data, let isIDR):
                accessUnits += 1
                if isIDR { idrUnits += 1 }
                bytes += data.count
                hasher.update(data: Data("A\(isIDR ? 1 : 0):\(data.count):".utf8))
                hasher.update(data: data)
            }
        }
    }

    var line: String {
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "parameter_sets=\(parameterSets) access_units=\(accessUnits) idr=\(idrUnits) bytes=\(bytes) sha256=\(hex)"
    }
}

/// SplitMix64: deterministic, so a chunking is reproducible from its seed.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func digest(_ input: Data, chunkSizes: () -> Int) throws -> String {
    var assembler = H264AnnexBAssembler()
    var digest = Digest()
    var offset = input.startIndex
    while offset < input.endIndex {
        let end = min(offset + chunkSizes(), input.endIndex)
        digest.add(try assembler.feed(input.subdata(in: offset..<end)))
        offset = end
    }
    digest.add(try assembler.flushTrailing())
    return digest.line
}

let arguments = CommandLine.arguments
guard arguments.count == 2, let input = FileManager.default.contents(atPath: arguments[1]), !input.isEmpty else {
    FileHandle.standardError.write(Data("usage: annexb-parity <capture.h264>\n".utf8))
    exit(2)
}

var lines: [(String, String)] = []
// The largest read stays well under the assembler's 4 MiB buffer cap, which
// a whole-file feed would (correctly) trip.
for size in [1_024, 4_096, 65_536, 1_048_576] {
    lines.append(("fixed-\(size)", try digest(input) { size }))
}
for seed in [UInt64(1), 2, 3] {
    var random = SplitMix64(state: seed)
    // Skew toward small reads so most boundaries fall inside start codes and
    // NAL headers, with occasional large reads like a busy pipe.
    lines.append(("random-\(seed)", try digest(input) {
        let roll = random.next()
        return Int(roll % 4 == 0 ? (roll >> 8) % 65_536 : (roll >> 8) % 7) + 1
    }))
}

print("capture_bytes=\(input.count)")
for (name, line) in lines {
    print("\(name)\t\(line)")
}
let distinct = Set(lines.map(\.1))
print(distinct.count == 1 ? "parity: identical across \(lines.count) chunkings" : "parity: MISMATCH")
exit(distinct.count == 1 ? 0 : 1)

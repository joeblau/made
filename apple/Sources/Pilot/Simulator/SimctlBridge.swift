import Foundation

/// Errors surfaced by `simctl` invocations. `toolingMissing` is the friendly
/// case for a machine with only the Command Line Tools (no full Xcode), where
/// `xcrun simctl` cannot run — the pane shows guidance instead of crashing.
enum SimctlError: Error {
    case toolingMissing
    case commandFailed(String)
}

/// One iOS Simulator device from `xcrun simctl list devices available --json`.
struct SimDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let state: String                 // "Booted", "Shutdown", "Booting", ...
    let deviceTypeIdentifier: String?
    let runtimeIdentifier: String     // the dictionary key, e.g. ...SimRuntime.iOS-26-4

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }

    /// Keep the list focused on the phones/tablets a user actually opens; hide
    /// watch/tv/vision runtimes that would clutter the picker.
    var isPhoneOrPad: Bool {
        guard let deviceTypeIdentifier else { return false }
        return deviceTypeIdentifier.contains("iPhone") || deviceTypeIdentifier.contains("iPad")
    }
}

/// Devices grouped under a single runtime, for sectioned display.
struct SimRuntimeGroup: Identifiable, Hashable, Sendable {
    let id: String            // runtime identifier (stable, unique)
    let displayName: String   // "iOS 26.4"
    let sortKey: String       // for newest-first ordering
    let devices: [SimDevice]
}

/// Typed wrapper over the `xcrun simctl` CLI. All calls are blocking and must be
/// run off the main actor (the session uses `Task.detached`).
enum SimctlBridge {
    /// Run `/usr/bin/xcrun <args>`, draining stdout/stderr concurrently so a
    /// large JSON payload can't deadlock against a full pipe buffer.
    static func runXcrun(_ args: [String]) throws -> Data {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: args,
            timeout: args.contains("bootstatus") ? .seconds(120) : .seconds(30),
            standardOutputLimit: 16 * 1_024 * 1_024,
            standardErrorLimit: 1 * 1_024 * 1_024
        )
        do {
            return try ProcessRunner.runBlocking(invocation).standardOutput
        } catch let error as ProcessRunnerError {
            let message = error.result?.standardErrorString ?? error.localizedDescription
            if message.contains("unable to find utility")
                || message.contains("requires Xcode")
                || message.contains("only the Command Line Tools") {
                throw SimctlError.toolingMissing
            }
            throw SimctlError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Listing

    private struct DeviceListResponse: Decodable {
        let devices: [String: [Device]]
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let deviceTypeIdentifier: String?
            let isAvailable: Bool?
        }
    }

    /// Available iPhone/iPad simulators, grouped by runtime, newest runtime first
    /// and booted/alphabetical within each group.
    static func listDevices() throws -> [SimRuntimeGroup] {
        let data = try runXcrun(["simctl", "list", "devices", "available", "--json"])
        let response = try JSONDecoder().decode(DeviceListResponse.self, from: data)

        var groups: [SimRuntimeGroup] = []
        for (runtimeID, rawDevices) in response.devices {
            let devices = rawDevices
                .filter { $0.isAvailable != false }
                .map { raw in
                    SimDevice(
                        udid: raw.udid,
                        name: raw.name,
                        state: raw.state,
                        deviceTypeIdentifier: raw.deviceTypeIdentifier,
                        runtimeIdentifier: runtimeID
                    )
                }
                .filter(\.isPhoneOrPad)
                .sorted { lhs, rhs in
                    if lhs.isBooted != rhs.isBooted { return lhs.isBooted && !rhs.isBooted }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !devices.isEmpty else { continue }
            groups.append(
                SimRuntimeGroup(
                    id: runtimeID,
                    displayName: runtimeDisplayName(runtimeID),
                    sortKey: runtimeSortKey(runtimeID),
                    devices: devices
                )
            )
        }
        // Newest runtime first.
        return groups.sorted { $0.sortKey > $1.sortKey }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" -> "iOS 26.4".
    /// Device-specific runtimes carry a hardware suffix after the version
    /// ("iOS-27-2-iPhone19-4"); it renders as "iOS 27.2 (iPhone19,4)" so the
    /// section stays distinct from the general iOS 27.2 runtime instead of
    /// reading "iOS 27.2.iPhone19.4".
    static func runtimeDisplayName(_ identifier: String) -> String {
        guard let components = runtimeComponents(identifier) else { return identifier }
        var name = components.os
        if !components.version.isEmpty {
            name += " " + components.version.map(String.init).joined(separator: ".")
        }
        if !components.variant.isEmpty {
            name += " (" + components.variant.joined(separator: ",") + ")"
        }
        return name
    }

    /// Zero-padded numeric sort key so iOS 9.0 sorts before iOS 26.4 lexically.
    static func runtimeSortKey(_ identifier: String) -> String {
        guard let components = runtimeComponents(identifier) else { return identifier }
        let numbers = components.version.map { String(format: "%04d", $0) }.joined(separator: ".")
        let variant = components.variant.isEmpty ? "" : "-" + components.variant.joined(separator: "-")
        return "\(components.os)-\(numbers)\(variant)"
    }

    /// Splits a runtime identifier's tail ("iOS-27-2-iPhone19-4") into the OS
    /// name, the leading numeric version, and any trailing variant fields.
    private struct RuntimeComponents {
        let os: String
        let version: [Int]
        let variant: [String]
    }

    private static func runtimeComponents(_ identifier: String) -> RuntimeComponents? {
        guard let tail = identifier.split(separator: ".").last else { return nil }
        let parts = tail.split(separator: "-").map(String.init)
        guard let os = parts.first else { return nil }
        let rest = parts.dropFirst()
        let version = rest.prefix { Int($0) != nil }.compactMap { Int($0) }
        let variant = Array(rest.dropFirst(version.count))
        return RuntimeComponents(os: os, version: version, variant: variant)
    }

    // MARK: - Lifecycle

    /// Boot a device. Tolerates an already-booted device (simctl exits non-zero
    /// with "Unable to boot... current state: Booted", which is success for us).
    static func boot(udid: String) throws {
        do {
            _ = try runXcrun(["simctl", "boot", udid])
        } catch SimctlError.commandFailed(let message) {
            if message.localizedCaseInsensitiveContains("current state: Booted")
                || message.localizedCaseInsensitiveContains("already booted") {
                return
            }
            throw SimctlError.commandFailed(message)
        }
    }

    /// Block until the device's boot completes and system services are ready.
    static func bootStatus(udid: String) {
        _ = try? runXcrun(["simctl", "bootstatus", udid, "-b"])
    }

    static func shutdown(udid: String) throws {
        _ = try runXcrun(["simctl", "shutdown", udid])
    }

    // MARK: - Media capture

    /// Save the simulator's native display as a PNG. `simctl io` captures the
    /// framebuffer directly, so the result is full resolution and contains no
    /// Pilot window chrome.
    static func takeScreenshot(udid: String, to url: URL) throws {
        _ = try runXcrun([
            "simctl", "io", udid, "screenshot", "--type=png", url.path,
        ])
    }

    /// Configure the long-running `simctl io … recordVideo` process. The caller
    /// owns its lifecycle and stops it with `Process.interrupt()` so simctl can
    /// finalize the movie, just as it does when receiving Control-C in Terminal.
    static func makeVideoRecordingProcess(udid: String, to url: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path,
        ]
        return process
    }
}

import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pilot

@Suite("Agent chat media and model selection")
@MainActor
struct AgentChatMediaTests {
    @Test("Images are bounded, previewed, and encoded only for image-capable agents")
    func imageImport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try await AgentChatAttachmentStore.importMedia(.image(png(), name: "Screenshot.png"), into: root)
        #expect(image.name == "Screenshot.png")
        #expect(image.thumbnail.flatMap(NSImage.init(data:)) != nil)
        #expect(image.byteCount <= AgentChatAttachmentStore.maximumImageBytes)
        let inline = try image.promptContent(supportsImages: true)
        #expect(inline["type"]?.stringValue == "image")
        #expect(Data(base64Encoded: try #require(inline["data"]?.stringValue)) == (try Data(contentsOf: image.url)))
        let linked = try image.promptContent(supportsImages: false)
        #expect(linked["type"]?.stringValue == "resource_link")
        #expect(linked["uri"]?.stringValue == image.url.absoluteString)
        #expect(linked["data"] == nil)
        await #expect(throws: (any Error).self) {
            try await AgentChatAttachmentStore.importMedia(.image(Data("invalid".utf8), name: "bad.png"), into: root)
        }
        await #expect(throws: (any Error).self) {
            try await AgentChatAttachmentStore.importMedia(.image(Data(count: 20 * 1_048_576 + 1), name: "huge.png"), into: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
    }

    @Test("Video files have a preview and remain readable after the source is removed")
    func videoImport() async throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                           kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixel = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 80, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try await waitUntil { input.isReadyForMoreMediaData }
        try #require(adaptor.append(pixel, withPresentationTime: .zero))
        try #require(adaptor.append(pixel, withPresentationTime: CMTime(value: 1, timescale: 30)))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        let video = try await AgentChatAttachmentStore.importMedia(.file(source), into: root.appendingPathComponent("saved"))
        try FileManager.default.removeItem(at: source)
        #expect(!video.isImage)
        #expect(video.thumbnail != nil)
        #expect(FileManager.default.fileExists(atPath: video.url.path))
        #expect(try video.promptContent(supportsImages: true)["type"]?.stringValue == "resource_link")
    }

    @Test("Model discovery prefers grouped configuration choices and rejects unknown IDs")
    func modelDiscovery() throws {
        let state = try #require(ACPModelState(json(#"""
        {"models":{"currentModelId":"old","availableModels":[]},"configOptions":[
          {"id":"llm","category":"model","type":"select","currentValue":"opus","options":[
            {"group":"recommended","name":"Recommended","options":[
              {"value":"opus","name":"Opus","description":"Reasoning"},
              {"value":"sonnet","name":"Sonnet"}]}]}]}
        """#)))
        #expect(state.currentName == "Opus")
        #expect(state.choices.map(\.name) == ["Opus", "Sonnet"])
        #expect(state.choices.first?.group == "Recommended")
        #expect(state.request(sessionID: "s", modelID: "invented") == nil)
        let request = try #require(state.request(sessionID: "s", modelID: "sonnet"))
        #expect(request.method == "session/set_config_option")
        #expect(request.params["configId"]?.stringValue == "llm")
        #expect(ACPAgentInfo([:]).supportsImages == false)
    }

    @Test("Model changes are confirmed by the agent and media-only messages reach its prompt", arguments: ["config", "legacy", "rejected"])
    func modelAndMediaPrompt(backend: String) async throws {
        let root = temporaryDirectory()
        let suite = "AgentChatMediaTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let initial = backend == "legacy"
            ? #"{"models":{"currentModelId":"quality","availableModels":[{"modelId":"quality","name":"Quality"},{"modelId":"fast","name":"Fast"}]}}"#
            : #"{"configOptions":[{"id":"model","type":"select","category":"model","currentValue":"quality","options":[{"value":"quality","name":"Quality"},{"value":"fast","name":"Fast"}]}]}"#
        let initialResult = initial.dropLast() + #", "sessionId":"media"}"#
        let updated = initial.replacingOccurrences(of: #""currentValue":"quality""#, with: #""currentValue":"fast""#)
        let reply = backend == "rejected" ? #""error":{"code":-32602,"message":"Unavailable"}"#
            : #""result":"# + (backend == "legacy" ? "{}" : updated)
        let method = backend == "legacy" ? "session/set_model" : "session/set_config_option"
        let launch = ACPConnection.LaunchConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
        read -r _
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true}}}}'
        read -r _
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":\(initialResult)}'
        read -r selection
        case "$selection" in *'"method":"\(method)"'*) ;; *) exit 1 ;; esac
        case "$selection" in *'"fast"'*) ;; *) exit 1 ;; esac
        printf '%s\\n' '{"jsonrpc":"2.0","id":3,\(reply)}'
        read -r prompt
        case "$prompt" in *'"type":"image"'*) answer='Image received' ;; *) answer='Missing image' ;; esac
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"media","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\\n' "$answer"
        printf '%s\\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
        read -r _
        """], environment: [:], currentDirectory: FileManager.default.temporaryDirectory)
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: NSTemporaryDirectory(), defaults: defaults,
                                       resolveLaunch: { _, _ in .success(launch) }, attachmentDirectory: root)
        defer { session.shutDown() }
        session.start()
        try await waitUntil { session.phase == .ready }
        session.draft = "Keep this draft"
        session.selectModel("fast")
        #expect(!session.canSend)
        try await waitUntil { !session.isChangingModel }
        #expect(session.modelName == (backend == "rejected" ? "Quality" : "Fast"))
        #expect((session.composerError != nil) == (backend == "rejected"))
        #expect(session.draft == "Keep this draft")
        session.draft = ""
        session.addAttachments([.image(try png(), name: "image.png")])
        #expect(!session.canSend)
        try await waitUntil { !session.isImportingAttachments }
        #expect(session.canSend)
        session.send()
        try await waitUntil { session.phase == .ready && !session.isPreparingPrompt && session.transcript.items.count == 2 }
        #expect(session.attachments.isEmpty)
        #expect(session.transcript.items.first?.attachments.count == 1)
        #expect(session.transcript.items.last?.content == .assistant("Image received"))
    }

    @Test("A native media paste creates removable chips without inserting an image into the text")
    func nativeMediaPaste() async throws {
        let root = temporaryDirectory()
        let suite = "AgentChatMediaTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let pane = Pane(kind: .agentChat)
        let session = AgentChatSession(paneID: pane.id, agent: .claude, workingDirectory: nil, defaults: defaults, attachmentDirectory: root)
        let controller = AgentChatPaneViewController(pane: pane, session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 280, height: 600))
        window.appearance = NSAppearance(named: .darkAqua)
        defer { controller.closePane(); window.close() }
        controller.updatePresentation(isActive: true, isSelected: false)
        let composer = try #require(descendants(controller.view).compactMap { $0 as? AgentChatComposerTextView }.first)
        #expect(composer.readablePasteboardTypes.contains(.png))
        #expect(composer.acceptableDragTypes.contains(.fileURL))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try png(), forType: .png)
        #expect(AgentChatMediaPasteboard.canRead(pasteboard))
        #expect(composer.readSelection(from: pasteboard, type: .png))
        try await waitUntil { !session.isImportingAttachments && !session.attachments.isEmpty }
        try await Task.sleep(for: .milliseconds(40))
        controller.view.layoutSubtreeIfNeeded()
        #expect(composer.string.isEmpty)
        let remove = try #require(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Remove image.png" })
        #expect(remove.frame.width > 0)
        if let destination = ProcessInfo.processInfo.environment["MADE_TOOL_REVIEW_OUTPUT"] {
            let output = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("agent-media-chip.png"))
        }
        remove.performClick(nil)
        #expect(session.attachments.isEmpty)
        let source = root.appendingPathComponent("picked.png")
        try png().write(to: source)
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSURL])
        #expect(AgentChatMediaPasteboard.canRead(pasteboard))
        let card = try #require(descendants(controller.view).compactMap { $0 as? AgentChatComposerCard }.first)
        #expect(card.onPasteMedia?(pasteboard) == true, "File drops use the same importer as clipboard images")
        try await waitUntil { !session.isImportingAttachments && session.attachments.count == 1 }
        #expect(session.attachments.first?.name == "picked.png")
        session.addAttachments(Array(repeating: .file(source), count: 9))
        #expect(session.attachments.count == 1)
        #expect(session.composerError == AgentChatAttachmentError.tooMany.localizedDescription)
        pasteboard.clearContents()
        pasteboard.setString("Ordinary pasted text", forType: .string)
        #expect(!AgentChatMediaPasteboard.canRead(pasteboard))
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AgentChatMedia-\(UUID())") }
    private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }
}

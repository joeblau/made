import AVFoundation
import Foundation
import XCTest
@testable import Pilot

final class AirPlayVideoRendererTests: XCTestCase {
    // Two synthetic solid-color H.264 frames (32x48 red, 48x32 blue), encoded
    // with x264 ultrafast/zerolatency. No device recordings or external tools
    // are needed at test time.
    @MainActor func testDecoderWaitsForKeyframeAndRecoversAfterRotationAndReset() async throws {
        let renderer = AirPlayVideoRenderer()
        try await Task.detached {
            func annexB(_ strings: String...) -> Data {
                strings.reduce(into: Data()) { bytes, string in
                    bytes.append(contentsOf: [0, 0, 0, 1])
                    bytes.append(Data(base64Encoded: string)!)
                }
            }
            let portraitConfig = annexB("Z0LACtonsBEAAAMAAQAAAwA8jxImoA==", "aM4PyA==")
            let landscapeConfig = annexB("Z0LACto1sBEAAAMAAQAAAwA8jxImoA==", "aM4PyA==")
            let portraitKeyframe = annexB("ZYiEOhGKAAIY8cAAQPY4AAh5SddddeA=")
            let landscapeKeyframe = annexB("ZYiEOhGKAAIxccAAQ8o4AAgFycnXXXg=")
            let interframe = annexB("QZogJo8=")

            XCTAssertFalse(try renderer.consume(interframe))
            XCTAssertFalse(try renderer.consume(portraitConfig))
            XCTAssertFalse(try renderer.consume(interframe), "Configuration alone cannot decode reference frames")
            XCTAssertTrue(try renderer.consume(portraitKeyframe))
            XCTAssertFalse(try renderer.consume(portraitConfig))
            XCTAssertTrue(try renderer.consume(interframe), "Repeated identical configuration must not reset the GOP")
            XCTAssertFalse(try renderer.consume(landscapeConfig))
            XCTAssertFalse(try renderer.consume(interframe), "Rotation requires a fresh keyframe")
            XCTAssertTrue(try renderer.consume(landscapeKeyframe))
            renderer.reset()
            XCTAssertFalse(try renderer.consume(interframe), "A previous connection must not seed a new decoder")
        }.value
    }
}

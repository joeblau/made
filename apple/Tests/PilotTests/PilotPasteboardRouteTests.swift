import Foundation
import Testing
@testable import Pilot

@Suite("Pilot pasteboard command routing")
struct PilotPasteboardRouteTests {
    private let paneID = UUID()

    @Test("A focused text field always receives the standard edit action")
    func textFirstResponderWins() {
        for kind in PaneKind.allCases {
            #expect(
                PilotPasteboardRoute.copy(firstResponderIsText: true, selectedPaneID: paneID, selectedPaneKind: kind)
                    == .standardEditAction
            )
            #expect(
                PilotPasteboardRoute.paste(firstResponderIsText: true, selectedPaneID: paneID, selectedPaneKind: kind)
                    == .standardEditAction
            )
        }
    }

    @Test("Copy captures device and Android screenshots and is standard elsewhere")
    func copyRoutesByPaneKind() {
        for kind in PaneKind.allCases {
            let expected: PilotPasteboardRoute = switch kind {
            case .device: .deviceScreenshot(paneID: paneID)
            case .android: .androidScreenshot(paneID: paneID)
            default: .standardEditAction
            }
            #expect(
                PilotPasteboardRoute.copy(firstResponderIsText: false, selectedPaneID: paneID, selectedPaneKind: kind)
                    == expected
            )
        }
    }

    @Test("Paste types on Android, pastes into terminals, and is standard elsewhere")
    func pasteRoutesByPaneKind() {
        for kind in PaneKind.allCases {
            let expected: PilotPasteboardRoute = switch kind {
            case .android: .androidPaste(paneID: paneID)
            case .terminal: .terminalPaste(paneID: paneID)
            default: .standardEditAction
            }
            #expect(
                PilotPasteboardRoute.paste(firstResponderIsText: false, selectedPaneID: paneID, selectedPaneKind: kind)
                    == expected
            )
        }
    }

    @Test("No selected pane falls back to the standard edit action")
    func noSelectionIsStandard() {
        #expect(
            PilotPasteboardRoute.copy(firstResponderIsText: false, selectedPaneID: nil, selectedPaneKind: nil)
                == .standardEditAction
        )
        #expect(
            PilotPasteboardRoute.paste(firstResponderIsText: false, selectedPaneID: nil, selectedPaneKind: nil)
                == .standardEditAction
        )
    }
}

import AppKit
@preconcurrency import ChromiumKit
import Foundation

/// Records every callback the Chromium runtime probe asserts on. Split from
/// ChromiumRuntimeProbe.swift to keep that file within the lint budget.
@MainActor
final class ChromiumRuntimeProbeDelegate:
    NSObject,
    ChromiumBrowserHostViewDelegate {
    private(set) var lastURL: URL?
    private(set) var lastTitle: String?
    private(set) var lastFailure: NSError?
    private(set) var rendererTerminationStatus: ChromiumRendererTerminationStatus?
    private(set) var blockedNavigationURLs: [URL] = []
    private(set) var interceptedPopupURLs: [URL] = []
    private(set) var deniedPermissionRequests = 0
    private(set) var deniedGeolocationPermission = false
    private(set) var deniedFileChooserRequests = 0
    private(set) var deniedDownloadURLs: [URL] = []
    private(set) var deniedAuthenticationRequests = 0
    private(set) var deniedAuthenticationURLs: [URL] = []
    private(set) var rejectedCertificateErrors: [Int] = []
    private(set) var rejectedCertificateURLs: [URL] = []
    private(set) var historyStateChangeCount = 0
    private(set) var lastCanGoBack = false
    var allowsIntentionalRendererCrash = false

    func prepareForRendererRecovery() {
        lastURL = nil
        lastTitle = nil
        lastFailure = nil
        rendererTerminationStatus = nil
    }

    func clearExpectedNavigationFailure() {
        lastFailure = nil
    }

    @objc(chromiumBrowserHostView:decideNavigationToURL:userGesture:isRedirect:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        decideNavigationTo url: URL,
        userGesture: Bool,
        isRedirect: Bool
    ) -> ChromiumNavigationDecision {
        MainActor.assumeIsolated {
            _ = browserView
            _ = isRedirect
            if allowsIntentionalRendererCrash,
               url.absoluteString == "chrome://crash" {
                return .allow
            }
            let request = ChromiumNavigationRequest(
                url: url,
                hasTrustedUserGesture: userGesture
            )
            switch ChromiumNavigationPolicy.disposition(for: request) {
            case .allowInCurrentPane:
                return .allow
            case .requestUserConfirmedExternalOpen:
                return .openExternally
            case .openInNewPane, .block:
                blockedNavigationURLs.append(url)
                return .cancel
            }
        }
    }

    @objc(chromiumBrowserHostView:didRequestPopup:disposition:userGesture:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didRequestPopup url: URL,
        disposition: ChromiumPopupDisposition,
        userGesture: Bool
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            _ = disposition
            let request = ChromiumNavigationRequest(
                url: url,
                target: .popup,
                hasTrustedUserGesture: userGesture
            )
            _ = ChromiumNavigationPolicy.disposition(for: request)
            interceptedPopupURLs.append(url)
        }
    }

    @objc(chromiumBrowserHostView:shouldOpenExternalURL:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        shouldOpenExternalURL url: URL
    ) -> Bool {
        MainActor.assumeIsolated {
            _ = browserView
            blockedNavigationURLs.append(url)
            return false
        }
    }

    @objc(chromiumBrowserHostView:didRequestPermission:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didRequestPermission request: ChromiumPermissionRequest
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            deniedPermissionRequests += 1
            deniedGeolocationPermission =
                deniedGeolocationPermission
                || request.kinds.contains(.geolocation)
            request.deny()
        }
    }

    @objc(chromiumBrowserHostViewShouldPresentFileChooser:)
    nonisolated func chromiumBrowserHostViewShouldPresentFileChooser(
        _ browserView: ChromiumBrowserHostView
    ) -> Bool {
        MainActor.assumeIsolated {
            _ = browserView
            deniedFileChooserRequests += 1
            return false
        }
    }

    @objc(chromiumBrowserHostView:shouldDownloadURL:suggestedFilename:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        shouldDownloadURL url: URL,
        suggestedFilename: String
    ) -> Bool {
        MainActor.assumeIsolated {
            _ = browserView
            _ = suggestedFilename
            deniedDownloadURLs.append(url)
            return false
        }
    }

    @objc(chromiumBrowserHostView:didRejectAuthenticationForURL:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didRejectAuthenticationFor url: URL?
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            deniedAuthenticationRequests += 1
            if let url {
                deniedAuthenticationURLs.append(url)
            }
        }
    }

    @objc(chromiumBrowserHostView:didRejectCertificateError:forURL:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didRejectCertificateError errorCode: Int,
        for url: URL?
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            rejectedCertificateErrors.append(errorCode)
            if let url {
                rejectedCertificateURLs.append(url)
            }
        }
    }

    @objc(chromiumBrowserHostView:didChangeURL:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didChange url: URL
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            lastURL = url
        }
    }

    @objc(chromiumBrowserHostView:didChangeTitle:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didChangeTitle title: String?
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            lastTitle = title
        }
    }

    @objc(chromiumBrowserHostView:didChangeCanGoBack:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didChangeCanGoBack canGoBack: Bool
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            historyStateChangeCount += 1
            lastCanGoBack = canGoBack
        }
    }

    @objc(chromiumBrowserHostView:didFailNavigationWithError:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        didFailNavigationWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            let navigationError = error as NSError
            let failingURL = navigationError.userInfo[
                NSURLErrorFailingURLErrorKey
            ] as? URL
            // The probe deliberately rejects every navigation recorded in
            // these lists. The cancel error can arrive after the step that
            // triggered it (ChromiumRequestPolicy.mm's GetAuthCredentials
            // dispatches the rejection from the CEF IO thread), so match on
            // the failing URL rather than on the error code or arrival timing.
            let expectedCancellation = failingURL.map {
                blockedNavigationURLs.contains($0)
                    || deniedDownloadURLs.contains($0)
                    || deniedAuthenticationURLs.contains($0)
                    || rejectedCertificateURLs.contains($0)
            } == true
            let intentionalCrashAbort = allowsIntentionalRendererCrash
                && failingURL?.absoluteString == "chrome://crash"
            if !expectedCancellation && !intentionalCrashAbort {
                lastFailure = navigationError
            }
        }
    }

    @objc(chromiumBrowserHostView:rendererTerminatedWithStatus:)
    nonisolated func chromiumBrowserHostView(
        _ browserView: ChromiumBrowserHostView,
        rendererTerminatedWith status: ChromiumRendererTerminationStatus
    ) {
        MainActor.assumeIsolated {
            _ = browserView
            rendererTerminationStatus = status
        }
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import CashSDK

/// The native macOS presenter hosts the same SwiftUI paywall as iOS, in its own window when
/// no window is open, and ends exactly once however the customer closes it.
@MainActor
final class MacPaywallPresenterTests: XCTestCase {
    private func config(presentation: String? = nil) throws -> PaywallConfig {
        let extra = presentation.map { #","presentation":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(
            PaywallConfig.self,
            from: Data(#"{"products":[],"root":{"type":"stack","children":[]}\#(extra)}"#.utf8)
        )
    }

    func testPresentsInAWindowAndFinishesOnceWhenClosed() throws {
        _ = NSApplication.shared
        var outcomes: [PaywallDismissOutcome] = []
        PaywallPresenter.shared.present(
            config: try config(),
            productsByRole: [:],
            introEligibleProductIds: [],
            placement: "mac_test",
            variant: nil,
            onFinish: { outcomes.append($0) }
        )
        let window = NSApp.windows.first { $0.delegate === PaywallPresenter.shared }
        XCTAssertNotNil(window, "the paywall opens in its own window when no window is open")
        XCTAssertTrue(window?.contentViewController is NSHostingController<PaywallView>, "hosting the SwiftUI paywall")

        // A second paywall while one is up never strands its caller.
        var second: PaywallDismissOutcome?
        PaywallPresenter.shared.present(
            config: try config(),
            productsByRole: [:],
            introEligibleProductIds: [],
            placement: "mac_test_2",
            variant: nil,
            onFinish: { second = $0 }
        )
        XCTAssertEqual(second, .cancelled)

        window?.close()
        XCTAssertEqual(outcomes, [.cancelled], "closing the window ends the paywall once, as cancelled")
        window?.close()
        XCTAssertEqual(outcomes.count, 1, "and only once")
    }

}
#endif

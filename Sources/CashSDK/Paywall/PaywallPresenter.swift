import SwiftUI
import StoreKit

#if canImport(UIKit)
import UIKit

/// Presents a resolved paywall over the app's key window. `@MainActor` because it
/// touches UIKit and SwiftUI hosting. One paywall at a time.
@MainActor
final class PaywallPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = PaywallPresenter()

    private weak var presented: UIViewController?
    private var context: PresentationContext?
    /// Called once when the paywall closes, with how it ended. Drives feature gating.
    private var onFinish: (@MainActor (PaywallDismissOutcome) -> Void)?
    private var outcome: PaywallDismissOutcome = .cancelled

    private struct PresentationContext {
        let placement: String
        let variant: String?
    }

    private override init() { super.init() }

    /// Build and present the paywall. Emits `paywall_open`; the close path emits
    /// `paywall_close`. `onFinish` fires exactly once with the dismissal outcome.
    func present(
        config: PaywallConfig,
        productsByRole: [String: Product],
        placement: String,
        variant: String?,
        onFinish: (@MainActor (PaywallDismissOutcome) -> Void)? = nil
    ) {
        guard presented == nil else {
            onFinish?(.cancelled) // another paywall is already up — never strand the caller
            return
        }
        guard let host = Self.topViewController() else {
            onFinish?(.error)
            return
        }

        context = PresentationContext(placement: placement, variant: variant)
        self.onFinish = onFinish
        outcome = .cancelled

        let actions = PaywallActions(
            purchase: { [weak self] productId in
                let result = try await CashSDK.shared.purchase(productId)
                if case .success = result { self?.outcome = .purchased }
                return result
            },
            restore: { [weak self] in
                try await CashSDK.shared.restore()
                let restored = CashSDK.shared.entitlements.hasAny
                if restored { self?.outcome = .restored }
                return restored
            },
            event: { name, product in
                CashSDK.shared.recordEvent(name, placement: placement, variant: variant, product: product)
            },
            dismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let controller = UIHostingController(
            rootView: PaywallView(config: config, productsByRole: productsByRole, actions: actions)
        )
        controller.modalPresentationStyle = config.prefersSheet ? .pageSheet : .fullScreen
        controller.presentationController?.delegate = self
        presented = controller

        host.present(controller, animated: true)
        controller.presentationController?.delegate = self
        CashSDK.shared.recordEvent("paywall_open", placement: placement, variant: variant)
    }

    private func dismiss() {
        guard let presented else { return }
        presented.dismiss(animated: true) { [weak self] in self?.finishDismissal() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishDismissal()
    }

    private func finishDismissal() {
        presented = nil
        if let context {
            CashSDK.shared.recordEvent("paywall_close", placement: context.placement, variant: context.variant)
        }
        context = nil
        let finish = onFinish
        onFinish = nil
        finish?(outcome)
    }

    /// Walk from the key window's root to the top-most presented controller.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first

        var top = window?.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        return top
    }
}
#else

/// Non-UIKit platforms (e.g. app extensions without UIKit) get a no-op presenter so the
/// package still compiles. Paywall presentation is a UIKit concern.
@MainActor
final class PaywallPresenter {
    static let shared = PaywallPresenter()
    private init() {}
    func present(
        config: PaywallConfig,
        productsByRole: [String: Product],
        placement: String,
        variant: String?,
        onFinish: (@MainActor (PaywallDismissOutcome) -> Void)? = nil
    ) {
        // No UIKit → nothing can be presented; treat as a skip so a gated feature
        // still resolves deterministically instead of hanging.
        onFinish?(.error)
    }
}
#endif

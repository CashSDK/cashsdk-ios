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
        introEligibleProductIds: Set<String>,
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
                // Detailed, so purchases kept by another account come back as a result the
                // paywall can explain rather than as an error.
                let result = try await CashSDK.shared.restoreDetailed()
                if result.entitlements.hasAny { self?.outcome = .restored }
                return result
            },
            event: { name, product in
                CashSDK.shared.recordEvent(name, placement: placement, variant: variant, product: product)
            },
            dismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let controller = UIHostingController(
            rootView: PaywallView(
                config: config,
                productsByRole: productsByRole,
                introEligibleProductIds: introEligibleProductIds,
                actions: actions
            )
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
#elseif canImport(AppKit)
import AppKit

/// Presents a resolved paywall in a native macOS app (AppKit or SwiftUI lifecycle). The same
/// SwiftUI `PaywallView` as on iOS, hosted in an `NSHostingController`: as a sheet on the key
/// window when the paywall prefers a sheet and a window is open, otherwise in its own window.
/// Mac Catalyst builds have UIKit and use the presenter above. One paywall at a time.
@MainActor
final class PaywallPresenter: NSObject, NSWindowDelegate {
    static let shared = PaywallPresenter()

    private var window: NSWindow?
    /// The window the paywall is a sheet on, when it is one.
    private weak var parent: NSWindow?
    private var context: PresentationContext?
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
        introEligibleProductIds: Set<String>,
        placement: String,
        variant: String?,
        onFinish: (@MainActor (PaywallDismissOutcome) -> Void)? = nil
    ) {
        guard window == nil else {
            onFinish?(.cancelled) // another paywall is already up: never strand the caller
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
                let result = try await CashSDK.shared.restoreDetailed()
                if result.entitlements.hasAny { self?.outcome = .restored }
                return result
            },
            event: { name, product in
                CashSDK.shared.recordEvent(name, placement: placement, variant: variant, product: product)
            },
            dismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let controller = NSHostingController(
            rootView: PaywallView(
                config: config,
                productsByRole: productsByRole,
                introEligibleProductIds: introEligibleProductIds,
                actions: actions
            )
        )
        let paywall = NSWindow(contentViewController: controller)
        paywall.title = config.prefersSheet ? "" : (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "")
        paywall.styleMask = [.titled, .closable, .fullSizeContentView]
        paywall.titlebarAppearsTransparent = true
        paywall.isReleasedWhenClosed = false
        paywall.setContentSize(NSSize(width: 480, height: 680))
        paywall.delegate = self
        window = paywall

        let host = NSApp.keyWindow ?? NSApp.mainWindow
        if config.prefersSheet, let host, host.attachedSheet == nil {
            parent = host
            host.beginSheet(paywall) { [weak self] _ in self?.finishDismissal() }
        } else {
            paywall.center()
            NSApp.activate(ignoringOtherApps: true)
            paywall.makeKeyAndOrderFront(nil)
        }
        CashSDK.shared.recordEvent("paywall_open", placement: placement, variant: variant)
    }

    private func dismiss() {
        guard let window else { return }
        if let parent {
            parent.endSheet(window) // the sheet's completion handler finishes the dismissal
        } else {
            window.close() // `windowWillClose` finishes the dismissal
        }
    }

    func windowWillClose(_ notification: Notification) {
        // A sheet ends through its completion handler; a standalone window through here,
        // including when the customer closes it from the title bar.
        guard parent == nil else { return }
        finishDismissal()
    }

    private func finishDismissal() {
        guard window != nil else { return }
        window = nil
        parent = nil
        if let context {
            CashSDK.shared.recordEvent("paywall_close", placement: context.placement, variant: context.variant)
        }
        context = nil
        let finish = onFinish
        onFinish = nil
        finish?(outcome)
    }
}
#else

/// Platforms with neither UIKit nor AppKit (e.g. watchOS-style extensions) get a no-op
/// presenter so the package still compiles.
@MainActor
final class PaywallPresenter {
    static let shared = PaywallPresenter()
    private init() {}
    func present(
        config: PaywallConfig,
        productsByRole: [String: Product],
        introEligibleProductIds: Set<String>,
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

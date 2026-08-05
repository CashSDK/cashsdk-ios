import SwiftUI
import StoreKit

/// The closures a presented paywall calls back into. Supplied by ``PaywallPresenter``.
struct PaywallActions {
    /// Purchase a product id and report the outcome.
    let purchase: (String) async -> PurchaseResult
    /// Restore purchases.
    let restore: () async -> Void
    /// Emit a lifecycle event `(name, productId)`.
    let event: (String, String?) -> Void
    /// Dismiss the paywall.
    let dismiss: () -> Void
}

/// A pure-SwiftUI renderer for the `schema_version: 2` paywall component tree.
///
/// It walks the config's `root` component, resolves product roles to live StoreKit
/// `Product`s for real localized prices, and routes the CTA / restore / dismiss actions
/// back through ``PaywallActions``. Unknown component types and missing fields render as
/// nothing, so a forward-compatible config never crashes an older SDK.
struct PaywallView: View {
    let config: PaywallConfig
    let productsByRole: [String: Product]
    let actions: PaywallActions

    @State private var selectedRole: String
    @State private var isPurchasing = false

    init(config: PaywallConfig, productsByRole: [String: Product], actions: PaywallActions) {
        self.config = config
        self.productsByRole = productsByRole
        self.actions = actions
        _selectedRole = State(initialValue: Self.defaultRole(for: config))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundColor.ignoresSafeArea()
            ScrollView {
                render(config.root)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
            closeButton
                .padding(16)
        }
        .tint(accentColor)
        .preferredColorScheme(forcedColorScheme)
        .onAppear { actions.event("product_view", selectedProductId) }
    }

    // MARK: - Recursive renderer

    private func render(_ component: PaywallComponent?) -> AnyView {
        guard let component else { return AnyView(EmptyView()) }
        switch component {
        case .stack(let stack):
            return renderStack(stack)
        case .text(let text):
            return AnyView(renderText(text))
        case .image(let image):
            return AnyView(PaywallImageView(image: image, cornerRadius: cornerRadius))
        case .featureList(let list):
            return AnyView(renderFeatureList(list))
        case .productSelector(let selector):
            return renderProductSelector(selector)
        case .timer(let timer):
            return AnyView(CountdownView(seconds: Int(timer.endsInSec ?? 0), accent: accentColor))
        case .carousel(let carousel):
            return AnyView(CarouselView(carousel: carousel, accent: accentColor, textColor: textColor))
        case .comparisonTable(let table):
            return AnyView(ComparisonTableView(table: table, accent: accentColor, textColor: textColor))
        case .badge(let badge):
            return AnyView(BadgeView(badge: badge, accent: accentColor))
        case .button(let button):
            return renderButton(button)
        case .divider:
            return AnyView(Divider().padding(.horizontal, 24))
        case .spacer(let spacer):
            return AnyView(Spacer(minLength: 0).frame(height: CGFloat(spacer.size ?? 12)))
        case .unknown:
            return AnyView(EmptyView())
        }
    }

    private func renderStack(_ stack: PaywallStack) -> AnyView {
        let children = Array((stack.children ?? []).enumerated())
        let spacing = stack.spacing.map { CGFloat($0) }
        let padding = CGFloat(stack.padding ?? 0)

        if stack.axis == "horizontal" {
            return AnyView(
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(children, id: \.offset) { item in render(item.element) }
                }
                .padding(padding)
            )
        }
        return AnyView(
            VStack(alignment: verticalAlignment(stack.align), spacing: spacing) {
                ForEach(children, id: \.offset) { item in render(item.element) }
            }
            .frame(maxWidth: .infinity)
            .padding(padding)
        )
    }

    private func renderText(_ text: PaywallText) -> some View {
        Text(text.text ?? "")
            .font(.system(size: CGFloat(text.style?.size ?? defaultSize(forRole: text.role))))
            .fontWeight(fontWeight(for: text))
            .foregroundStyle(textStyleColor(for: text))
            .multilineTextAlignment(textAlignment(for: text))
            .frame(maxWidth: .infinity, alignment: frameAlignment(for: text))
            .padding(.horizontal, 24)
    }

    private func renderFeatureList(_ list: PaywallFeatureList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((list.items ?? []).enumerated()), id: \.offset) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: symbolName(item.element.icon))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(item.element.text ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(textColor)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func renderProductSelector(_ selector: PaywallProductSelector) -> AnyView {
        let roles = selectorRoles(selector)
        if selector.layout == "horizontal" {
            return AnyView(
                HStack(spacing: 12) {
                    ForEach(roles, id: \.self) { role in productCard(role: role) }
                }
                .padding(.horizontal, 24)
            )
        }
        return AnyView(
            VStack(spacing: 12) {
                ForEach(roles, id: \.self) { role in productCard(role: role) }
            }
            .padding(.horizontal, 24)
        )
    }

    private func productCard(role: String) -> some View {
        let ref = config.products?.first { $0.role == role }
        let product = productsByRole[role]
        let isSelected = role == selectedRole

        return Button {
            selectedRole = role
            actions.event("product_view", product?.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product?.displayName ?? ref?.productId ?? role)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(textColor)
                    if let badge = ref?.badge {
                        Text(badge)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accentColor)
                    }
                }
                Spacer(minLength: 0)
                Text(product?.displayPrice ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(textColor)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected ? accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func renderButton(_ button: PaywallButton) -> AnyView {
        let role = button.role ?? "secondary"
        let action = button.action ?? defaultAction(forRole: role)
        let title = button.text ?? defaultTitle(forRole: role)

        switch role {
        case "cta":
            return AnyView(ctaButton(title: title, action: action))
        case "restore":
            return AnyView(
                Button(title) { perform(action) }
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            )
        default:
            return AnyView(
                Button(title) { perform(action) }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accentColor)
            )
        }
    }

    private func ctaButton(title: String, action: String) -> some View {
        Button {
            perform(action)
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(accentColor))
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var closeButton: some View {
        Button {
            actions.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func perform(_ action: String) {
        switch action {
        case "restore":
            Task { await actions.restore() }
        case "dismiss":
            actions.dismiss()
        default: // "purchase_selected"
            purchaseSelected()
        }
    }

    private func purchaseSelected() {
        guard let productId = selectedProductId else { return }
        Task {
            isPurchasing = true
            actions.event("purchase_start", productId)
            let result = await actions.purchase(productId)
            isPurchasing = false
            if case .success = result { actions.dismiss() }
        }
    }

    private var selectedProductId: String? {
        config.products?.first { $0.role == selectedRole }?.productId
            ?? productsByRole[selectedRole]?.id
    }

    // MARK: - Selection

    private func selectorRoles(_ selector: PaywallProductSelector) -> [String] {
        if let subset = selector.products, !subset.isEmpty { return subset }
        return (config.products ?? []).map { $0.role }
    }

    private static func defaultRole(for config: PaywallConfig) -> String {
        if let primary = config.products?.first(where: { $0.role == "primary" }) { return primary.role }
        return config.products?.first?.role ?? "primary"
    }

    // MARK: - Theme

    private var accentColor: Color { color(config.theme?.accent, fallback: .accentColor) }
    private var textColor: Color { color(config.theme?.text, fallback: .primary) }
    private var cornerRadius: CGFloat { CGFloat(config.theme?.cornerRadius ?? 16) }

    private var backgroundColor: Color {
        if let rgb = PaywallColor.rgb(from: config.theme?.background) {
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color.white
        #endif
    }

    private var forcedColorScheme: ColorScheme? {
        switch config.theme?.darkMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private func color(_ hex: String?, fallback: Color) -> Color {
        guard let rgb = PaywallColor.rgb(from: hex) else { return fallback }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    // MARK: - Text styling

    private func defaultSize(forRole role: String?) -> Double {
        switch role {
        case "title": return 28
        case "subtitle": return 17
        case "legal": return 12
        default: return 17
        }
    }

    private func fontWeight(for text: PaywallText) -> Font.Weight {
        switch text.style?.weight {
        case "bold": return .bold
        case "medium": return .medium
        case "regular": return .regular
        default: return text.role == "title" ? .bold : .regular
        }
    }

    private func textStyleColor(for text: PaywallText) -> Color {
        if let rgb = PaywallColor.rgb(from: text.style?.color) {
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        switch text.role {
        case "subtitle", "legal": return .secondary
        default: return textColor
        }
    }

    private func textAlignment(for text: PaywallText) -> TextAlignment {
        text.style?.align == "left" ? .leading : .center
    }

    private func frameAlignment(for text: PaywallText) -> Alignment {
        text.style?.align == "left" ? .leading : .center
    }

    private func verticalAlignment(_ align: String?) -> HorizontalAlignment {
        switch align {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func symbolName(_ icon: String?) -> String {
        switch icon {
        case "star": return "star.fill"
        case "bolt": return "bolt.fill"
        case "heart": return "heart.fill"
        default: return "checkmark.circle.fill"
        }
    }

    // MARK: - Button defaults

    private func defaultAction(forRole role: String) -> String {
        switch role {
        case "cta": return "purchase_selected"
        case "restore": return "restore"
        default: return "dismiss"
        }
    }

    private func defaultTitle(forRole role: String) -> String {
        switch role {
        case "cta": return "Continue"
        case "restore": return "Restore purchases"
        default: return "Not now"
        }
    }
}

import Foundation

func initialPaywallRole(config: PaywallConfig, availableRoles: Set<String>) -> String {
    func firstSelector(_ component: PaywallComponent?) -> PaywallProductSelector? {
        switch component {
        case .productSelector(let selector): return selector
        case .stack(let stack): return stack.children?.compactMap { firstSelector($0) }.first
        default: return nil
        }
    }
    let selector = firstSelector(config.root)
    let roles = selector?.products?.isEmpty == false
        ? selector!.products! : (config.products ?? []).map(\.role)
    let available = roles.filter { availableRoles.contains($0) }
    if let preferred = selector?.defaultRole, available.contains(preferred) { return preferred }
    if available.contains("primary") { return "primary" }
    return available.first ?? ""
}

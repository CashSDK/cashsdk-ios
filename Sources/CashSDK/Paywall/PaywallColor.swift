import Foundation

// MARK: - Color parsing

/// Parses `#RRGGBB` / `RRGGBB` / `#RGB` hex strings into RGB components (0…1).
enum PaywallColor {
    static func rgb(from hex: String?) -> (Double, Double, Double)? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        return (
            Double((int >> 16) & 0xFF) / 255.0,
            Double((int >> 8) & 0xFF) / 255.0,
            Double(int & 0xFF) / 255.0
        )
    }
}

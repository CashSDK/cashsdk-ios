import SwiftUI

// MARK: - Leaf subviews
//
// The `schema_version: 2` component tree's leaf renderers. Extracted from `PaywallView.swift`;
// `internal` (not `private`) so the recursive renderer in that file can reference them.

struct PaywallImageView: View {
    let image: PaywallImage
    let cornerRadius: CGFloat

    var body: some View {
        content
            .aspectRatio(image.aspect.map { CGFloat($0) } ?? 1.4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(image.cornerRadius ?? Double(cornerRadius))))
            .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var content: some View {
        if let urlString = image.url, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let loaded): loaded.resizable().scaledToFill()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        // asset_id resolution is a server/bundled-asset concern; the scaffold shows art.
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color.secondary.opacity(0.25), Color.secondary.opacity(0.08)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }
}

struct CountdownView: View {
    let seconds: Int
    let accent: Color
    @State private var remaining: Int
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(seconds: Int, accent: Color) {
        self.seconds = seconds
        self.accent = accent
        _remaining = State(initialValue: max(0, seconds))
    }

    var body: some View {
        Text(formatted)
            .font(.system(size: 34, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(accent)
            .onReceive(timer) { _ in if remaining > 0 { remaining -= 1 } }
    }

    private var formatted: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}

struct CarouselView: View {
    let carousel: PaywallCarousel
    let accent: Color
    let textColor: Color

    var body: some View {
        TabView {
            ForEach(Array((carousel.slides ?? []).enumerated()), id: \.offset) { item in
                VStack(spacing: 10) {
                    if let rating = item.element.rating {
                        HStack(spacing: 2) {
                            ForEach(Array(0..<max(0, min(rating, 5))), id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                    Text(item.element.quote ?? "")
                        .font(.system(size: 17))
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.center)
                    if let author = item.element.author {
                        Text("— \(author)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
            }
        }
        // PageTabViewStyle (swipeable carousel) is iOS-only; on the macOS build target the
        // TabView falls back to its default style. UIKit-free so the package still compiles.
        #if os(iOS)
        .tabViewStyle(PageTabViewStyle())
        #endif
        .frame(height: 170)
    }
}

struct ComparisonTableView: View {
    let table: PaywallComparisonTable
    let accent: Color
    let textColor: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer().frame(maxWidth: .infinity)
                ForEach(Array((table.columns ?? []).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(textColor)
                        .frame(width: 64)
                }
            }
            ForEach(Array((table.rows ?? []).enumerated()), id: \.offset) { row in
                VStack(spacing: 10) {
                    HStack {
                        Text(row.element.label ?? "")
                            .font(.system(size: 15))
                            .foregroundStyle(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array((row.element.values ?? []).enumerated()), id: \.offset) { value in
                            Image(systemName: value.element ? "checkmark" : "minus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(value.element ? accent : Color.secondary)
                                .frame(width: 64)
                        }
                    }
                    Divider()
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

struct BadgeView: View {
    let badge: PaywallBadge
    let accent: Color

    var body: some View {
        Text(badge.text ?? "")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.15)))
    }
}

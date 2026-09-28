import StoreKit

/// The paywall's line for a subscription's introductory offer, e.g. "Free for 1 week, then
/// $9.99 / month". The paywall shows it only when StoreKit says the Apple ID is eligible, so a
/// returning subscriber is never promised a trial the App Store will not give.
enum IntroOfferText {
    enum Mode { case freeTrial, payAsYouGo, payUpFront }
    enum Unit { case day, week, month, year }

    /// Nil when the product has no introductory offer, or one this SDK cannot describe.
    static func describe(_ product: Product) -> String? {
        guard let subscription = product.subscription,
              let offer = subscription.introductoryOffer,
              let offerMode = Self.mode(offer.paymentMode),
              let offerUnit = Self.unit(offer.period.unit),
              let regularUnit = Self.unit(subscription.subscriptionPeriod.unit) else { return nil }
        return text(
            mode: offerMode,
            offerPrice: offer.displayPrice,
            periodValue: offer.period.value,
            periodUnit: offerUnit,
            periodCount: offer.periodCount,
            regularPrice: product.displayPrice,
            regularPeriodValue: subscription.subscriptionPeriod.value,
            regularPeriodUnit: regularUnit
        )
    }

    /// `periodValue`/`periodUnit` is one offer period and `periodCount` how many of them the
    /// offer lasts, as StoreKit reports them.
    static func text(
        mode: Mode,
        offerPrice: String,
        periodValue: Int,
        periodUnit: Unit,
        periodCount: Int,
        regularPrice: String,
        regularPeriodValue: Int,
        regularPeriodUnit: Unit
    ) -> String {
        let length = duration(periodValue * max(periodCount, 1), periodUnit)
        let then = "then \(regularPrice) / \(every(regularPeriodValue, regularPeriodUnit))"
        switch mode {
        case .freeTrial:
            return "Free for \(length), \(then)"
        case .payUpFront:
            return "\(offerPrice) for \(length), \(then)"
        case .payAsYouGo:
            return "\(offerPrice) / \(every(periodValue, periodUnit)) for \(length), \(then)"
        }
    }

    /// "1 week", "3 days".
    static func duration(_ value: Int, _ unit: Unit) -> String {
        "\(value) \(name(unit))\(value == 1 ? "" : "s")"
    }

    /// "month" for one, "3 months" otherwise, as in "$9.99 / month".
    static func every(_ value: Int, _ unit: Unit) -> String {
        value == 1 ? name(unit) : duration(value, unit)
    }

    private static func name(_ unit: Unit) -> String {
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        }
    }

    private static func mode(_ mode: Product.SubscriptionOffer.PaymentMode) -> Mode? {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default: return nil
        }
    }

    private static func unit(_ unit: Product.SubscriptionPeriod.Unit) -> Unit? {
        switch unit {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        @unknown default: return nil
        }
    }
}

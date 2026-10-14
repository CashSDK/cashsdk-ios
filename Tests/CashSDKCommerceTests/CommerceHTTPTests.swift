import Foundation
import XCTest
import CashSDKCommerce

/// Invoked by the API's extension suite against its isolated running services and Stripe fixture.
final class CommerceHTTPTests: XCTestCase {
    func testNativeClientAgainstRunningServices() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CASHSDK_TEST_API"], let key = env["CASHSDK_TEST_KEY"],
              let backend = env["CASHSDK_TEST_BACKEND"], let origin = env["CASHSDK_TEST_ORIGIN"],
              let checkoutId = env["CASHSDK_TEST_CHECKOUT"] else {
            throw XCTSkip("Run test:web-sdk:extension to start the isolated HTTP fixture")
        }
        let client = try CashSDKCommerceClient(publishableKey: key, environment: .sandbox, customerId: "extension-alice",
            origin: origin, apiURL: URL(string: base)!, getSessionToken: {
                var request = URLRequest(url: URL(string: backend)!)
                request.httpMethod = "POST"
                request.setValue("Bearer merchant-session-fixture", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw CommerceError(code: "test_session_failed", message: "Test backend refused session") }
                return try JSONDecoder().decode(CommerceSessionToken.self, from: data)
            })
        let customer = try await client.getCustomer()
        XCTAssertEqual(customer.customerId, "extension-alice")
        let offerings = try await client.getOfferings()
        XCTAssertFalse(offerings.current?.packages.isEmpty ?? true)
        let entitlements = try await client.getEntitlements()
        XCTAssertTrue(entitlements.isActive("pro"))
        let subscriptions = try await client.getSubscriptions()
        XCTAssertTrue(subscriptions.subscriptions.contains { $0.active && $0.provider == "stripe" })
        let checkout = try await client.getCheckout(checkoutId)
        XCTAssertEqual(checkout.status, .complete)
        let portal = try await client.openBillingPortal(returnURL: URL(string: origin + "/return")!)
        XCTAssertEqual(try portal.redirectURL().host, "billing.stripe.com")
        try await client.logout()
        let active = await client.isActive("pro")
        XCTAssertFalse(active)
    }
}

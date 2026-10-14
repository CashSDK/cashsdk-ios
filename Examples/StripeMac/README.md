# Native macOS with Stripe

Run `swift run --package-path Examples/StripeMac` from the SDK directory. Requires
macOS 14+. This example uses the local `CashSDKCommerce` product, which is not yet in
a published SDK tag.

Create a CashSDK app with the `macos-direct` platform. Connect your own Stripe account,
import recurring prices, map entitlements and add products to an offering. Enable
customer sessions and allow the exact hosted return origin. Start with sandbox.

The backend endpoint must authenticate your signed-in merchant session token and return
`CashSDKServer.createWebSession` with the actual customer's ID, the fixed return origin,
and scopes `customer:read`, `entitlements:read`, `subscriptions:read`, `offerings:read`,
`checkout:create`, `checkout:read`, `billing:manage`. The app derives its customer ID from
this backend response. No server key belongs in the app. The session token provider
calls this endpoint again when a CashSDK token needs renewal.

Enter the configuration in the window. It reads offerings and `pro` access, opens Stripe
Checkout and the customer portal in your browser, and refreshes when the app becomes
active. Checkout attempts survive relaunch in UserDefaults, scoped to customer, API,
app key and environment. A completed checkout does not grant access on its own.
The merchant sign-in token is held only in memory.

SDK-created checkout still requires sandbox preview flags on CashSDK's services. Do not
interpret a working example or mocked tests as real Stripe acceptance. Configure the
Stripe customer portal before using Manage billing. Your backend should revoke all
customer sessions when your app signs out. For a sandboxed app target, enable outgoing
network connections. This executable is a development example, not a signed/notarized
app bundle.

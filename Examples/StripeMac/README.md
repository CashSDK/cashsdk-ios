# Native macOS with Stripe

Run `swift run --package-path Examples/StripeMac` from the SDK directory. Requires
macOS 12+. This example builds against the `CashSDKCommerce` product in this checkout.
Your own app adds the published Swift package, version 2.6.0 or later.

Create a CashSDK app with the `macos-direct` platform. Connect your own Stripe account,
import your prices, map entitlements and add products to an offering. Enable
customer sessions and allow the exact hosted return origin. Start with sandbox.

The backend endpoint must authenticate your signed-in merchant session token and return
`CashSDKServer.createWebSession` with the actual customer's ID, the fixed return origin,
and scopes `customer:read`, `entitlements:read`, `subscriptions:read`, `offerings:read`,
`checkout:create`, `checkout:read`, `billing:manage`. Return the whole response: its
`expiresInSeconds` is counted on the Mac's own clock, so a Mac whose clock is wrong still
works. The app derives its customer ID from this backend response. No server key belongs
in the app. The session token provider calls this endpoint again when a CashSDK token
needs renewal.

Enter the configuration in the window. It reads offerings and `pro` access, opens Stripe
Checkout and the customer portal in your browser (Stripe's host or your Stripe custom
domain). Buying goes through `purchase`, which keeps one idempotency key and checkout id
per customer and package in UserDefaults: a relaunch or a second click resumes the same
checkout. Each package has its own attempt, and one that is over (paid, expired, refused,
or a plan the customer already has) is forgotten, so the next purchase starts a new one.
When the app becomes active again after a checkout was opened, it follows the payment
and then the `pro` access for up to 30 seconds each; otherwise it refreshes access. A
completed checkout does not grant access on its own. The merchant sign-in token is held
only in memory.

Sign out clears local access at once and ends the CashSDK session in the background.
Your backend should revoke all customer sessions when your app signs out.

A working example is not a live purchase: follow
https://docs.cashsdk.com/sdk/go-live before you take real payments. Configure the
Stripe customer portal before using Manage billing. For a sandboxed app target, enable
outgoing network connections. This executable is a development example, not a
signed/notarized app bundle.

# Native account sign-in (0.3)

Google and Discord authenticate in ASWebAuthenticationSession on iOS and Custom
Tabs on Android. Provider redirects remain the existing production HTTPS Better
Auth callbacks; no provider-console redirect changes are required.

`ArkpediaAuth.prepare/open/cancel` is restricted to the canonical production page.
The native process creates a 256-bit verifier, gives JavaScript only its SHA-256
challenge, and retains the verifier in memory. The website registers the requested
provider, mode and bounded return path with `/api/native-auth/begin`. Native code
opens only the fixed production start endpoint using the returned random state.

The server consumes the launch record and starts Better Auth OAuth. An extra random
completion ticket is kept inside Better Auth's OAuth state, and is disclosed only
by its successful callback. Merely knowing a launch state cannot transfer a browser's
existing session. Linking first installs the app's current session in the auth browser
using a server-only one-time token; linking/confirmation/deletion returns must match
the original user. Provider errors never disclose the completion ticket.

After OAuth, a short-lived handoff is indexed by state and challenge. The custom
scheme callback `net.arkpedia.mobile://auth?state=…` contains no cookie, bearer token
or verifier. Native code checks the outstanding state and redeems over canonical
HTTPS with its verifier. Redirects are disabled for redemption. The server consumes
the handoff and Better Auth token once and returns HttpOnly secure cookies, which
native code writes directly to WKHTTPCookieStore or Android CookieManager. Only the
relative return path is exposed to JavaScript. Incorrect proofs cannot consume the
real handoff. Cancellation, timeout or process death discards the native verifier.

Launch records expire in 60 seconds, provider callbacks in 10 minutes and handoffs
in 60 seconds. Initiation is rate limited; POSTs require canonical Origin and JSON.
Preview does not expose these endpoints. No data/schema migration or account-secret
change is needed. No associated domains, App Groups, widget extension or Apple team
identifier is required, so the callback remains valid with Sideloadly signing.

Device acceptance remains required: Google and Discord sign-in, cancellation, a
second attempt, expired callback, link/re-auth on the existing account, sign-out,
restart persistence, and a Sideloadly-signed iPhone. Do not treat browser mocks or
native compilation as proof of device authentication.

The iOS WebView occupies the root view's safe-area rectangle, with automatic scroll
insets disabled. Its fixed navigation and transport cannot extend into the status
bar or home indicator. An origin-checked, main-frame-only observer matches the
native background and status-bar text to Arkpedia's light/dark theme.

import AuthenticationServices
import Capacitor
import CryptoKit
import WebKit

@objc(ArkpediaAuthPlugin)
public class ArkpediaAuthPlugin: CAPPlugin, CAPBridgedPlugin, ASWebAuthenticationPresentationContextProviding, URLSessionTaskDelegate {
    public let identifier = "ArkpediaAuthPlugin"
    public let jsName = "ArkpediaAuth"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "prepare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]
    private let origin = "https://www.arkpedia.net"
    private var verifier: String?
    private var state: String?
    private var pending: CAPPluginCall?
    private var session: ASWebAuthenticationSession?
    private var timeout: DispatchWorkItem?
    private var exchange: Task<Void, Never>?

    private func allowed() -> Bool {
        guard let url = bridge?.webView?.url else { return false }
        return url.scheme == "https" && url.host == "www.arkpedia.net" && (url.port == nil || url.port == 443)
    }
    private func valid(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil }
    private func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func clear() {
        timeout?.cancel(); timeout = nil
        exchange?.cancel(); exchange = nil
        let previous = session
        session = nil; verifier = nil; state = nil; pending = nil
        previous?.cancel()
    }
    @objc func prepare(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.allowed() else { call.reject("Sign-in is available only to Arkpedia production"); return }
            guard self.pending == nil else { call.reject("Sign-in is already open"); return }
            self.clear()
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { call.reject("Could not prepare sign-in"); return }
            let verifier = self.encoded(Data(bytes)); self.verifier = verifier
            call.resolve(["challenge": self.encoded(Data(SHA256.hash(data: Data(verifier.utf8))))])
        }
    }
    @objc func open(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.allowed(), let state = call.getString("state"), self.valid(state), self.verifier != nil, self.pending == nil else { call.reject("Prepare sign-in first"); return }
            self.state = state; self.pending = call
            let session = ASWebAuthenticationSession(url: URL(string: self.origin + "/api/native-auth/start?state=" + state)!, callbackURLScheme: "net.arkpedia.mobile") { [weak self] url, _ in
                DispatchQueue.main.async {
                    guard let self, self.state == state else { return }
                    self.receive(url)
                }
            }
            self.session = session
            session.presentationContextProvider = self
            // Keep the browser's Arkpedia account separate, including when linking providers.
            session.prefersEphemeralWebBrowserSession = true
            let timeout = DispatchWorkItem { [weak self] in self?.fail("Sign-in timed out. Please try again.") }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeout)
            if !session.start() { self.fail("Could not open sign-in. Please try again.") }
        }
    }
    @objc func cancel(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.allowed() else { call.reject("Unavailable outside Arkpedia"); return }
            self.fail("Sign-in cancelled."); call.resolve()
        }
    }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        bridge!.viewController!.view.window!
    }
    private func fail(_ message: String) { let call = pending; clear(); call?.reject(message) }
    private func receive(_ url: URL?) {
        guard let url, url.scheme == "net.arkpedia.mobile", url.host == "auth", url.path.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.filter({ $0.name == "state" }).count == 1,
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let state, let verifier, let call = pending else { fail("Sign-in cancelled or callback invalid."); return }
        guard parts.queryItems?.contains(where: { $0.name == "error" }) != true else { fail("Sign-in could not finish. Use your existing login and try again."); return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let transport = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: URL(string: origin + "/api/native-auth/redeem")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["state": state, "verifier": verifier])
        exchange = Task { @MainActor in
            defer { transport.invalidateAndCancel() }
            do {
                let (data, response) = try await transport.data(for: request)
                guard !Task.isCancelled, self.state == state, self.allowed(),
                      let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let path = body["returnPath"] as? String,
                      path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
                      let webView = self.bridge?.webView else { throw URLError(.badServerResponse) }
                let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: request.url!).filter {
                    $0.name.hasPrefix("__Secure-arkpedia.") && $0.domain == "www.arkpedia.net" && $0.isSecure && $0.isHTTPOnly
                }
                guard cookies.contains(where: { $0.name == "__Secure-arkpedia.session_token" }) else { throw URLError(.badServerResponse) }
                for cookie in cookies { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                guard !Task.isCancelled, self.state == state else { return }
                self.exchange = nil; self.clear(); call.resolve(["returnPath": path])
            } catch { if self.state == state { self.fail("Sign-in could not finish. Please try again.") } }
        }
    }
    // A handoff must never send its proof to a redirected host.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

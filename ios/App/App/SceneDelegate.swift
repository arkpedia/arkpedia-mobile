import UIKit
import Capacitor
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = ArkpediaViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

// Keep browser-style history navigation available without adding page chrome.
class ArkpediaViewController: CAPBridgeViewController, WKScriptMessageHandler {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(ArkpediaAudioPlugin())
        bridge?.registerPluginInstance(ArkpediaAuthPlugin())
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let webView else { return }
        let container = UIView()
        view = container
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor)
        ])
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        applyTheme(light: false)
    }

    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.userContentController.add(self, name: "arkpediaAppearance")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
                if (location.origin !== 'https://www.arkpedia.net') return;
                const update = () => window.webkit.messageHandlers.arkpediaAppearance.postMessage(document.documentElement.dataset.theme === 'light');
                update();
                new MutationObserver(update).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return super.webView(with: frame, configuration: configuration)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == "www.arkpedia.net",
              origin.port == 0 || origin.port == 443, let light = message.body as? Bool else { return }
        applyTheme(light: light)
    }
    private func applyTheme(light: Bool) {
        let color = light ? UIColor(red: 241/255, green: 243/255, blue: 245/255, alpha: 1) : UIColor(red: 15/255, green: 21/255, blue: 27/255, alpha: 1)
        view.backgroundColor = color
        webView?.backgroundColor = color
        webView?.scrollView.backgroundColor = color
        statusBarStyle = light ? .darkContent : .lightContent
        setNeedsStatusBarAppearanceUpdate()
    }
}

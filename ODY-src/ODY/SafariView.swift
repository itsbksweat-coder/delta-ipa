import SwiftUI
import WebKit

/// Discord runs directly inside ODY as a persistent WKWebView.
/// The Discord website session is kept by WKWebsiteDataStore.default(), so it
/// belongs to this app and can survive normal app closes/reopens.
/// ODY never exports Discord cookies, passwords, localStorage, or user tokens.
struct EmbeddedDiscordWebView: UIViewRepresentable {
    private static let guildID = "1422601105149264006"
    private static let channelID = "1487787555427455067"
    private static let targetURL = URL(string: "https://discord.com/channels/\(guildID)/\(channelID)")!

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Persistent app-owned website storage. This is what keeps the Discord
        // website signed in inside ODY without copying the session anywhere else.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "odyStatus")
        controller.addUserScript(
            WKUserScript(
                source: Self.statusScannerScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        context.coordinator.webView = webView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadDiscord),
            name: .reloadDiscordPage,
            object: nil
        )

        // Go straight to the Odyssey channel. If Discord does not yet have a
        // valid session in ODY, Discord itself redirects this same in-app view
        // to its normal login/QR page. After login, ODY returns to the channel.
        webView.load(
            URLRequest(
                url: Self.targetURL,
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 60
            )
        )

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "odyStatus")
    }

    /// Reads only visible page text and extracts status lines. No browser storage APIs
    /// are accessed. Discord's own session stays private inside WKWebView.
    private static let statusScannerScript = #"""
    (() => {
      if (window.__ODY_STATUS_SCANNER__) return;
      window.__ODY_STATUS_SCANNER__ = true;

      let last = "";

      function cleanLine(s) {
        return String(s || "")
          .replace(/\u00a0/g, " ")
          .replace(/[\t ]+/g, " ")
          .trim();
      }

      function normalizeBlock(raw) {
        const source = String(raw || "")
          .split(/\r?\n/)
          .map(cleanLine)
          .filter(Boolean);

        const out = [];
        let tier = null;
        let pendingTier = null;
        let pendingName = null;

        for (let i = 0; i < source.length; i++) {
          const line = source[i];

          const head = line.match(/\b(FARMER|PRO)\b[^\n]*?(\d+)\s*\/\s*(\d+)/i);
          if (head && !/expires?\s+in/i.test(line)) {
            tier = head[1].toUpperCase();
            pendingTier = null;
            pendingName = null;
            out.push(`${tier} ${head[2]} / ${head[3]}`);
            continue;
          }

          if (/^(FARMER|PRO)$/i.test(line)) {
            pendingTier = line.toUpperCase();
            continue;
          }
          if (pendingTier) {
            const count = line.match(/(\d+)\s*\/\s*(\d+)/);
            if (count) {
              tier = pendingTier;
              out.push(`${tier} ${count[1]} / ${count[2]}`);
              pendingTier = null;
              pendingName = null;
              continue;
            }
          }

          if (!tier) continue;

          const full = line.match(/^[\s>*_`-]*@?(.+?)\s*[-–—]\s*expires?\s+in\s+(.+?)\s*$/i);
          if (full) {
            out.push(`@${cleanLine(full[1]).replace(/^@/, "")} - expires in ${cleanLine(full[2])}`);
            pendingName = null;
            continue;
          }

          const expiry = line.match(/(?:^|[-–—]\s*)expires?\s+in\s+(.+?)\s*$/i);
          if (expiry && pendingName) {
            out.push(`@${pendingName.replace(/^@/, "")} - expires in ${cleanLine(expiry[1])}`);
            pendingName = null;
            continue;
          }

          if (
            line.length <= 90 &&
            !/^(today|yesterday|edited|reply|more|add reaction)$/i.test(line) &&
            !/\b(FARMER|PRO)\b/i.test(line) &&
            !/\d+\s*\/\s*\d+/.test(line)
          ) {
            pendingName = line.replace(/^@/, "");
          }
        }

        const text = out.join("\n").trim();
        if (!/\b(FARMER|PRO)\b\s+\d+\s*\/\s*\d+/i.test(text)) return "";
        return text;
      }

      function candidateBlocks() {
        const selectors = [
          'li[id^="chat-messages-"]',
          '[id^="chat-messages-"]',
          '[data-list-item-id^="chat-messages"]',
          '[class*="messageListItem"]',
          '[role="article"]'
        ];
        const seen = new Set();
        const blocks = [];

        for (const selector of selectors) {
          for (const el of document.querySelectorAll(selector)) {
            if (!el || seen.has(el)) continue;
            seen.add(el);
            const text = String(el.innerText || "").trim();
            if (!text) continue;
            if (!/\b(FARMER|PRO)\b/i.test(text)) continue;
            if (!/expires?\s+in/i.test(text)) continue;
            blocks.push(text);
          }
        }

        if (!blocks.length && document.body) {
          const bodyText = String(document.body.innerText || "");
          if (/\b(FARMER|PRO)\b/i.test(bodyText) && /expires?\s+in/i.test(bodyText)) {
            blocks.push(bodyText);
          }
        }
        return blocks;
      }

      function scan() {
        try {
          const blocks = candidateBlocks();
          let best = "";

          for (let i = blocks.length - 1; i >= 0; i--) {
            const normalized = normalizeBlock(blocks[i]);
            if (!normalized) continue;
            if (/expires?\s+in/i.test(normalized)) {
              best = normalized;
              break;
            }
            if (!best) best = normalized;
          }

          if (!best || best === last) return;
          last = best;
          window.webkit?.messageHandlers?.odyStatus?.postMessage(best);
        } catch (_) {}
      }

      const observer = new MutationObserver(() => {
        clearTimeout(window.__ODY_STATUS_DEBOUNCE__);
        window.__ODY_STATUS_DEBOUNCE__ = setTimeout(scan, 180);
      });

      observer.observe(document.documentElement, {
        subtree: true,
        childList: true,
        characterData: true
      });

      setInterval(scan, 1000);
      scan();
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var lastStatus = ""
        private var lastLoginState: Bool?
        private var routedToTargetAfterLogin = false

        @objc func reloadDiscord() {
            webView?.reload()
        }

        private func publishLoginState(_ loggedIn: Bool) {
            guard lastLoginState != loggedIn else { return }
            lastLoginState = loggedIn
            UserDefaults.standard.set(loggedIn, forKey: "ODYDiscordLoggedIn")

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .discordLoginStateUpdated,
                    object: nil,
                    userInfo: ["loggedIn": loggedIn]
                )
            }
        }

        private func updateDiscordState(for webView: WKWebView) {
            guard let url = webView.url,
                  let host = url.host?.lowercased(),
                  host == "discord.com" || host.hasSuffix(".discord.com")
            else { return }

            let path = url.path.lowercased()

            if path.hasPrefix("/login") || path.hasPrefix("/register") {
                routedToTargetAfterLogin = false
                publishLoginState(false)
                return
            }

            if path.hasPrefix("/channels/") {
                publishLoginState(true)

                let targetPath = "/channels/\(EmbeddedDiscordWebView.guildID)/\(EmbeddedDiscordWebView.channelID)"
                if path != targetPath.lowercased(), !routedToTargetAfterLogin {
                    routedToTargetAfterLogin = true
                    webView.load(URLRequest(url: EmbeddedDiscordWebView.targetURL))
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "odyStatus",
                  let text = message.body as? String else { return }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != lastStatus else { return }

            lastStatus = cleaned
            UserDefaults.standard.set(cleaned, forKey: "ODYLatestStatusText")

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .odyStatusTextUpdated,
                    object: nil,
                    userInfo: ["text": cleaned]
                )
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            updateDiscordState(for: webView)
            webView.evaluateJavaScript(EmbeddedDiscordWebView.SelfScannerBootstrap.script, completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            updateDiscordState(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }

    private enum SelfScannerBootstrap {
        static let script = #"""
        try {
          if (typeof window.__ODY_STATUS_SCANNER__ === 'undefined') {
            location.reload();
          }
        } catch (_) {}
        """#
    }
}

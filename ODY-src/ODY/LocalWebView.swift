import SwiftUI
import WebKit

struct LocalWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.loadLocalPage()

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadLocalPage),
            name: .reloadODYPage,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.statusUpdated(_:)),
            name: .odyStatusTextUpdated,
            object: nil
        )

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var pageReady = false

        @objc func reloadLocalPage() {
            pageReady = false
            loadLocalPage()
        }

        @objc func statusUpdated(_ note: Notification) {
            let text = (note.userInfo?["text"] as? String)
                ?? UserDefaults.standard.string(forKey: "ODYLatestStatusText")
            guard let text, !text.isEmpty else { return }
            applyStatus(text)
        }

        func loadLocalPage() {
            guard
                let webView,
                let url = Bundle.main.url(forResource: "ody_local", withExtension: "html")
            else { return }

            webView.loadFileURL(
                url,
                allowingReadAccessTo: url.deletingLastPathComponent()
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            if let saved = UserDefaults.standard.string(forKey: "ODYLatestStatusText"),
               !saved.isEmpty {
                applyStatus(saved)
            }
        }

        private func applyStatus(_ text: String) {
            guard pageReady, let webView else { return }

            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let jsonArray = String(data: data, encoding: .utf8),
                  jsonArray.count >= 2 else { return }

            // JSON-encode through an array so special characters/newlines are safe.
            let js = "window.odyApplyStatus && window.odyApplyStatus((\(jsonArray))[0]);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

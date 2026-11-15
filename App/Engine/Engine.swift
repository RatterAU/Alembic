import Foundation
import JavaScriptCore
import UIKit
import WebKit

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The app's line to the Python engine (Engine/engine/api.py).
/// Every call runs on a background queue; Python's GIL serialises them.
final class Engine: @unchecked Sendable {
    static let shared = Engine()

    private let queue = DispatchQueue(label: "alembic.engine", qos: .userInitiated, attributes: .concurrent)
    private let decoder = JSONDecoder()
    /// Receives engine events on the main actor.
    @MainActor var onEvent: (([String: Any]) -> Void)?

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async(flags: .barrier) {
                if let err = alembic_python_start(Bundle.main.bundlePath, engineEventCallback, engineJSCallback) {
                    let message = String(cString: err)
                    free(err)
                    cont.resume(throwing: EngineError(message: message))
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// Calls a command and returns the raw JSON of its `result`.
    func callData(_ cmd: String, _ args: [String: Any] = [:]) async throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: ["cmd": cmd, "args": args])
        let text = String(decoding: request, as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let raw = alembic_python_call(text)
                let reply = Data(bytes: raw, count: strlen(raw))
                free(raw)
                do {
                    guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                        throw EngineError(message: "Unreadable reply from the engine")
                    }
                    if obj["ok"] as? Bool == true {
                        let result = obj["result"] ?? NSNull()
                        cont.resume(returning: try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]))
                    } else {
                        cont.resume(throwing: EngineError(message: obj["error"] as? String ?? "Something went wrong"))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: Any] = [:], as type: T.Type) async throws -> T {
        let data = try await callData(cmd, args)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func call(_ cmd: String, _ args: [String: Any] = [:]) async throws -> Any {
        let data = try await callData(cmd, args)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    fileprivate func deliver(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let box = UncheckedBox(obj)
        Task { @MainActor in self.onEvent?(box.value) }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// C callbacks handed to PythonHost.m

private let engineEventCallback: alembic_event_callback = { ptr in
    guard let ptr else { return }
    Engine.shared.deliver(String(cString: ptr))
}

private let engineJSCallback: alembic_js_callback = { code, errorOut in
    switch JSRunner.runBlocking(String(cString: code)) {
    case .success(let output):
        return strdup(output)
    case .failure(let error):
        errorOut.pointee = strdup(error.localizedDescription)
        return nil
    }
}

/// Runs yt-dlp's YouTube challenge solver (plain JavaScript that prints its
/// answer with console.log). WebKit runs it with its JIT in a separate, sandboxed
/// process. The page is locked down three ways: a Content Security Policy with
/// no sources, a content rule list that blocks every load, and a navigation
/// policy that refuses to leave the blank page. The script runs in the page's
/// own world, so the policy applies to it.
@MainActor
final class JSRunner: NSObject, WKNavigationDelegate {
    static let shared = JSRunner()
    private var webView: WKWebView?
    private var creating: Task<WKWebView?, Never>?
    private var pageLoaded = false

    private func view() async -> WKWebView? {
        if let webView { return webView }
        if let creating { return await creating.value }
        let task = Task { await makeView() }
        creating = task
        let wv = await task.value
        creating = nil
        webView = wv
        return wv
    }

    private func makeView() async -> WKWebView? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let blockAll = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        if let rules = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "alembic.block-all", encodedContentRuleList: blockAll) {
            config.userContentController.add(rules)
        } else {
            return nil // never run the solver without the network blocked
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.isHidden = true
        wv.isUserInteractionEnabled = false
        wv.navigationDelegate = self
        // Keep it in the window so iOS doesn't throttle its web process.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(wv)
        }
        pageLoaded = false
        let csp = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; form-action 'none'; base-uri 'none'"
        wv.loadHTMLString("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><title>solver</title>", baseURL: nil)
        for _ in 0..<150 where !pageLoaded {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return wv
    }

    // Only the initial blank page may load; any later navigation is refused.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(pageLoaded ? .cancel : .allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { pageLoaded = true }
    }

    // A crashed or killed web process: start a fresh one next time.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { self.discard() }
    }

    private func discard() {
        webView?.removeFromSuperview()
        webView = nil
        pageLoaded = false
    }

    func run(_ source: String) async throws -> String {
        guard let wv = await view(), pageLoaded else {
            discard()
            throw EngineError(message: "WebKit isn't available")
        }
        let body = """
        const out = [];
        const original = console.log;
        console.log = (...a) => out.push(a.map(String).join(' '));
        try { (0, eval)(src); } finally { console.log = original; }
        return out.join('\\n');
        """
        let result = try await wv.callAsyncJavaScript(body, arguments: ["src": source], contentWorld: .page)
        return result as? String ?? ""
    }

    /// Called from Python's thread; never from the main thread.
    nonisolated static func runBlocking(_ source: String) -> Result<String, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task { @MainActor in
            // In the background iOS may suspend WebKit's process; don't wait on it.
            if UIApplication.shared.applicationState != .background {
                do { box.result = .success(try await JSRunner.shared.run(source)) }
                catch { box.result = .failure(error) }
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .success, case .success = box.result {
            return box.result!
        }
        // WebKit unavailable: JavaScriptCore in-process. It has no network, file or
        // timer APIs, so the script can only compute and print.
        return runInJSC(source)
    }

    nonisolated private static func runInJSC(_ source: String) -> Result<String, Error> {
        guard let context = JSContext() else { return .failure(EngineError(message: "No JavaScript engine")) }
        var output: [String] = []
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            output.append(args.map { $0.toString() }.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.evaluateScript(source)
        if let exception = context.exception {
            return .failure(EngineError(message: "JavaScript error: \(exception)"))
        }
        return .success(output.joined(separator: "\n"))
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<String, Error>?
}

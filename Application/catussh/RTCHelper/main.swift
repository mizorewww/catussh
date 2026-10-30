//
//  main.swift
//  catussh-rtc
//
//  Hosts the UU Remote WebRTC page for the Mac app. Mac Catalyst's WebKit has
//  no RTCPeerConnection; this helper is a macOS process, whose WebKit has it.
//  It speaks newline-delimited JSON on stdin and stdout:
//
//    in:  {"load": html, "base": url}    -> out: {"ready": true}
//    in:  {"id": n, "js": expression}    -> out: {"id": n, "ok": value} or {"id": n, "error": text}
//    out: {"event": {"name": …, "data": …}} for every message the page posts
//
//  It quits when stdin closes, that is when the app goes away.
//

import AppKit
import WebKit

final class PageHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private let output = FileHandle.standardOutput
    private let writeLock = NSLock()

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
        super.init()
        config.userContentController.add(self, name: "rtc")
        webView.navigationDelegate = self
    }

    func send(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        writeLock.withLock { output.write(line) }
    }

    func handle(_ command: [String: Any]) {
        if let html = command["load"] as? String {
            webView.loadHTMLString(html, baseURL: (command["base"] as? String).flatMap(URL.init(string:)))
            return
        }
        guard let id = command["id"], let script = command["js"] as? String else { return }
        webView.callAsyncJavaScript("return await (\(script));", in: nil, in: .page) { [weak self] result in
            switch result {
            case let .success(value):
                // Only what JSON carries; a page function's undefined is null.
                let plain: Any = JSONSerialization.isValidJSONObject(["v": value]) ? value : NSNull()
                self?.send(["id": id, "ok": plain])
            case let .failure(error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                self?.send(["id": id, "error": message])
            }
        }
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rtc", JSONSerialization.isValidJSONObject(["e": message.body]) else { return }
        send(["event": message.body])
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        send(["ready": true])
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        send(["ready": false, "error": error.localizedDescription])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let host = PageHost()

// Commands arrive on a reader thread and run on the main thread, which
// WebKit wants.
Thread.detachNewThread {
    var pending = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { DispatchQueue.main.async { exit(0) } ; return }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex ..< newline]
            pending = Data(pending[pending.index(after: newline)...])
            guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            DispatchQueue.main.async { host.handle(command) }
        }
    }
}
app.run()

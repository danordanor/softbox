// Softbox — a tiny macOS menu-bar face for the Softbox bridge.
//
// It adds an item next to the clock. Clicking it drops a popover that hosts the
// control panel (served by the lightd background service on 127.0.0.1). The app
// is an agent (no Dock icon). All light control lives in the bridge; this is
// only the face, so it stays small and reliable.

import Cocoa
import WebKit

let kPort = ProcessInfo.processInfo.environment["LIGHTD_PORT"] ?? "9124"
let kURL = URL(string: "http://127.0.0.1:\(kPort)/")!
let kSize = NSSize(width: 360, height: 560)

// MARK: - menu-bar icon drawn in code (template image, adapts to light/dark)
func lampIcon() -> NSImage {
    // the Softbox panel, upright: a tall rounded rectangle drawn as an
    // outline only (no fill), with soft corners.
    let s = NSSize(width: 15, height: 18)
    let img = NSImage(size: s)
    img.lockFocus()
    let lw: CGFloat = 1.5
    let rect = NSRect(x: 2, y: 1.5, width: 11, height: 15)
    let path = NSBezierPath(roundedRect: rect, xRadius: 2.6, yRadius: 2.6)
    path.lineWidth = lw
    NSColor.black.setStroke()
    path.stroke()
    img.unlockFocus()
    img.isTemplate = true   // the menu bar tints the outline for us
    return img
}

// MARK: - app
class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var web: WKWebView!
    var monitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        // never allow a second menu-bar item: if another copy is already
        // running, this one bows out immediately.
        let me = NSRunningApplication.current
        let twins = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier
        }
        if !twins.isEmpty { NSApp.terminate(nil); return }

        NSApp.setActivationPolicy(.accessory)

        // web view inside the popover
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = false
        web = WKWebView(frame: NSRect(origin: .zero, size: kSize), configuration: cfg)
        web.navigationDelegate = self
        web.customUserAgent = "SoftboxApp/1.1"     // the service only shows the panel to this app
        web.setValue(false, forKey: "drawsBackground")   // avoid white flash behind the dark UI
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = NSColor(white: 0.055, alpha: 1) }

        let vc = NSViewController()
        vc.view = web
        popover.contentViewController = vc
        popover.contentSize = kSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = lampIcon()
            b.toolTip = "Softbox"
            b.target = self
            b.action = #selector(click(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        load()
    }

    func load() { web.load(URLRequest(url: kURL)) }

    // links that aren't the panel itself (like shortcuts://) open in their own app
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme, scheme != "http", scheme != "about" {
            NSWorkspace.shared.open(url)
            close()
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // reload on failure so a slow-starting bridge still fills in
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { retry() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { retry() }
    func retry() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.load() } }

    @objc func click(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent!
        if ev.type == .rightMouseUp { return showMenu() }
        popover.isShown ? close() : open(sender)
    }

    func open(_ sender: NSStatusBarButton) {
        // keep the page loaded (no reload flash); just ask it for fresh state
        web.evaluateJavaScript("window.kl && kl.refresh(); 0") { [weak self] _, err in if err != nil { self?.load() } }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // close when clicking elsewhere, as a belt to .transient
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }
    func close() {
        popover.performClose(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    // right-click: your presets, one click each (✓ on the one the light is set to), then Off and Quit
    func showMenu() {
        let menu = NSMenu()
        let st = fetchState()
        let on = (st?["on"] as? Int) == 1
        let b = st?["brightness"] as? Int ?? -1, k = st?["kelvin"] as? Int ?? -1
        let cap = ((st?["power"] as? [String: Any])?["maxBrightness"] as? Int) ?? 100
        let scenes = (st?["events"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String) == "scene" }
        for sc in scenes {
            guard let id = sc["id"] as? String, let act = sc["action"] as? [String: Any],
                  (act["on"] as? Int) == 1 else { continue }
            let item = NSMenuItem(title: sc["label"] as? String ?? id, action: #selector(usePreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id
            let pk = act["kelvin"] as? Int ?? 0, pb = act["brightness"] as? Int ?? 0
            let actual = max(1, Int((Double(pb) * Double(cap) / 100).rounded()))
            if on && abs(pk - k) <= 60 && actual == b { item.state = .on }
            menu.addItem(item)
        }
        if let off = scenes.first(where: { (($0["action"] as? [String: Any])?["on"] as? Int) == 0 }),
           let id = off["id"] as? String {
            let item = NSMenuItem(title: "Off", action: #selector(usePreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id
            if st != nil && !on { item.state = .on }
            menu.addItem(item)
        }
        if st == nil {
            let item = NSMenuItem(title: "Light not reachable", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Softbox", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // so left-click keeps toggling the popover
    }

    // the service is on this Mac, so a short blocking read is fine here
    func fetchState() -> [String: Any]? {
        final class Box: @unchecked Sendable { var value: [String: Any]? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: kURL.appendingPathComponent("api/state"))
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { box.value = j }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return box.value
    }

    @objc func usePreset(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(kPort)/api/event/\(id)?force=1")!)
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Lightd")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()

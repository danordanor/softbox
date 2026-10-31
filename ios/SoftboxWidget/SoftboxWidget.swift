import WidgetKit
import SwiftUI
import AppIntents

// The small home-screen widget: the lamp itself, in its real colour and brightness.
// Tap the lamp to turn the light on or off; tap anywhere around it to open the app.
// No text at all.

@main
struct SoftboxWidgets: WidgetBundle {
    var body: some Widget { LampWidget() }
}

struct LampWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Shared.widgetKind, provider: LampProvider()) { entry in
            LampWidgetView(state: entry.state)
        }
        .configurationDisplayName("Light")
        .description("Tap the lamp to turn it on or off.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct LampEntry: TimelineEntry {
    let date: Date
    let state: LampState
}

struct LampProvider: TimelineProvider {
    func placeholder(in context: Context) -> LampEntry {
        LampEntry(date: .now, state: LampState(on: true, brightness: 62, kelvin: 3300, maxBrightness: 100))
    }
    func getSnapshot(in context: Context, completion: @escaping (LampEntry) -> Void) {
        completion(LampEntry(date: .now, state: LampState.load()))
    }
    // ask the light how it is right now; if it doesn't answer, show the last known state
    func getTimeline(in context: Context, completion: @escaping (Timeline<LampEntry>) -> Void) {
        Task {
            var s = LampState.load()
            if let fresh = await LampLink().read() { s = fresh; s.save() }
            completion(Timeline(entries: [LampEntry(date: .now, state: s)],
                                policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - the tap

struct ToggleLampIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Light"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        var s = LampState.load()
        s.on.toggle(); s.save()                       // the widget redraws at once
        if let real = await LampLink().toggle() { real.save() }
        return .result()
    }
}

// MARK: - the look

struct LampWidgetView: View {
    let state: LampState

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let lw = w * 0.469, lh = h * 0.694
            let c = state.on ? kelvinRGB(state.kelvin) : [0.23, 0.23, 0.25]
            let L = state.level
            ZStack {
                // the glow on the wall around the lamp
                if state.on {
                    Ellipse()
                        .fill(RadialGradient(colors: [rgb(c).opacity(0.28 + 0.3 * L), rgb(c).opacity(0)],
                                             center: .center, startRadius: 0, endRadius: h * 0.58))
                        .frame(width: w, height: h * 1.16)
                }
                Button(intent: ToggleLampIntent()) {
                    ZStack {
                        WSquircle(n: 3.6)
                            .fill(RadialGradient(colors: face(c, L),
                                                 center: UnitPoint(x: 0.5, y: 0.42),
                                                 startRadius: 0, endRadius: lh * 0.7))
                            .brightness(state.on ? (-0.38 + 0.5 * L) * 0.5 : 0)
                        ring(lw: lw, lh: lh)
                    }
                    .frame(width: lw, height: lh)
                    .contentShape(WSquircle(n: 3.6))
                }
                .buttonStyle(.plain)
            }
            .frame(width: w, height: h)
        }
        .containerBackground(for: .widget) { Color(red: 0.078, green: 0.082, blue: 0.094) }
    }

    // the dot: across for warmth, up for brightness, like the app
    private func ring(lw: CGFloat, lh: CGFloat) -> some View {
        let m = lw * 0.147
        let x = m + CGFloat(Double(state.kelvin - 2900) / 4100) * (lw - 2 * m)
        let y = m + CGFloat(1 - state.level) * (lh - 2 * m)
        let stroke = state.on ? Color(red: 0.55, green: 0.37, blue: 0.22).opacity(0.7) : Color.white.opacity(0.35)
        return Circle()
            .stroke(stroke, lineWidth: 1.2)
            .frame(width: lw * 0.14, height: lw * 0.14)
            .position(x: x, y: y)
            .frame(width: lw, height: lh)
    }

    private func face(_ c: [Double], _ L: Double) -> [Color] {
        guard state.on else {
            return [Color(red: 0.227, green: 0.231, blue: 0.251), Color(red: 0.18, green: 0.184, blue: 0.204),
                    Color(red: 0.149, green: 0.153, blue: 0.169)]
        }
        let toWhite = 0.25 + 0.4 * L
        return [rgb(mix(c, [1, 1, 1], toWhite)), rgb(c), rgb(mix(c, [0.784, 0.47, 0.235], 0.18))]
    }
    private func mix(_ a: [Double], _ b: [Double], _ f: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * f } }
    private func rgb(_ c: [Double]) -> Color { Color(red: c[0], green: c[1], blue: c[2]) }
}

// warmth (Kelvin) -> screen colour, 0...1
func kelvinRGB(_ k: Int) -> [Double] {
    let t = Double(k) / 100
    var r, g, b: Double
    if t <= 66 { r = 255; g = 99.47 * log(t) - 161.1; b = t <= 19 ? 0 : 138.5 * log(t - 10) - 305.0 }
    else { r = 329.7 * pow(t - 60, -0.1332); g = 288.1 * pow(t - 60, -0.0755); b = 255 }
    return [r, g, b].map { min(255, max(0, $0)) / 255 }
}

// the lamp's outline: a superellipse, the same family as the app icon
struct WSquircle: Shape {
    var n: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
        for i in 0..<160 {
            let t = 2 * Double.pi * Double(i) / 160
            let c = cos(t), s = sin(t)
            let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
            let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - talking to the light

// A short, one-off connection: open, ask or change, close.
// The widget can't keep a socket open the way the app does.
final class LampLink: NSObject, URLSessionDelegate {
    private var identity: SecIdentity?
    private var chain: [SecCertificate] = []

    override init() {
        super.init()
        guard let url = Bundle.main.url(forResource: "Softbox", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else { return }
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: "keylight"]
        guard SecPKCS12Import(data as CFData, opts as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let id = first[kSecImportItemIdentity as String] else { return }
        let ident = id as! SecIdentity
        identity = ident
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(ident, &leaf)
        let all = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        chain = all.filter { c in
            guard let leaf else { return true }
            return SecCertificateCopyData(c) as Data != SecCertificateCopyData(leaf) as Data
        }
    }

    func read() async -> LampState? {
        await session { t in try await self.state(t) }
    }

    // flip whatever the light is doing right now, not what the widget last saw
    func toggle() async -> LampState? {
        await session { t in
            var s = try await self.state(t)
            s.on.toggle()
            _ = try await self.call(t, "put.elgato.lights",
                                    ["numberOfLights": 1, "lights": [["on": s.on ? 1 : 0]]], id: "2")
            return s
        }
    }

    private func state(_ t: URLSessionWebSocketTask) async throws -> LampState {
        let r = try await call(t, "get.elgato.lights", [:], id: "1")
        guard let l = (r["lights"] as? [[String: Any]])?.first else { throw URLError(.badServerResponse) }
        var s = LampState.load()
        if let v = l["on"] as? Int { s.on = v == 1 }
        if let v = l["brightness"] as? Int { s.brightness = max(1, min(100, v)) }
        if let v = l["temperature"] as? Int, v > 0 { s.kelvin = max(2900, min(7000, Int((1_000_000.0 / Double(v)).rounded()))) }
        return s
    }

    private func session(_ work: @escaping (URLSessionWebSocketTask) async throws -> LampState) async -> LampState? {
        guard identity != nil else { return nil }
        let d = Shared.defaults
        var targets: [String] = []
        if let ip = d.string(forKey: "lightIP") { targets.append(ip) }
        if let host = d.string(forKey: "lightHost") { targets.append(host) }
        for target in targets {                       // the saved IP first, then the .local name
            let h = target.hasSuffix(".") ? String(target.dropLast()) : target
            guard let url = URL(string: "wss://\(h):9123/") else { continue }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 4
            cfg.waitsForConnectivity = false
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: url)
            t.resume()
            let result = try? await withThrowingTaskGroup(of: LampState.self) { g -> LampState in
                g.addTask { try await work(t) }
                g.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw URLError(.timedOut) }
                let first = try await g.next()!
                g.cancelAll()
                return first
            }
            t.cancel(with: .goingAway, reason: nil)
            s.invalidateAndCancel()
            if let result { return result }
        }
        return nil
    }

    private func call(_ t: URLSessionWebSocketTask, _ method: String, _ params: [String: Any], id: String) async throws -> [String: Any] {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: msg)
        try await t.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let m = try await t.receive()
            guard case .string(let str) = m,
                  let j = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] else { continue }
            if (j["id"] as? String) == id { return (j["result"] as? [String: Any]) ?? [:] }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate, let id = identity {
            completionHandler(.useCredential, URLCredential(identity: id, certificates: chain.isEmpty ? nil : chain,
                                                            persistence: .forSession)); return
        }
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust)); return   // the light's cert is self-signed
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

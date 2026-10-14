// LightController — talks straight to the Elgato Key Light Air MK.2 over its
// local, mutually-authenticated TLS WebSocket (JSON-RPC). No Mac, no bridge.
//
// The light requires a client certificate minted from the Elgato app's
// intermediate CA; that identity is bundled as Softbox.p12 (see
// make-identity.sh). The light's own server certificate is self-signed, so we
// accept it explicitly. Request ids must be STRINGS — a numeric id reboots the
// firmware.

import Foundation
import Network
import Combine
import AppIntents

@MainActor
final class LightController: NSObject, ObservableObject {
    // one instance for the app and for Shortcuts actions
    static let shared = LightController()

    // live state, bound to the UI
    @Published var connected = false
    @Published var on = false
    @Published var brightness = 20        // 1...100
    @Published var kelvin = 4500           // 2900...7000
    @Published var statusText = "Looking for your light…"
    // true once we've seen the light before: the app opens straight onto its last state
    // and reconnects quietly underneath, instead of showing a loader every time
    @Published var cached = false
    // no light on this network (say, showing the app to someone): the interface works as usual,
    // but nothing is sent. Turns on by itself after a few seconds without the light, off the moment it answers.
    @Published var demo = false
    // what the current power supply allows (the light reports this itself)
    @Published var maxBrightness = 100
    @Published var maxLumen: Int? = nil
    @Published var watts: Double? = nil
    private var hwFade = false
    private var fadeBusy = false
    private var lightSettings: [String: Any]? = nil

    // networking
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    // read from the (nonisolated) TLS challenge callback, written once at launch
    nonisolated(unsafe) private var identity: SecIdentity?
    // the intermediate CA that signed our client cert. The light needs it to
    // verify us, and iOS only sends it if we pass it explicitly.
    nonisolated(unsafe) private var chain: [SecCertificate] = []
    private var reqId = 0
    private var host: String? {
        get { UserDefaults.standard.string(forKey: "lightHost") }
        set { UserDefaults.standard.set(newValue, forKey: "lightHost") }
    }
    // the light's IP address, found via Bonjour. Used as a fallback when the
    // .local name doesn't work.
    private var ip: String? {
        get { UserDefaults.standard.string(forKey: "lightIP") }
        set { UserDefaults.standard.set(newValue, forKey: "lightIP") }
    }
    private var useIP = false
    private var lastError = ""

    // discovery
    private var browser: NetServiceBrowser?
    private var pending: NetService?

    // effects
    private var effectTask: Task<Void, Never>?

    override init() {
        super.init()
        loadIdentity()
        loadCache()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4            // a dead address fails fast instead of hanging for a minute
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        guard identity != nil else { return }        // the status already says what's wrong
        useIP = ip != nil                            // the saved IP connects faster than resolving the .local name
        if host != nil || ip != nil { reconnect() }
        discover()                                   // always look, to keep the address fresh
        armDemo()
    }

    private var demoArm = 0
    private func armDemo() {
        demoArm += 1; let n = demoArm
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, n == self.demoArm, !self.connected else { return }
            if !self.cached { self.on = true; self.brightness = 40; self.kelvin = 4300 }   // a pleasant first look
            self.demo = true
        }
    }

    // the last state the light reported, so the app can show it the moment it opens
    private func loadCache() {
        guard let c = UserDefaults.standard.dictionary(forKey: "lastLight") else { return }
        if let v = c["on"] as? Bool { on = v }
        if let v = c["brightness"] as? Int { brightness = max(1, min(100, v)) }
        if let v = c["kelvin"] as? Int { kelvin = max(2900, min(7000, v)) }
        if let v = c["maxBrightness"] as? Int { maxBrightness = max(1, min(100, v)) }
        cached = true
    }
    private func saveCache() {
        UserDefaults.standard.set(["on": on, "brightness": brightness, "kelvin": kelvin, "maxBrightness": maxBrightness],
                                  forKey: "lastLight")
        cached = true
    }

    // back in the foreground: check the socket is still alive (iOS drops it while the app sleeps),
    // and if it doesn't answer quickly, reconnect at once instead of waiting for it to time out
    private var pingSeq = 0
    func wake() {
        armDemo()
        guard identity != nil else { demo = true; return }
        guard let t = task, connected else {
            if host != nil || ip != nil { reconnect() } else { discover() }
            return
        }
        pingSeq += 1; let seq = pingSeq
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self, seq == self.pingSeq else { return }
                self.pingSeq += 1
                if err != nil { self.connected = false; self.reconnect() } else { self.refresh() }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, seq == self.pingSeq else { return }
            self.pingSeq += 1; self.connected = false; self.reconnect()
        }
    }

    private func reconnect() {
        // alternate between the .local name and the IP until one works
        let target = (useIP ? ip : host) ?? host ?? ip
        if let t = target { connect(to: t) }
    }

    // MARK: identity
    private func loadIdentity() {
        guard let url = Bundle.main.url(forResource: "Softbox", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            statusText = "Missing certificate (run make-identity.sh)"; return
        }
        let opts = [kSecImportExportPassphrase as String: "keylight"]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let id = first[kSecImportItemIdentity as String] else {
            statusText = "Certificate unreadable (error \(status)). Run make-identity.sh again."
            return
        }
        let ident = id as! SecIdentity
        identity = ident
        // keep every cert in the chain except our own leaf
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(ident, &leaf)
        let all = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        chain = all.filter { c in
            guard let leaf else { return true }
            return SecCertificateCopyData(c) as Data != SecCertificateCopyData(leaf) as Data
        }
    }

    // MARK: discovery (Bonjour _elg._tcp)
    func discover() {
        browser?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_elg._tcp.", inDomain: "local.")
        browser = b
        if !connected && host == nil { statusText = "Looking for your light…" }
    }

    func setHost(_ h: String) {
        let clean = h.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if clean.first?.isNumber == true { ip = clean; useIP = true } else { host = clean; useIP = false }
        connect(to: clean)
    }

    fileprivate func found(host h: String?, ip a: String?) {
        if let h { host = h }
        if let a { ip = a }
        // don't cut short an attempt that's already on its way
        if !connected && Date().timeIntervalSince(attemptStarted) > 3 { reconnect() }
    }

    // MARK: connection
    private var current: String = ""
    private var attemptStarted = Date.distantPast
    private func connect(to target: String) {
        attemptStarted = Date()
        task?.cancel(with: .goingAway, reason: nil)
        let h = target.hasSuffix(".") ? String(target.dropLast()) : target
        guard let url = URL(string: "wss://\(h):9123/") else { return }
        current = h
        statusText = "Connecting to \(h)…"
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
        refresh()
        rpc("get.elgato.accessory-info", params: [:])
        rpc("get.elgato.lights.settings", params: [:])
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            // the completion runs off the main actor; hop back on for all work
            Task { @MainActor in
                guard let self, t === self.task else { return }   // ignore stale tasks
                switch result {
                case .failure(let err):
                    self.connected = false
                    let why = self.lastError.isEmpty ? err.localizedDescription : self.lastError
                    self.statusText = "Can't connect to \(self.current): \(why)"
                    self.lastError = ""
                    self.useIP.toggle()                           // try the other address next
                    self.retry()
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive(t)
                }
            }
        }
    }

    private var retrying = false
    private func retry() {
        guard !retrying else { return }
        retrying = true
        Task { try? await Task.sleep(nanoseconds: self.demo ? 5_000_000_000 : 600_000_000)   // quick to recover, calm when there is no light
            self.retrying = false
            if self.host == nil && self.ip == nil { self.discover() } else { self.reconnect() }
        }
    }

    fileprivate func noteError(_ e: String) { lastError = e }

    private func handle(_ s: String) {
        guard let data = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = (j["result"] as? [String: Any]) ?? (j["params"] as? [String: Any])
        if let p = payload?["power-info"] as? [String: Any] {
            maxBrightness = max(1, min(100, (p["maximumBrightness"] as? Int) ?? 100))
            maxLumen = p["maximumLumen"] as? Int
            if let pdo = (p["source"] as? [String: Any])?["pdo"] as? [String: Any],
               let mv = pdo["voltage"] as? Int, let ma = pdo["current"] as? Int {
                watts = (Double(mv * ma) / 1e5).rounded() / 10
            }
        }
        // the light's own fade time; when it's soft (set by the Mac), effects let the light glide
        if let ms = payload?["colorChangeDurationMs"] as? Int {
            if !fadeBusy { hwFade = ms >= 300 }
            lightSettings = payload
        }
        if let lights = payload?["lights"] as? [[String: Any]], let l = lights.first {
            connected = true; statusText = ""; demo = false
            if let v = l["on"] as? Int { on = v == 1 }
            if let v = l["brightness"] as? Int { brightness = max(1, min(100, v)) }
            if let v = l["temperature"] as? Int { kelvin = Int((1_000_000.0 / Double(v)).rounded()) }
            saveCache()
        }
    }

    // MARK: JSON-RPC
    private func rpc(_ method: String, params: Any?) {
        if demo && method.hasPrefix("put.") { return }     // demo: the interface moves, the light doesn't
        reqId += 1
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": "\(reqId)", "method": method] // string id!
        if let p = params { msg["params"] = p }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { _ in }
    }

    func refresh() { rpc("get.elgato.lights", params: [:]) }

    // change only how long the light takes to glide between values (it keeps the rest of its settings)
    @discardableResult
    private func setFade(_ ms: Int) -> Bool {
        guard var st = lightSettings else { return false }
        st["colorChangeDurationMs"] = ms
        fadeBusy = ms != 400
        rpc("put.elgato.lights.settings", params: st)
        lightSettings = st
        return true
    }

    private func put(_ light: [String: Any]) {
        rpc("put.elgato.lights", params: ["numberOfLights": 1, "lights": [light]])
    }

    static func k2m(_ k: Int) -> Int { max(143, min(344, Int((1_000_000.0 / Double(max(1, k))).rounded()))) }

    // MARK: control (used by the UI)
    // Brightness on a 1-100 scale of what the current power allows:
    // 100% is the most the charger permits (20% of the light on 4.5W, all of it on 30W).
    var level: Int { max(1, min(100, Int((Double(brightness) * 100 / Double(max(1, maxBrightness))).rounded()))) }
    func actual(_ r: Int) -> Int {
        max(1, min(maxBrightness, Int((Double(max(1, min(100, r))) * Double(maxBrightness) / 100).rounded())))
    }
    func setLevel(_ r: Int) { setBrightness(actual(r)) }
    func setPoint(kelvin k: Int, level r: Int) { if !on { on = true }; setKelvin(k); setLevel(r) }

    func setOn(_ v: Bool) { on = v; put(["on": v ? 1 : 0]) }
    func toggle() { setOn(!on) }

    func setBrightness(_ v: Int) {
        brightness = max(1, min(maxBrightness, v)); if !on { on = true }
        throttledPut(["on": 1, "brightness": brightness])   // coalesce while dragging
    }
    func setKelvin(_ v: Int) {
        kelvin = max(2900, min(7000, v))
        throttledPut(["temperature": Self.k2m(kelvin)])
    }

    // coalesce rapid drag updates into ~one network write per 90ms
    private var pendingPut: [String: Any] = [:]
    private var putScheduled = false
    private func throttledPut(_ light: [String: Any]) {
        pendingPut.merge(light) { _, new in new }
        guard !putScheduled else { return }
        putScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self else { return }
            self.putScheduled = false
            let l = self.pendingPut; self.pendingPut = [:]
            if !l.isEmpty { self.put(l) }
        }
    }
    func applyMoment(on o: Bool, brightness b: Int?, kelvin k: Int?) {
        var l: [String: Any] = ["on": o ? 1 : 0]
        if let b { l["brightness"] = actual(b) }                 // presets are on the 0-100 scale
        if let k { l["temperature"] = Self.k2m(k) }
        on = o; if let b { brightness = actual(b) }; if let k { kelvin = k }
        put(l)
    }

    // MARK: used by Shortcuts actions
    func ensureConnected(timeout: Double = 8) async throws {
        if connected { return }
        if task == nil { reconnect() }
        let deadline = Date().addingTimeInterval(timeout)
        while !connected && Date() < deadline {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if !connected { throw LightIntentError.offline }
    }
    func playAndWait(_ effect: Effect) async {
        effectTask?.cancel()
        await run(effect)
    }

    // Sunrise and Wind down. Warmth and brightness each move on their own, one after the other.
    // iOS gives a Shortcuts action about 30 seconds, so the whole thing fits inside that.
    func sunrise() async {
        effectTask?.cancel(); refresh()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !on {                                       // start as a faint warm glow
            await step(["on": 1, "brightness": 1, "temperature": Self.k2m(3400)], 120); on = true
            brightness = 1; kelvin = 3400
        }
        await sweep(from: brightness, to: actual(80), seconds: 18, curve: Self.there)   // light first
        brightness = actual(80)
        await warmth(to: 4800, seconds: 6)                                               // then cooler
    }
    func windDown() async {
        effectTask?.cancel(); refresh()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard on else { return }
        await warmth(to: 2900, seconds: 8)                                               // warmth first
        await sweep(from: brightness, to: 1, seconds: 16, curve: Self.there)             // then dim
        brightness = 1
        await step(["on": 0], 200); on = false
    }
    private func warmth(to k1: Int, seconds: Double) async {
        let m0 = Self.k2m(kelvin), m1 = Self.k2m(k1)
        let n = max(2, Int(seconds * 10))
        for i in 1...n {
            if Task.isCancelled { return }
            let f = Self.there(Double(i) / Double(n))
            put(["temperature": Int((Double(m0) + Double(m1 - m0) * f).rounded())])
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        kelvin = k1
    }

    // MARK: effects — run locally on the phone, stepping the light over time
    func play(_ effect: Effect) {
        effectTask?.cancel()
        effectTask = Task { [weak self] in await self?.run(effect) }
    }

    private func step(_ light: [String: Any], _ ms: UInt64) async {
        put(light)
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    // Brightness the way the eye sees it: move through perceived lightness,
    // not raw percent, so dim changes don't look abrupt.
    private static func perceptual(_ a: Int, _ b: Int, _ f: Double) -> Int {
        let g = 2.2
        let a = Double(max(1, min(100, a))), b = Double(max(1, min(100, b)))   // never feed pow a negative
        let f = f.isFinite ? max(0, min(1, f)) : 1
        let pa = pow(a / 100, 1 / g), pb = pow(b / 100, 1 / g)
        let v = pow(pa + (pb - pa) * f, g) * 100
        return v.isFinite ? max(1, min(100, Int(v.rounded()))) : Int(b)
    }

    // Play a list of (brightness) keyframes as one smooth curve at ~20 updates a second.
    // Every effect starts and ends exactly where the light was: no jumps.
    // With soft transitions the light glides between points, so a point every 0.4s is
    // smoother than many tiny jumps; without them, 20 steps a second.
    private func sweep(from a: Int, to b: Int, seconds: Double, curve: (Double) -> Double) async {
        let step = hwFade ? 0.4 : 0.05
        let n = max(2, Int((seconds / step).rounded()))
        var last = -1
        for i in 1...n {
            if Task.isCancelled { return }
            let v = Self.perceptual(a, b, curve(Double(i) / Double(n)))
            if v != last { put(["brightness": v]); last = v }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
    }
    private static let there = { (t: Double) in (1 - cos(t * .pi)) / 2 }            // ease in-out, a -> b
    private static let thereAndBack = { (t: Double) in (1 - cos(t * 2 * .pi)) / 2 }  // a -> b -> a

    private func run(_ e: Effect) async {
        refresh()
        try? await Task.sleep(nanoseconds: 180_000_000)
        let cap = maxBrightness
        var b0 = min(brightness, cap)
        let k0 = kelvin, on0 = on
        if !on0 { b0 = max(1, Int((Double(cap) * 0.4).rounded())); await step(["on": 1, "brightness": 1], 40); await sweep(from: 1, to: b0, seconds: 0.6, curve: Self.there) }

        // the flicker: up 10% of what the power allows and back, three beats; warmth pinned where it is
        let d = max(1, Int((Double(cap) * 0.1).rounded()))
        let hi = b0 + d <= cap ? b0 + d : max(1, b0 - d)     // only at the very top does it dip instead
        let mired = Self.k2m(k0)
        let glide = 0.9                                       // seconds for each rise and each settle
        switch e {
        case .breath:
            if hwFade, setFade(Int(glide * 1000)) {
                // the light glides by itself: one value per half-beat, and never interrupt a glide
                try? await Task.sleep(nanoseconds: 150_000_000)
                for _ in 0..<3 {
                    if Task.isCancelled { break }
                    put(["brightness": hi, "temperature": mired]); try? await Task.sleep(nanoseconds: UInt64((glide + 0.06) * 1e9))
                    put(["brightness": b0, "temperature": mired]); try? await Task.sleep(nanoseconds: UInt64((glide + 0.06) * 1e9))
                }
                _ = setFade(400)
            } else {                                          // no fades in the light: draw the curve ourselves
                for _ in 0..<3 {
                    let n = Int((2 * glide / 0.05).rounded())
                    for i in 1...n {
                        if Task.isCancelled { break }
                        put(["brightness": Self.perceptual(b0, hi, Self.thereAndBack(Double(i) / Double(n))), "temperature": mired])
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
        }
        put(["brightness": b0])                          // settle exactly
        if !on0 { await sweep(from: b0, to: 1, seconds: 0.6, curve: Self.there); put(["on": 0]) }
    }
}

// One gentle effect: a soft flicker, 10% up and back, three times in two seconds. Brightness only.
enum Effect: String, CaseIterable, Identifiable {
    case breath
    var id: String { rawValue }
    var label: String { "Breath" }
}

// MARK: - mTLS + WebSocket delegate
extension LightController: URLSessionDelegate, URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate, let id = identity {
            // hand the light our client identity plus the intermediate that signed it
            let certs: [Any]? = chain.isEmpty ? nil : chain
            completionHandler(.useCredential, URLCredential(identity: id, certificates: certs, persistence: .forSession)); return
        }
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            // the light's certificate is self-signed; accept it
            completionHandler(.useCredential, URLCredential(trust: trust)); return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in self.statusText = "Connected"; self.refresh() }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // keep the most specific reason (TLS, refused, timeout…) for the status line
        let ns = error as NSError
        let detail = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        Task { @MainActor in self.noteError(detail) }
    }
}

// MARK: - Bonjour discovery
extension LightController: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.pending = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        // pull the IPv4 address out of the resolved sockaddrs
        var ipv4: String?
        for d in sender.addresses ?? [] {
            d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let sa = p.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      sa.pointee.sa_family == sa_family_t(AF_INET) else { return }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(d.count), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    ipv4 = String(cString: buf)
                }
            }
        }
        let name = sender.hostName
        Task { @MainActor in self.found(host: name, ip: ipv4) }
    }
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in self.statusText = "Found the light but couldn't resolve its address" }
    }
}

// MARK: - ============ Mac bridge (Claude signals, daylight) ============
// BridgeController — finds the Softbox bridge on your Mac (Bonjour
// _softbox._tcp) and reads/writes its settings: which effect each Claude
// signal plays, whether it's on, and the daylight rhythm. Those features run
// on the Mac (that's where Claude Code lives), so the phone edits them there.


struct LightSignal: Identifiable, Equatable {
    let id: String
    var label: String
    var enabled: Bool
    var effect: String
}

@MainActor
final class BridgeController: NSObject, ObservableObject {
    @Published var found = false
    @Published var status = "Looking for your Mac…"
    @Published var signals: [LightSignal] = []
    @Published var daylight = false

    private var base: URL?
    private var browser: NetServiceBrowser?
    private var pending: NetService?

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "bridgeURL"), let u = URL(string: saved) {
            base = u; Task { await self.load() }
        }
        discover()
    }

    func discover() {
        browser?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_softbox._tcp.", inDomain: "local.")
        browser = b
    }

    fileprivate func use(host: String, port: Int) {
        let h = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard let u = URL(string: "http://\(h):\(port)") else { return }
        base = u
        UserDefaults.standard.set(u.absoluteString, forKey: "bridgeURL")
        Task { await load() }
    }

    func load() async {
        guard let base else { return }
        do {
            var req = URLRequest(url: base.appendingPathComponent("api/state"))
            req.timeoutInterval = 4
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            daylight = (j["daylight"] as? Bool) ?? false
            let events = (j["events"] as? [[String: Any]]) ?? []
            signals = events.compactMap { e in
                guard (e["kind"] as? String) == "signal", let id = e["id"] as? String else { return nil }
                return LightSignal(id: id, label: (e["label"] as? String) ?? id,
                              enabled: (e["enabled"] as? Bool) ?? true,
                              effect: (e["effect"] as? String) ?? "breath")
            }
            found = true; status = ""
        } catch {
            found = false
            status = "Your Mac isn't reachable. Signals and rhythm need it on, on the same Wi-Fi."
        }
    }

    private func post(_ body: [String: Any]) {
        guard let base else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/config"))
        req.httpMethod = "POST"
        req.setValue("1", forHTTPHeaderField: "X-Lightd")          // the bridge requires it
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req).resume()
    }

    func setEffect(_ signal: String, _ effect: String) {
        if let i = signals.firstIndex(where: { $0.id == signal }) { signals[i].effect = effect }
        post(["events": [signal: ["effect": effect]]])
    }
    func setEnabled(_ signal: String, _ on: Bool) {
        if let i = signals.firstIndex(where: { $0.id == signal }) { signals[i].enabled = on }
        post(["events": [signal: ["enabled": on]]])
    }
    func setDaylight(_ on: Bool) {
        daylight = on
        post(["daylight": on])
    }
}

extension BridgeController: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.pending = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName
        let port = sender.port
        Task { @MainActor in
            if let host, port > 0 { self.use(host: host, port: port) }
        }
    }
}


// MARK: - ============ Shortcuts actions ============
// These show up in the Shortcuts app, so any iPhone automation (an email or
// message arriving, plugging in the charger, an alarm, Back Tap, an NFC tag…)
// can drive the light directly, without the Mac.

// A short note each time a Shortcuts action runs, shown in Settings.
// (iOS doesn't let apps read your automations, so this is how the app sees them working.)
enum AutomationLog {
    struct Run: Identifiable { let id: Double; let what: String; var date: Date { Date(timeIntervalSince1970: id) } }
    private static let key = "automationLog"
    static func add(_ what: String) {
        var list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        list.insert(["t": Date().timeIntervalSince1970, "s": what], at: 0)
        UserDefaults.standard.set(Array(list.prefix(6)), forKey: key)
    }
    static func recent() -> [Run] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { d in
            guard let t = d["t"] as? Double, let s = d["s"] as? String else { return nil }
            return Run(id: t, what: s)
        }
    }
}

enum LightIntentError: Error, CustomLocalizedStringResourceConvertible {
    case offline
    var localizedStringResource: LocalizedStringResource { "Couldn't reach your Softbox. Is it on the same Wi-Fi?" }
}

enum EffectOption: String, AppEnum {
    case breath
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Light effect"
    static var caseDisplayRepresentations: [EffectOption: DisplayRepresentation] = [.breath: "Breath"]
}

enum PresetOption: String, AppEnum {
    case focus, meeting, evening, off
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Light preset"
    static var caseDisplayRepresentations: [PresetOption: DisplayRepresentation] = [
        .focus: "Focus", .meeting: "Meeting", .evening: "Evening", .off: "Off",
    ]
}

struct PlayEffectIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Light Effect"
    static var description = IntentDescription("Plays an effect on your Softbox, then returns it to how it was.")
    @Parameter(title: "Effect", default: .breath) var effect: EffectOption
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$effect) on the light") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        let fx = Effect(rawValue: effect.rawValue) ?? .breath
        AutomationLog.add("Played \(fx.label)")
        await light.playAndWait(fx)
        return .result()
    }
}

// The first version of the preset action, kept so shortcuts made with it keep working.
struct SetPresetIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "Set Light Preset"
    static var description = IntentDescription("Switches your Softbox to a preset.")
    @Parameter(title: "Preset", default: .focus) var preset: PresetOption
    static var parameterSummary: some ParameterSummary { Summary("Set the light to \(\.$preset)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        AutomationLog.add(preset == .off ? "Turned off" : "Preset \(preset.rawValue.capitalized)")
        switch preset {
        case .off:
            light.applyMoment(on: false, brightness: nil, kelvin: nil)
        default:
            let v = PresetStore.shared.v(preset.rawValue)        // the presets as you set them
            light.applyMoment(on: true, brightness: v[1], kelvin: v[0])
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the write go out
        return .result()
    }
}

// Your presets as Shortcuts sees them, including ones you added, plus Off.
struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Light preset"
    static var defaultQuery = PresetQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PresetQuery: EntityQuery {
    @MainActor private func all() -> [PresetEntity] {
        PresetStore.shared.items.map { PresetEntity(id: $0.id, name: $0.name) } + [PresetEntity(id: "off", name: "Off")]
    }
    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        await MainActor.run { all().filter { identifiers.contains($0.id) } }
    }
    func suggestedEntities() async throws -> [PresetEntity] {
        await MainActor.run { all() }
    }
}

struct UsePresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Use Light Preset"
    static var description = IntentDescription("Switches your Softbox to one of your presets.")
    @Parameter(title: "Preset") var preset: PresetEntity
    static var parameterSummary: some ParameterSummary { Summary("Set the light to \(\.$preset)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        AutomationLog.add(preset.id == "off" ? "Turned off" : "Preset \(preset.name)")
        if preset.id == "off" {
            light.applyMoment(on: false, brightness: nil, kelvin: nil)
        } else {
            let v = PresetStore.shared.v(preset.id)
            light.applyMoment(on: true, brightness: v[1], kelvin: v[0])
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the write go out
        return .result()
    }
}

struct SunriseIntent: AppIntent {
    static var title: LocalizedStringResource = "Sunrise"
    static var description = IntentDescription("Wakes the light slowly, from a warm glow to bright daylight.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        AutomationLog.add("Sunrise")
        await light.sunrise()
        return .result()
    }
}

struct WindDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Wind Down"
    static var description = IntentDescription("Warms and dims the light slowly, then turns it off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        AutomationLog.add("Wind down")
        await light.windDown()
        return .result()
    }
}

struct ToggleLightIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Light"
    static var description = IntentDescription("Turns your Softbox on or off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let light = LightController.shared
        try await light.ensureConnected()
        light.toggle()
        AutomationLog.add(light.on ? "Turned on" : "Turned off")
        try await Task.sleep(nanoseconds: 300_000_000)
        return .result()
    }
}

struct SoftboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayEffectIntent(),
                    phrases: ["Breathe \(.applicationName)", "Play an effect on \(.applicationName)"],
                    shortTitle: "Play Effect", systemImageName: "light.max")
        AppShortcut(intent: UsePresetIntent(),
                    phrases: ["Set \(.applicationName) preset"],
                    shortTitle: "Set Preset", systemImageName: "circle.grid.2x2")
        AppShortcut(intent: SunriseIntent(),
                    phrases: ["\(.applicationName) sunrise"],
                    shortTitle: "Sunrise", systemImageName: "sunrise")
        AppShortcut(intent: WindDownIntent(),
                    phrases: ["\(.applicationName) wind down"],
                    shortTitle: "Wind Down", systemImageName: "moon.zzz")
        AppShortcut(intent: ToggleLightIntent(),
                    phrases: ["Toggle \(.applicationName)"],
                    shortTitle: "Toggle Light", systemImageName: "power")
    }
}

import SwiftUI
import UIKit
import AppIntents

// warmth (Kelvin) -> an approximate screen colour for the glow
func kelvinColor(_ k: Int) -> Color {
    let t = Double(k) / 100.0
    var r, g, b: Double
    if t <= 66 {
        r = 255
        g = 99.4708025861 * log(t) - 161.1195681661
        b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    } else {
        r = 329.698727446 * pow(t - 60, -0.1332047592)
        g = 288.1221695283 * pow(t - 60, -0.0755148492)
        b = 255
    }
    func c(_ x: Double) -> Double { min(255, max(0, x)) / 255 }
    return Color(red: c(r), green: c(g), blue: c(b))
}

// A preset: a named spot on the light. Brightness is on the 0-100 scale of what the power allows.
struct Preset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kelvin: Int
    var brightness: Int
}

// The presets, saved on the phone. Drag a circle to move it; press and hold the light to add one.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    static let defaults: [Preset] = [
        Preset(id: "focus", name: "Focus", kelvin: 6200, brightness: 78),
        Preset(id: "meeting", name: "Meeting", kelvin: 4300, brightness: 28),
        Preset(id: "evening", name: "Evening", kelvin: 3100, brightness: 12),
    ]
    @Published var items: [Preset]

    init() {
        if let d = UserDefaults.standard.data(forKey: "presets.v2"),
           let list = try? JSONDecoder().decode([Preset].self, from: d) {
            items = list
        } else {                                   // carry over the spots from the first version
            let old = UserDefaults.standard.dictionary(forKey: "presets") as? [String: [Int]] ?? [:]
            items = Self.defaults.map { p in
                var p = p
                if let v = old[p.id], v.count == 2 { p.kelvin = v[0]; p.brightness = v[1] }
                return p
            }
        }
    }
    func v(_ id: String) -> [Int] {
        if let p = items.first(where: { $0.id == id }) { return [p.kelvin, p.brightness] }
        return [4500, 50]
    }
    func set(_ id: String, kelvin: Int, brightness: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].kelvin = kelvin; items[i].brightness = brightness
    }
    @discardableResult
    func add(name: String, kelvin: Int, brightness: Int) -> Preset {
        let p = Preset(id: UUID().uuidString, name: name, kelvin: kelvin, brightness: brightness)
        items.append(p); save(); return p
    }
    func rename(_ id: String, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = name; save()
    }
    func remove(_ id: String) { items.removeAll { $0.id == id }; save() }
    func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "presets.v2") }
    }
    func reset() { items = Self.defaults; save() }
}

struct ContentView: View {
    @EnvironmentObject var light: LightController
    @EnvironmentObject var bridge: BridgeController
    @State private var showSettings = false
    @State private var axis = 0               // 0 idle, 1 dragging
    @State private var lastTick: Int? = nil
    @ObservedObject private var presets = PresetStore.shared
    @State private var movingID: String? = nil      // the preset being dragged
    @State private var moveStart: CGPoint? = nil
    @State private var movePoint: CGPoint? = nil    // where that preset is under the finger
    @State private var live: CGPoint? = nil         // the ring under the finger while dragging

    // press and hold the light to save that spot as a new preset
    @State private var pressStart: CGPoint? = nil
    @State private var pressMoved = false
    @State private var pressTask: Task<Void, Never>? = nil
    @State private var newPoint: (k: Int, b: Int)? = nil
    @State private var showNew = false
    @State private var editing: Preset? = nil
    @State private var showRename = false
    @State private var nameField = ""

    private var level: Double { Double(light.level) / 100 }
    private var glow: Color { kelvinColor(light.kelvin) }

    // the map is the whole lamp: edge to edge, following its rounded outline
    private static let M: CGFloat = 24
    private let ink = Color(red: 0.32, green: 0.2, blue: 0.1)
    private var hairline: Color { ink.opacity(0.4) }          // the line and the ring share one stroke

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.059, blue: 0.071).ignoresSafeArea()
            if light.on {            // the light spilling into the room
                glow.opacity(0.14 * level + 0.03).blur(radius: 100).ignoresSafeArea()
                    .animation(.easeOut(duration: 0.4), value: light.level)
            }
            VStack(spacing: 0) {
                header.padding(.horizontal, 24)
                lamp.padding(.horizontal, 16).padding(.top, 8)
                footer
            }
            .padding(.vertical, 8)
            if !light.connected && !light.cached && !light.demo { connectOverlay }   // only the very first time
        }
        .animation(.easeOut(duration: 0.6), value: light.connected || light.cached || light.demo)
        .foregroundStyle(.white)
        .alert("New preset", isPresented: $showNew) {
            TextField("Name", text: $nameField)
            Button("Add") {
                if let p = newPoint {
                    let name = nameField.trimmingCharacters(in: .whitespaces)
                    presets.add(name: name.isEmpty ? "Preset \(presets.items.count + 1)" : name,
                                kelvin: p.k, brightness: p.b)
                    Haptics.drop()
                }
                newPoint = nil
            }
            Button("Cancel", role: .cancel) { newPoint = nil }
        } message: {
            Text("Saves this light as a circle you can tap.")
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $nameField)
            Button("Save") {
                let name = nameField.trimmingCharacters(in: .whitespaces)
                if let p = editing, !name.isEmpty { presets.rename(p.id, to: name) }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    // MARK: lamp: the light fills the screen and is also a map.
    // Left to right = warm to cool, bottom to top = 0-100% of what the power allows.
    // Tap or drag anywhere to put the light there; drag the line to change only brightness.
    private var lamp: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let here = ringPoint(W, H)
            let block = numberCenter(lineY: here.y, W, H)
            ZStack {
                Squircle(n: 4)
                    .fill(light.on
                          ? AnyShapeStyle(RadialGradient(
                                colors: [Color.white.opacity(0.45 * level + 0.35), glow, glow.opacity(0.92)],
                                center: .init(x: 0.5, y: 0.4), startRadius: 4,
                                endRadius: max(W, H) * 0.75))
                          : AnyShapeStyle(Color(white: 0.14)))
                    .brightness(light.on ? (0.45 * level - 0.2) : 0)
                    .shadow(color: light.on ? glow.opacity(0.35 * level + 0.05) : .clear, radius: 40)
                    .animation(.easeOut(duration: 0.3), value: light.level)
                    .animation(.easeOut(duration: 0.3), value: light.kelvin)
                    .contentShape(Squircle(n: 4))
                    .gesture(pointGesture(W, H))

                if light.on {
                    // the brightness line: a hairline with the ring sitting on it (no line inside the ring),
                    // kept inside the lamp's outline
                    GapLine(y: here.y, gapX: here.x, gap: 14)
                        .stroke(hairline, lineWidth: 1)
                        .mask(Squircle(n: 4).padding(10))
                        .allowsHitTesting(false)

                    // where you are now: same stroke as the line
                    Circle().stroke(hairline, lineWidth: 1)
                        .frame(width: 28, height: 28)
                        .scaleEffect(axis != 0 ? 1.15 : 1)
                        .position(here)
                        .allowsHitTesting(false)

                    // grab anywhere along the line to change only the brightness
                    Color.clear
                        .frame(width: W, height: 40)
                        .contentShape(Rectangle())
                        .position(x: W / 2, y: here.y)
                        .gesture(lineGesture(W, H))
                        .accessibilityElement()
                        .accessibilityLabel("Brightness")
                        .accessibilityValue("\(light.level) percent")
                        .accessibilityAdjustableAction { dir in
                            light.setLevel(light.level + (dir == .increment ? 5 : -5))
                        }
                }

                // the big number in the middle, rolling as it changes, with the preset's name under it
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(bigValue)
                            .font(.system(size: 84, weight: .ultraLight)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(light.level)))
                        Text(bigUnit).font(.system(size: 24, weight: .light))
                    }
                    Text(activePreset?.name ?? " ")
                        .font(.system(size: 26, weight: .light))
                        .opacity(activePreset == nil ? 0 : 0.85)
                        .contentTransition(.opacity)
                }
                .animation(.snappy(duration: 0.28), value: light.level)
                .animation(.easeOut(duration: 0.3), value: activePreset?.id)
                .foregroundStyle(light.on ? ink.opacity(0.55) : Color.white.opacity(0.35))
                .scaleEffect(axis != 0 ? 1.08 : 1)
                .position(block)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: block)
                .allowsHitTesting(false)

                // presets, each at its own spot
                ForEach(presets.items) { p in
                    let at = movingID == p.id ? (movePoint ?? dotSpot(p, W, H)) : dotSpot(p, W, H)
                    presetDot(p, at: at, block: block, W, H)
                        .position(at)
                }
            }
            // follow the finger exactly while dragging; glide only when a value changes on its own
            .animation(live == nil && movingID == nil ? .snappy(duration: 0.28) : nil, value: here)
            .animation(movingID == nil ? .snappy(duration: 0.28) : nil, value: presets.items)
            .coordinateSpace(name: "lamp")
        }
        .animation(.easeOut(duration: 0.4), value: light.on)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: axis)
    }

    static func fmt(_ w: Double) -> String { w == w.rounded() ? String(Int(w)) : String(format: "%.1f", w) }

    // the preset the light is set to right now, if any
    private var activePreset: Preset? {
        guard light.on else { return nil }
        if let id = movingID { return presets.items.first { $0.id == id } }
        return presets.items.first { abs($0.kelvin - light.kelvin) <= 60 && light.actual($0.brightness) == light.brightness }
    }

    // the ring: under the finger while dragging; centred on a preset when the light is set to it
    private func ringPoint(_ W: CGFloat, _ H: CGFloat) -> CGPoint {
        if let live { return live }
        if movingID != nil, let mp = movePoint { return mp }      // a preset being dragged previews on the light
        if let p = activePreset { return dotSpot(p, W, H) }
        return spot(kelvin: light.kelvin, brightness: light.level, W, H)
    }

    // map warmth/brightness to a point on the lamp
    private func spot(kelvin k: Int, brightness b: Int, _ W: CGFloat, _ H: CGFloat) -> CGPoint {
        let kx = CGFloat(k - 2900) / 4100
        let by = CGFloat(b) / 100
        return clamp(CGPoint(x: Self.M + kx * (W - 2 * Self.M), y: Self.M + (1 - by) * (H - 2 * Self.M)), W, H)
    }
    private func dotSpot(_ p: Preset, _ W: CGFloat, _ H: CGFloat) -> CGPoint {
        spot(kelvin: p.kelvin, brightness: p.brightness, W, H)
    }
    // keep a point inside the lamp's rounded outline (a slightly smaller superellipse)
    private func clamp(_ p: CGPoint, _ W: CGFloat, _ H: CGFloat, margin: CGFloat = M) -> CGPoint {
        clamp(p, W, H, mx: margin, my: margin)
    }
    private func clamp(_ p: CGPoint, _ W: CGFloat, _ H: CGFloat, mx: CGFloat, my: CGFloat) -> CGPoint {
        let cx = W / 2, cy = H / 2, a = max(1, W / 2 - mx), b = max(1, H / 2 - my)
        var u = Double((p.x - cx) / a), v = Double((p.y - cy) / b)
        let r = pow(pow(abs(u), 4) + pow(abs(v), 4), 0.25)
        if r > 1 { u /= r; v /= r }
        return CGPoint(x: cx + CGFloat(u) * a, y: cy + CGFloat(v) * b)
    }

    // where a circle's name goes: under it, or above it near the bottom, always inside the lamp
    private func labelOffset(_ text: String, at p: CGPoint, gap: CGFloat, _ W: CGFloat, _ H: CGFloat) -> CGSize {
        let half = CGFloat(text.count) * 3.4 + 6          // about half the text width at 11pt
        func fits(_ c: CGPoint) -> Bool {
            let a = W / 2 - half - 4, b = H / 2 - 12
            guard a > 0, b > 0 else { return false }
            return pow(abs(Double((c.x - W / 2) / a)), 4) + pow(abs(Double((c.y - H / 2) / b)), 4) <= 1
        }
        let below = CGPoint(x: p.x, y: p.y + gap), above = CGPoint(x: p.x, y: p.y - gap)
        var c = (fits(below) || !fits(above)) && p.y < H * 0.82 ? below : above
        if !fits(c) { c = clamp(c, W, H, mx: half + 4, my: 12) }   // slide it in from the edge
        return CGSize(width: c.x - p.x, height: c.y - p.y)
    }

    // the big number + name sit in the middle, stepping above or below the line so it never crosses them
    private static let blockHalf = CGSize(width: 105, height: 62)
    private func numberCenter(lineY: CGFloat, _ W: CGFloat, _ H: CGFloat) -> CGPoint {
        let mid = H * 0.5, clear = Self.blockHalf.height + 22
        guard light.on, abs(lineY - mid) < clear else { return CGPoint(x: W / 2, y: mid) }
        let y = lineY > mid ? lineY - clear : lineY + clear
        return CGPoint(x: W / 2, y: min(H - clear, max(clear, y)))
    }

    private func presetDot(_ p: Preset, at: CGPoint, block: CGPoint, _ W: CGFloat, _ H: CGFloat) -> some View {
        let moving = movingID == p.id
        let label = moving ? "\(p.kelvin)K · \(p.brightness)%" : p.name
        let off = labelOffset(label, at: at, gap: moving ? 34 : 26, W, H)
        // a small name hides when the big name already shows it, or when it would sit under the big text
        let lc = CGPoint(x: at.x + off.width, y: at.y + off.height)
        let lw = CGFloat(label.count) * 3.4 + 6
        // half the width of the big text: digits at 84pt plus "%", or the name at 26pt
        let numW = CGFloat(bigValue.count) * 47 + 24, nameW = CGFloat(activePreset?.name.count ?? 0) * 13
        let hw = max(numW, nameW) / 2 + 6
        let underBig = abs(lc.x - block.x) < hw + lw && abs(lc.y - block.y) < Self.blockHalf.height + 8
        let showLabel = moving || (activePreset?.id != p.id && !underBig)
        return ZStack {
            Circle()
                .fill(kelvinColor(p.kelvin))
                .frame(width: moving ? 32 : 20, height: moving ? 32 : 20)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: ink.opacity(moving ? 0.35 : 0.25), radius: moving ? 10 : 3, y: moving ? 4 : 1)
                .frame(width: 44, height: 44)              // the only tappable area: the circle itself
                .contentShape(Circle())
                .contentShape(.contextMenuPreview, Circle())
                .onTapGesture {
                    Haptics.soft()
                    light.applyMoment(on: true, brightness: p.brightness, kelvin: p.kelvin)
                }
                .highPriorityGesture(moveGesture(p, W, H))
                .contextMenu {
                    Button { editing = p; nameField = p.name; showRename = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { presets.remove(p.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityLabel(p.name)
                .accessibilityHint("Drag to move. Press and hold to rename or delete.")
            Text(label)
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(light.on ? ink.opacity(0.6) : Color.white.opacity(0.45))
                .fixedSize()
                .offset(off)
                .opacity(showLabel ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: showLabel)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: moving)
    }

    // drag a preset: it stays under the finger the whole way (a short tap still applies it)
    private func moveGesture(_ p: Preset, _ W: CGFloat, _ H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("lamp"))
            .onChanged { drag in
                if movingID != p.id {                      // picked up
                    movingID = p.id; lastTick = nil
                    moveStart = dotSpot(p, W, H)
                    Haptics.pickup()
                }
                guard let start = moveStart else { return }
                let pt = clamp(CGPoint(x: start.x + drag.translation.width,
                                       y: start.y + drag.translation.height), W, H)
                movePoint = pt
                let (k, b) = unspot(pt, W, H)
                if presets.v(p.id) != [k, b] {
                    presets.set(p.id, kelvin: k, brightness: b)
                    light.setPoint(kelvin: k, level: b)           // preview it on the light
                    tickIfNeeded(k / 250 * 1000 + b / 5, edge: false)
                }
            }
            .onEnded { _ in
                if movingID == p.id { presets.save(); Haptics.drop() }
                movingID = nil; moveStart = nil; movePoint = nil
            }
    }

    // a point on the lamp -> warmth/brightness (the inverse of spot)
    private func unspot(_ p: CGPoint, _ W: CGFloat, _ H: CGFloat) -> (Int, Int) {
        let kx = min(1, max(0, Double((p.x - Self.M) / (W - 2 * Self.M))))
        let by = min(1, max(0, 1 - Double((p.y - Self.M) / (H - 2 * Self.M))))
        let k = Int(((2900 + kx * 4100) / 50).rounded()) * 50
        let b = max(1, Int((by * 100).rounded()))
        return (k, b)
    }

    private var bigValue: String { light.on ? "\(light.level)" : "Off" }
    private var bigUnit: String { light.on ? "%" : "" }

    // tap or drag on the light: put it at that point (warmth by side, brightness by height).
    // Press and hold without moving: save that spot as a new preset.
    private func pointGesture(_ W: CGFloat, _ H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lamp"))
            .onChanged { g in
                guard light.connected || light.cached || light.demo else { return }
                if axis == 0 {
                    axis = 1; lastTick = nil; Haptics.tap()
                    pressStart = g.startLocation; pressMoved = false
                    pressTask?.cancel()
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 550_000_000)
                        guard !Task.isCancelled, !pressMoved, let s = pressStart else { return }
                        let (k, b) = unspot(clamp(s, W, H), W, H)
                        newPoint = (k, b); nameField = ""
                        Haptics.pickup()
                        showNew = true
                    }
                }
                if let s = pressStart, hypot(g.location.x - s.x, g.location.y - s.y) > 10 {
                    pressMoved = true; pressTask?.cancel()
                }
                let p = clamp(g.location, W, H)
                live = p
                let (k, r) = unspot(p, W, H)
                light.setPoint(kelvin: k, level: r)
                tickIfNeeded(k / 250 * 1000 + r / 5, edge: false)
            }
            .onEnded { _ in
                pressTask?.cancel(); pressStart = nil
                endDrag()
            }
    }

    // drag the line: brightness only, all the way to the bottom
    private func lineGesture(_ W: CGFloat, _ H: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lamp"))
            .onChanged { g in
                guard light.connected || light.cached || light.demo else { return }
                let x = live?.x ?? ringPoint(W, H).x
                if axis == 0 { axis = 1; lastTick = nil; Haptics.prepare() }
                let p = clamp(CGPoint(x: x, y: g.location.y), W, H)
                live = p
                let (_, r) = unspot(p, W, H)
                light.setLevel(r)
                tickIfNeeded(light.level / 5, edge: light.level <= 5 || light.level == 100)
            }
            .onEnded { _ in endDrag() }
    }

    private func endDrag() {
        live = nil                                  // the ring settles onto the real value
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.4)) { axis = 0 }
    }

    private func tickIfNeeded(_ bucket: Int, edge: Bool) {
        guard bucket != lastTick else { return }
        lastTick = bucket
        edge ? Haptics.edge() : Haptics.tick()
    }

    // MARK: chrome
    private var header: some View {
        HStack {
            Text("Softbox").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            if light.demo {
                Text("Demo").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .accessibilityLabel("Demo mode: the light isn't on this network, nothing is sent")
                    .transition(.opacity)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Settings")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(light).environmentObject(bridge)
                .presentationDetents([.large])
        }
    }
    private var footerText: String {
        var t = "\(light.kelvin)K"
        if light.maxBrightness < 100 {
            t += "   ·   max \(light.maxBrightness)%" + (light.watts.map { " on \(Self.fmt($0))W" } ?? "")
        }
        return t
    }
    // under the lamp: the Off circle, then the small print
    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.soft()
                light.applyMoment(on: false, brightness: nil, kelvin: nil)
            } label: {
                Circle().fill(Color(white: light.on ? 0.22 : 0.3))
                    .overlay(Circle().strokeBorder(.white.opacity(light.on ? 0.35 : 0.6), lineWidth: 1))
                    .frame(width: 20, height: 20)
                    .frame(width: 44, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Off")
            Text(light.connected || light.cached || light.demo ? (light.on ? footerText : "Standby") : "")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.top, 10)
    }

    // shown only until the light answers for the first time: the lamp and its dot, no words
    private var connectOverlay: some View {
        ZStack {
            Color(red: 0.055, green: 0.059, blue: 0.071)
            // dead centre, same size and resting state as the launch screen, so it flows straight in
            LampLoader()
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

// A horizontal hairline across the lamp with a hole where the ring sits
struct GapLine: Shape {
    var y: CGFloat
    var gapX: CGFloat
    var gap: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(y, gapX) }
        set { y = newValue.first; gapX = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = max(r.minX, gapX - gap), b = min(r.maxX, gapX + gap)
        if a > r.minX { p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: a, y: y)) }
        if b < r.maxX { p.move(to: CGPoint(x: b, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y)) }
        return p
    }
}

// A word with a soft light passing over it
struct ShimmerText: View {
    let text: String
    @State private var start = Date()
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 2.4) / 2.4
            let p = -0.4 + 1.8 * t
            label
                .foregroundStyle(.white.opacity(0.3))
                .overlay(
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)],
                                   startPoint: UnitPoint(x: p - 0.3, y: 0.5),
                                   endPoint: UnitPoint(x: p + 0.3, y: 0.5))
                        .mask(label)
                )
        }
        .accessibilityLabel(text)
    }
    private var label: some View {
        Text(text).font(.system(size: 13, weight: .medium)).kerning(0.1)
    }
}

// MARK: - Settings: only what works from here (Mac-only parts appear when the Mac answers)
struct SettingsView: View {
    @EnvironmentObject var light: LightController
    @EnvironmentObject var bridge: BridgeController
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [AutomationLog.Run] = []
    private let accent = Color(red: 1.0, green: 0.84, blue: 0.63)
    private let green = Color(red: 0.37, green: 0.73, blue: 0.55)

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.075, blue: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Settings").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button("Done") { dismiss() }.foregroundStyle(accent)
                    }
                    .padding(.bottom, 22)

                    sectionTitle("Automations")
                    Text("Use the light in any automation.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 14)
                    ShortcutsLink()                       // Apple's button (fixed size): opens Softbox in Shortcuts

                    // the six light animations, each shown live on a little lamp; tap to play it on the light
                    sectionTitle("Effects").padding(.top, 28)
                    Text("Tap to play on the light. Pick any of them in Shortcuts.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 12)
                    EffectGrid { fx in Haptics.soft(); light.play(fx) }

                    // what your automations did: iOS doesn't let apps read the automations themselves,
                    // so the app keeps a note each time one of its actions runs
                    sectionTitle("Recent runs").padding(.top, 28)
                    if runs.isEmpty {
                        Text("Nothing yet.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(runs) { r in
                                HStack {
                                    Text(r.what).font(.system(size: 15))
                                    Spacer()
                                    Text(r.date, format: .relative(presentation: .named))
                                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                                }
                                .padding(.vertical, 12)
                                if r.id != runs.last?.id { Divider().overlay(Color.white.opacity(0.08)) }
                            }
                        }
                    }

                    // runs on the Mac, so it shows only when the Mac answers
                    if bridge.found {
                        sectionTitle("Rhythm").padding(.top, 28)
                        Toggle(isOn: Binding(get: { bridge.daylight }, set: { bridge.setDaylight($0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daylight").font(.system(size: 15, weight: .medium))
                                Text("Cool by day, warm by evening").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            }
                        }.tint(green)
                    }

                    Text(powerText)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 36)

                    Button("Reset presets") { PresetStore.shared.reset(); Haptics.soft() }
                        .font(.system(size: 13)).foregroundStyle(accent).padding(.top, 18)
                }
                .padding(22)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { runs = AutomationLog.recent() }
        .task { await bridge.load() }
    }

    private var powerText: String {
        let src = light.watts.map { "\(ContentView.fmt($0))W USB power" } ?? "USB power"
        if light.maxBrightness >= 100 { return "\(src). Full brightness available." }
        return "Max \(light.maxBrightness)% on \(src). 30W USB-C gives full light."
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45)).kerning(0.5).padding(.bottom, 4)
    }
}

// Six cards, each with a small lamp looping its effect, the way the real light moves
struct EffectGrid: View {
    var onPick: (Effect) -> Void
    @State private var start = Date()
    @State private var playing: Effect? = nil
    private let accent = Color(red: 1.0, green: 0.84, blue: 0.63)

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(Effect.allCases.enumerated()), id: \.element) { i, fx in
                    let f = EffectPreview.frame(fx, t + Double(i) * 0.45)
                    Button {
                        playing = fx; onPick(fx)
                        let id = fx
                        DispatchQueue.main.asyncAfter(deadline: .now() + EffectPreview.length(fx)) {
                            if playing == id { playing = nil }
                        }
                    } label: {
                        VStack(spacing: 10) {
                            EffectPreview.lamp(level: f.level, warmth: f.warmth)
                            Text(fx.label).font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(playing == fx ? 1 : 0.8))
                        }
                        .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 12)
                        .background(Color.white.opacity(playing == fx ? 0.1 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(playing == fx ? accent.opacity(0.8) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(fx.label)
                }
            }
        }
    }
}

enum EffectPreview {
    // one loop: the effect as the light plays it, then a short rest
    static func length(_ e: Effect) -> Double {
        switch e { case .breath: 7 }
    }
    private static func swell(_ x: Double) -> Double { (1 - cos(x * 2 * .pi)) / 2 }      // 0 -> 1 -> 0
    private static func ease(_ x: Double) -> Double { (1 - cos(x * .pi)) / 2 }
    // eased glide through (time, level) keyframes; holds the last level after the end
    private static func keys(_ k: [(Double, Double)], _ t: Double) -> Double {
        for i in 1..<k.count where t <= k[i].0 {
            let (t0, v0) = k[i - 1], (t1, v1) = k[i]
            return v0 + (v1 - v0) * ease((t - t0) / (t1 - t0))
        }
        return k.last!.1
    }

    // level 0...1 of the lamp's resting glow, warmth 0 (as is) ... 1 (warmest)
    static func frame(_ e: Effect, _ time: Double) -> (level: Double, warmth: Double) {
        let t = time.truncatingRemainder(dividingBy: length(e))
        switch e {
        // three soft beats, 10% up and back, then a rest
        case .breath:
            guard t < 5.7 else { return (0.62, 0) }
            return (0.62 + 0.28 * swell(t.truncatingRemainder(dividingBy: 1.9) / 1.9), 0)    // three slow, even beats
        }
    }

    // a small lamp in the app's shape, glowing at that level and warmth
    static func lamp(level: Double, warmth: Double) -> some View {
        let k = Int(5200 - 2300 * warmth)
        let c = kelvinColor(k)
        return ZStack {
            Squircle(n: 4)
                .fill(RadialGradient(colors: [Color.white.opacity(0.85), c, c.opacity(0.9)],
                                     center: .init(x: 0.5, y: 0.4), startRadius: 1, endRadius: 30))
                .frame(width: 26, height: 36)
                .brightness(-0.6 * (1 - level))
                .shadow(color: c.opacity(0.6 * level), radius: 12 * level + 1)
        }
        .frame(height: 44)
    }
}

// The "chubby square": a superellipse |x/a|^n + |y/b|^n = 1 (same shape as the app icon)
struct Squircle: Shape {
    var n: Double = 4
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = Double(r.width) / 2, b = Double(r.height) / 2
        let steps = 240
        for i in 0..<steps {
            let t = 2 * Double.pi * Double(i) / Double(steps)
            let c = cos(t), s = sin(t)
            let x = a * copysign(pow(abs(c), 2 / n), c)
            let y = b * copysign(pow(abs(s), 2 / n), s)
            let pt = CGPoint(x: Double(r.midX) + x, y: Double(r.midY) + y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// Haptics: a light tick while dragging, a firmer one at the ends, a tap for on/off
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    static func prepare() { selection.prepare(); rigid.prepare() }
    static func tick() { selection.selectionChanged() }
    static func edge() { rigid.impactOccurred(intensity: 0.8) }
    static func tap() { light.impactOccurred() }
    static func soft() { softGen.impactOccurred() }
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    static func pickup() { medium.impactOccurred(intensity: 0.9) }
    static func drop() { softGen.impactOccurred(intensity: 0.7) }
}

// The loader: the app icon's lamp with its dot. The dot wanders over the lamp and the lamp follows it,
// warmth across and brightness up, then comes back to rest exactly where the icon and launch screen show it.
// Driven by the clock (not a repeating animation) so it never hitches while the app starts up.
struct LampLoader: View {
    @State private var start = Date()
    private static let rest: (Double, Double) = (-0.22, 0.17)
    private static let keys: [(Double, Double, Double)] = [
        (0, -0.22, 0.17), (1.4, -0.22, 0.17), (2.8, -0.5, 0.42), (4.6, 0.45, -0.42), (6.2, 0.05, -0.05), (7.4, -0.22, 0.17)]
    private static let base: [[Double]] = [[255, 247, 238], [255, 214, 168], [240, 176, 117]]

    private static func rgb(_ k: Double) -> [Double] {
        let t = k / 100
        var r, g, b: Double
        if t <= 66 { r = 255; g = 99.47 * log(t) - 161.1; b = t <= 19 ? 0 : 138.5 * log(t - 10) - 305.0 }
        else { r = 329.7 * pow(t - 60, -0.1332); g = 288.1 * pow(t - 60, -0.0755); b = 255 }
        return [r, g, b].map { min(255, max(1, $0)) }
    }
    private static func kelvin(_ u: Double) -> Double { 2900 + (u + 1) / 2 * 4100 }
    private static func level(_ v: Double) -> Double { (1 - v) / 2 }
    private static func smooth(_ x: Double) -> Double { x <= 0 ? 0 : x >= 1 ? 1 : (1 - cos(x * .pi)) / 2 }
    private static func at(_ t: Double) -> (Double, Double) {
        let t = t.truncatingRemainder(dividingBy: 7.4)
        for i in 1..<keys.count where t <= keys[i].0 {
            let a = keys[i - 1], b = keys[i], f = smooth((t - a.0) / (b.0 - a.0))
            return (a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
        }
        return rest
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let (u, v) = Self.at(tl.date.timeIntervalSince(start))
            let c = Self.rgb(Self.kelvin(u)), cr = Self.rgb(Self.kelvin(Self.rest.0))
            let L = Self.level(v), Lr = Self.level(Self.rest.1)
            let f = 0.86 * min(1.2, max(0.62, 0.72 + 0.28 * L / Lr))   // 0.86 at rest, like the launch screen
            let stops = Self.base.map { s in
                Color(red: min(255, s[0] * c[0] / cr[0] * f) / 255,
                      green: min(255, s[1] * c[1] / cr[1] * f) / 255,
                      blue: min(255, s[2] * c[2] / cr[2] * f) / 255)
            }
            let glow = Color(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255)
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [glow.opacity(0.45), glow.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 230, height: 270)
                    .opacity(min(1, max(0.2, 0.35 + 0.9 * (L - Lr))))
                ZStack {
                    Squircle(n: 4)
                        .fill(RadialGradient(colors: stops, center: .init(x: 0.5, y: 0.4), startRadius: 2, endRadius: 80))
                    Circle()
                        .stroke(Color(red: 0.55, green: 0.37, blue: 0.22).opacity(0.66), lineWidth: 0.8)
                        .frame(width: 12.2, height: 12.2)
                        .offset(x: u * 36, y: v * 52)
                }
                .frame(width: 72, height: 104)
                .scaleEffect(0.96 + 0.08 * (L - Lr))
            }
            .drawingGroup()
        }
        .accessibilityLabel("Connecting")
    }
}

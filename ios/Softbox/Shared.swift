import Foundation

// What the app and the home-screen widget share: where the light is and how it last looked.
// Both read and write the same App Group, so the widget can draw the lamp without the app running.
enum Shared {
    // set once in the project's APP_GROUP build setting; it reaches here through Info.plist
    static let group = (Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String) ?? "group.com.example.softbox"
    static let defaults: UserDefaults = UserDefaults(suiteName: group) ?? .standard
    static let widgetKind = "SoftboxLamp"

    // one time: bring over what older builds kept in the app's own defaults
    static func migrate() {
        guard defaults !== UserDefaults.standard, defaults.object(forKey: "migrated") == nil else { return }
        for k in ["lightHost", "lightIP", "lastLight"] {
            if let v = UserDefaults.standard.object(forKey: k) { defaults.set(v, forKey: k) }
        }
        defaults.set(true, forKey: "migrated")
    }
}

// The light as last seen. Brightness is the light's own 1-100; maxBrightness is what the power allows.
struct LampState: Equatable {
    var on = true
    var brightness = 40
    var kelvin = 4300
    var maxBrightness = 100

    // 0...1 of what the power allows, the same scale the app's dot uses
    var level: Double { min(1, max(0.01, Double(brightness) / Double(max(1, maxBrightness)))) }

    static func load() -> LampState {
        var s = LampState()
        guard let c = Shared.defaults.dictionary(forKey: "lastLight") else { return s }
        if let v = c["on"] as? Bool { s.on = v }
        if let v = c["brightness"] as? Int { s.brightness = max(1, min(100, v)) }
        if let v = c["kelvin"] as? Int { s.kelvin = max(2900, min(7000, v)) }
        if let v = c["maxBrightness"] as? Int { s.maxBrightness = max(1, min(100, v)) }
        return s
    }
    func save() {
        Shared.defaults.set(["on": on, "brightness": brightness, "kelvin": kelvin, "maxBrightness": maxBrightness],
                            forKey: "lastLight")
    }
}

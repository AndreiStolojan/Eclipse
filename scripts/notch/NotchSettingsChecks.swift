import Foundation

/// Loads hand-written settings blobs from a throwaway defaults suite: out-of-range numbers are clamped, the rest kept.
@main
struct NotchSettingsChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }
        let suite = "ro.andrei.NotchLab.SettingsChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("No defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        func load(_ json: String) -> NotchSettings {
            defaults.set(Data(json.utf8), forKey: NotchSettings.key)
            return NotchSettings.load(from: defaults)
        }

        let defaultSettings = NotchSettings()
        check(NotchSettings.ranges.allSatisfy { $1.contains(defaultSettings[keyPath: $0]) }, "Every default is in its range")
        let absurd = load(#"{"clipboardLimit":1e30,"hudDuration":-5,"expandedWidth":1e308,"lockScreenWidgetOffset":-1e9}"#)
        check(absurd.clipboardLimit == 50 && absurd.hudDuration == 0.5 && absurd.expandedWidth == 600
              && absurd.lockScreenWidgetOffset == -160, "Out-of-range numbers clamp to the slider ends")
        let valid = load(#"{"clipboardLimit":25,"hudDuration":2.3,"haptics":false,"accentHex":"FF0000"}"#)
        check(valid.clipboardLimit == 25 && valid.hudDuration == 2.3 && !valid.haptics && valid.accentHex == "FF0000"
              && valid.peekDuration == defaultSettings.peekDuration, "Valid values are kept and missing keys take defaults")
        let malformed = load(#"{"clipboardLimit":"many","haptics":null,"waveStyle":"unknown","accentHex":"FF0000","downloadAlerts":true}"#)
        check(malformed.clipboardLimit == defaultSettings.clipboardLimit && malformed.haptics == defaultSettings.haptics
              && malformed.waveStyle == defaultSettings.waveStyle && malformed.accentHex == "FF0000" && malformed.downloadAlerts,
              "Wrong types, nulls and unknown enum values reset only their own fields")
        let nested = load(#"{"display":{"display":{"id":"monitor"}},"clipboardLimit":25}"#)
        check(nested.display == defaultSettings.display && nested.clipboardLimit == 25,
              "An incomplete associated enum falls back without losing unrelated settings")
        check(load("not JSON") == defaultSettings, "An unreadable settings document falls back to defaults")
        print("\(checks) settings checks passed")
    }
}

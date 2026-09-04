//
//  Settings.swift
//
// ALVR server-side settings decoded from JSON.
//
import Foundation

enum SettingsError: Error {
    case badJson
}

struct SettingsCodables {
    struct AlphaStreamConfig: Codable {
        @DefaultFalse var premultiplied_alpha: Bool
    }

    // Only the AlphaStream variant is decoded here; the other passthrough modes are handled
    // entirely client side. Serde writes enum variants as a single keyed object, so any other mode
    // simply leaves AlphaStream nil.
    struct PassthroughConfig: Codable {
        let AlphaStream: AlphaStreamConfig?
    }

    struct VideoConfig: Codable {
        @OptionSwitch var foveated_encoding: FoveationSettings?
        @OptionSwitch var passthrough: PassthroughConfig?
    }
    
    //
    // Headset
    //
    struct HandSkeletonConfig: Codable {
        @DefaultFalse var steamvr_input_2_0: Bool
    }
    
    struct HandTrackingInteraction: Codable {
        @DefaultFalse var only_touch: Bool
    }
    
    struct ControllersConfig: Codable {
        @DefaultTrue var tracked: Bool
        //@DefaultTrue var enable_skeleton: Bool
        @DefaultFalse var multimodal_tracking: Bool
        @DefaultEmptyArray var left_controller_position_offset: [Float]
        @DefaultEmptyArray var left_controller_rotation_offset: [Float]
        @DefaultEmptyArray var left_hand_tracking_position_offset: [Float]
        @DefaultEmptyArray var left_hand_tracking_rotation_offset: [Float]
        @OptionSwitch var hand_skeleton: HandSkeletonConfig?
        @OptionSwitch var hand_tracking_interaction: HandTrackingInteraction?
        @DefaultEmptyString var emulation_mode: String
    }
    
    struct HeadsetConfig: Codable {
        @OptionSwitch var controllers: ControllersConfig?
    }

    //
    // Extra
    //

    // Mirrors alvr_common::LogSeverity. Serde writes the unit variants as plain strings.
    enum LogSeverity: String, Codable {
        case Debug
        case Info
        case Warning
        case Error
    }

    struct LoggingConfig: Codable {
        // Switch<LogSeverity>: "Disabled", or {"Enabled": "Info"}. nil means the streamer is not
        // collecting client logs at all.
        @OptionSwitch var client_log_report_level: LogSeverity?
    }

    struct ExtraConfig: Codable {
        let logging: LoggingConfig?
    }

    struct Settings: Codable {
        let video: VideoConfig
        let headset: HeadsetConfig
        // Optional so that a streamer which omits or renames the block cannot fail the whole
        // settings decode and take the alpha configuration down with it.
        let extra: ExtraConfig?
    }
}

struct Settings {
    private init() {}
    
    static var _cached: SettingsCodables.Settings?

    private static func parseSettingsJsonCString<T: Decodable>(getJson: (UnsafeMutablePointer<CChar>?) -> UInt64, type: T.Type) -> T? {
        let len = getJson(nil)
        if len == 0 {
            return nil
        }

        let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: Int(len))
        defer { buffer.deallocate() }

        _ = getJson(buffer.baseAddress)
        let data = Data(bytesNoCopy: buffer.baseAddress!, count: Int(len) - 1, deallocator: .none)
        
        // Helper to see/debug JSON
        /*if let utf8String = String(bytes: data, encoding: .utf8) {
            print(utf8String.trimmingCharacters(in: ["\0"]))
        }*/
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        }
        catch {
            return nil
        }
    }

    public static func getAlvrSettings() -> SettingsCodables.Settings? {
        if Settings._cached != nil {
            return Settings._cached
        }

        let val = parseSettingsJsonCString(getJson: alvr_get_settings_json, type: SettingsCodables.Settings.self)
        Settings._cached = val
        return val
    }
    
    public static func clearSettingsCache() {
        Settings._cached = nil
        Settings._cachedVerboseDiagnostics = nil
    }

    static var _cachedVerboseDiagnostics: Bool?

    // Whether to emit the alpha-pairing and decoder-identity diagnostics, driven by the streamer's
    // Settings -> Extra -> Logging -> client log report level. Info or Debug turns them on.
    //
    // Deliberately not a separate client-side toggle: this same value also decides whether
    // alvr_log output survives the filter in the client core's logging backend, so a client-only
    // switch would produce diagnostics that are "on" yet still invisible. One setting, one
    // behaviour. Read per frame, so the result is cached until the settings cache is cleared.
    //
    // Settings only exist after the stream config arrives, so anything logged before connection
    // sees false and should use print() if it needs to be seen.
    public static var verboseDiagnostics: Bool {
        if let cached = Settings._cachedVerboseDiagnostics {
            return cached
        }
        let level = getAlvrSettings()?.extra?.logging?.client_log_report_level
        let enabled = (level == .Info || level == .Debug)
        Settings._cachedVerboseDiagnostics = enabled
        return enabled
    }
}

import Foundation

// MARK: - Zone

public struct Zone: Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var state: PlaybackState
    public var outputs: [Output]
    public var nowPlaying: NowPlaying?
    public var seekPosition: Double?    // seconds

    public init(from dict: [String: Any]) {
        id = dict["zone_id"] as? String ?? ""
        displayName = dict["display_name"] as? String ?? "Unknown Zone"
        let stateStr = dict["state"] as? String ?? ""
        state = PlaybackState(rawValue: stateStr) ?? .stopped
        outputs = (dict["outputs"] as? [[String: Any]] ?? []).map(Output.init)
        if let np = dict["now_playing"] as? [String: Any] {
            nowPlaying = NowPlaying(from: np)
        }
        if let seek = dict["now_playing"] as? [String: Any],
           let pos = seek["seek_position"] as? Double {
            seekPosition = pos
        }
    }
}

public enum PlaybackState: String, Sendable {
    case playing, paused, loading, stopped
    public var icon: String {
        switch self {
        case .playing: "play.fill"
        case .paused: "pause.fill"
        case .loading: "ellipsis"
        case .stopped: "stop.fill"
        }
    }
}

// MARK: - Output

public struct Output: Identifiable, Equatable, Sendable {
    public let id: String
    public let zoneID: String
    public var displayName: String
    public var volume: VolumeInfo?

    public init(from dict: [String: Any]) {
        id = dict["output_id"] as? String ?? ""
        zoneID = dict["zone_id"] as? String ?? ""
        displayName = dict["display_name"] as? String ?? "Unknown Output"
        if let vol = dict["volume"] as? [String: Any] {
            volume = VolumeInfo(from: vol)
        }
    }
}

// MARK: - VolumeInfo

public struct VolumeInfo: Equatable, Sendable {
    public var value: Int
    public var min: Int
    public var max: Int
    public var step: Int
    public var isMuted: Bool

    public init(from dict: [String: Any]) {
        value = dict["value"] as? Int ?? 0
        min = dict["min"] as? Int ?? 0
        max = dict["max"] as? Int ?? 100
        step = dict["step"] as? Int ?? 1
        isMuted = dict["is_muted"] as? Bool ?? false
    }
}

// MARK: - NowPlaying

public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var imageKey: String?
    public var length: Int?

    public init(from dict: [String: Any]) {
        let oneline = dict["one_line"] as? [String: Any]
        let twoline = dict["two_line"] as? [String: Any]
        let threeline = dict["three_line"] as? [String: Any]
        title = threeline?["line1"] as? String
            ?? twoline?["line1"] as? String
            ?? oneline?["line1"] as? String
            ?? ""
        artist = threeline?["line2"] as? String ?? twoline?["line2"] as? String
        album = threeline?["line3"] as? String
        imageKey = dict["image_key"] as? String
        length = dict["length"] as? Int
    }
}

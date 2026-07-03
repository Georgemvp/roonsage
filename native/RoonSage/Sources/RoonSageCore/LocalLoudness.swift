import Foundation

/// Loudness normalization for on-device playback, applied as a per-track gain
/// on the local `AVPlayer`. The analyzer measures K-weighted LUFS (BS.1770,
/// schema v28); this maps that measurement to a playback volume:
///
///     gain(dB) = target − LUFS + pre-amp        volume = 10^(gain/20)
///
/// `AVPlayer.volume` cannot boost past unity, so normalization only attenuates
/// (tracks quieter than the target play at full volume). That keeps the loud
/// modern masters in line with the quiet dynamic ones, which is where the
/// annoyance lives. Tracks without a LUFS measurement are assumed to be a loud
/// modern master (`assumedLufsWhenUnknown`) so they don't blast out between
/// normalized neighbours.
public enum LocalLoudness {
    public enum Mode: String, CaseIterable, Sendable {
        case off      // unity gain, engine untouched
        case track    // normalize each track to the target
        case album    // normalize on the album's mean LUFS (preserves intra-album dynamics)
    }

    /// Normalization target. −14 LUFS matches the common streaming loudness.
    public static let targetLufs: Double = -14
    /// LUFS assumed for tracks the analyzer hasn't measured (loud master).
    public static let assumedLufsWhenUnknown: Double = -9

    static let modeKey = "local_loudness_mode"
    static let preampKey = "local_loudness_preamp_db"

    public static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// User pre-amp in dB, clamped to ±12.
    public static var preampDB: Double {
        get { max(-12, min(12, UserDefaults.standard.double(forKey: preampKey))) }
        set { UserDefaults.standard.set(max(-12, min(12, newValue)), forKey: preampKey) }
    }

    /// Pure gain computation (dB). `albumLufs` is the mean LUFS of the track's
    /// album; in `.album` mode it takes precedence, falling back to the track
    /// value so a lone measured track still normalizes.
    public static func gainDB(trackLufs: Double?, albumLufs: Double?,
                              mode: Mode, preampDB: Double) -> Double {
        guard mode != .off else { return 0 }
        let reference: Double = switch mode {
        case .album: albumLufs ?? trackLufs ?? assumedLufsWhenUnknown
        case .track: trackLufs ?? albumLufs ?? assumedLufsWhenUnknown
        case .off: 0 // unreachable
        }
        return targetLufs - reference + preampDB
    }

    /// Gain as an `AVPlayer.volume` value, clamped to [0, 1] (no boost).
    public static func volume(trackLufs: Double?, albumLufs: Double?,
                              mode: Mode, preampDB: Double) -> Float {
        let db = gainDB(trackLufs: trackLufs, albumLufs: albumLufs, mode: mode, preampDB: preampDB)
        return Float(max(0, min(1, pow(10, db / 20))))
    }
}

#if DEBUG
import SwiftUI
import RoonSageCore
import RoonSageUI

/// DEBUG-only host that renders the Now Playing screen with a mock zone, so its
/// layout can be captured in the simulator (real iOS rendering — unlike a macOS
/// ImageRenderer snapshot). Enabled with the `RS_PREVIEW=1` launch env var.
struct NowPlayingPreviewHost: View {
    @Environment(RoonClient.self) private var client
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            NowPlayingView()
                .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let dict: [String: Any] = [
                "zone_id": "z1", "display_name": "WIIM Receiver", "state": "playing",
                "outputs": [[
                    "output_id": "o1", "zone_id": "z1", "display_name": "WIIM Receiver",
                    "volume": ["value": 50, "min": 0, "max": 100, "step": 1, "is_muted": false],
                ]],
                "now_playing": [
                    "length": 280, "seek_position": 95.0,
                    "three_line": ["line1": "The Last Laugh (Remastered 2021)",
                                   "line2": "Mark Knopfler",
                                   "line3": "The Studio Albums 1996-2007"],
                    "image_key": "",
                ],
            ]
            client.previewLoad(
                zones: [Zone(from: dict)],
                queueTitles: [
                    (title: "The Last Laugh", subtitle: "Mark Knopfler"),
                    (title: "Golden Heart", subtitle: "Mark Knopfler"),
                ],
                selected: "z1")
        }
    }
}
#endif

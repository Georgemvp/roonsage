import SwiftUI
import RoonSageCore

struct UpdateView: View {
    let update: UpdateInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            // Title
            VStack(spacing: 6) {
                Text("Update Available")
                    .font(.title.bold())
                Text("RoonSage \(update.version) is ready to download.")
                    .foregroundStyle(.secondary)
            }

            // Release notes (if any)
            if let notes = update.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("View Release Notes") {
                    NSWorkspace.shared.open(URL(string: update.releasePageURL)!)
                }

                Button("Download") {
                    NSWorkspace.shared.open(URL(string: update.downloadURL)!)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 460)
    }
}

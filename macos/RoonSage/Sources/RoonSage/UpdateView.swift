import SwiftUI
import RoonSageCore

@MainActor
struct UpdateView: View {
    let update: UpdateInfo
    let installer: UpdateInstaller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            stateIcon

            // Title + subtitle
            VStack(spacing: 6) {
                Text(stateTitle)
                    .font(.title.bold())
                Text(stateSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Progress bar (shown while downloading)
            if case .downloading(let p) = installer.state {
                VStack(spacing: 6) {
                    ProgressView(value: p > 0 ? p : nil)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                    if p > 0 {
                        Text("\(Int(p * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Installing spinner
            if case .installing = installer.state {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Replacing app bundle…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Error detail
            if case .error(let msg) = installer.state {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            // Release notes (shown in idle state only)
            if case .idle = installer.state, let notes = update.releaseNotes, !notes.isEmpty {
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
            actionButtons
        }
        .padding(36)
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: stateTitle)
    }

    // MARK: - Dynamic content

    var stateIcon: some View {
        Group {
            switch installer.state {
            case .idle:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
            case .downloading:
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse)
            case .readyToInstall:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installing:
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(.orange)
                    .symbolEffect(.rotate.byLayer)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 56))
    }

    var stateTitle: String {
        switch installer.state {
        case .idle:             "Update Available"
        case .downloading:      "Downloading…"
        case .readyToInstall:   "Ready to Install"
        case .installing:       "Installing…"
        case .error:            "Update Failed"
        }
    }

    var stateSubtitle: String {
        switch installer.state {
        case .idle:
            "RoonSage \(update.version) is available."
        case .downloading:
            "Downloading RoonSage \(update.version)…"
        case .readyToInstall:
            "The update is downloaded. Click Install to apply it\nand relaunch RoonSage automatically."
        case .installing:
            "Do not close the app."
        case .error:
            "Something went wrong. You can install manually instead."
        }
    }

    @ViewBuilder
    var actionButtons: some View {
        HStack(spacing: 12) {
            switch installer.state {
            case .idle:
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Release Notes") {
                    if let url = URL(string: update.releasePageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Download Update") {
                    installer.download(from: update.downloadURL)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .downloading:
                Button("Cancel") {
                    installer.cancelDownload()
                }
                .keyboardShortcut(.cancelAction)

            case .readyToInstall(let dmgURL):
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Install & Relaunch") {
                    Task { await installer.install(dmgURL: dmgURL) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .installing:
                EmptyView()

            case .error:
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Install Manually") {
                    if let url = URL(string: update.downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Retry") {
                    installer.download(from: update.downloadURL)
                }
            }
        }
    }
}

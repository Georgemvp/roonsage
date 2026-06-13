import SwiftUI
import RoonSageCore
import RoonSageUI

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
                    Text("App-bundel vervangen…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Error detail
            if case .error(let msg) = installer.state {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(Color.roonDanger)
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
        .animation(Motion.quick, value: stateTitle)
    }

    // MARK: - Dynamic content

    @ViewBuilder
    var stateIcon: some View {
        if case .downloading = installer.state {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)
        } else if case .readyToInstall = installer.state {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.roonSuccess)
        } else if case .installing = installer.state {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.roonWarning)
                .symbolEffect(.pulse)
        } else if case .error = installer.state {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.roonDanger)
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.roonSuccess)
        }
    }

    var stateTitle: String {
        switch installer.state {
        case .idle:             "Update beschikbaar"
        case .downloading:      "Downloaden…"
        case .readyToInstall:   "Klaar om te installeren"
        case .installing:       "Installeren…"
        case .error:            "Update mislukt"
        }
    }

    var stateSubtitle: String {
        switch installer.state {
        case .idle:
            "RoonSage \(update.version) is beschikbaar."
        case .downloading:
            "RoonSage \(update.version) wordt gedownload…"
        case .readyToInstall:
            "De update is gedownload. Klik op Installeer om hem toe te passen\nen RoonSage automatisch te herstarten."
        case .installing:
            "Sluit de app niet af."
        case .error:
            "Er ging iets mis. Je kunt de update ook handmatig installeren."
        }
    }

    @ViewBuilder
    var actionButtons: some View {
        HStack(spacing: 12) {
            switch installer.state {
            case .idle:
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Releasenotities") {
                    if let url = URL(string: update.releasePageURL) {
                        NSWorkspace.shared.open(url)
                    }
                }

                if update.downloadURL.hasSuffix(".dmg") {
                    Button("Download update") {
                        installer.download(from: update.downloadURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Bekijk release") {
                        if let url = URL(string: update.releasePageURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

            case .downloading:
                Button("Annuleer") {
                    installer.cancelDownload()
                }
                .keyboardShortcut(.cancelAction)

            case .readyToInstall(let dmgURL):
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Installeer & herstart") {
                    Task { await installer.install(dmgURL: dmgURL) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .installing:
                EmptyView()

            case .error:
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Installeer handmatig") {
                    if let url = URL(string: update.downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Probeer opnieuw") {
                    installer.download(from: update.downloadURL)
                }
            }
        }
    }
}

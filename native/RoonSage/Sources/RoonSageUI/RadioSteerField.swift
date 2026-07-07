import RoonSageCore
import SwiftUI

/// A free-text "steer the station" field for the active-radio banner: type a
/// phrase ("avontuurlijker", "veiliger", "minder verrassing") and the running
/// station re-steers via `RoonClient.steerActiveRadio`. Unrecognised phrases
/// surface a hint toast rather than silently doing nothing.
@MainActor
struct RadioSteerField: View {
    @Environment(RoonClient.self) private var client
    @State private var text = ""

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(LS("radio.steer.placeholder"), text: $text)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .submitLabel(.send)
                .onSubmit(submit)
            Button(action: submit) { Image(systemName: "paperplane.fill") }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(LS("radio.steer.send"))
        }
    }

    private func submit() {
        let phrase = text.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return }
        Haptics.tap()
        text = ""
        Task {
            if await client.steerActiveRadio(phrase: phrase) == false {
                client.reportError(String(format: LS("radio.steer.unrecognised"), phrase))
            }
        }
    }
}

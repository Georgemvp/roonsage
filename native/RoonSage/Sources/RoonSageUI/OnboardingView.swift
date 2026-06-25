import SwiftUI
import RoonSageCore

/// First-run welcome shown to brand-new users *before* the connect screen.
///
/// Gating (see `WelcomeGate` in RootView): it appears whenever the app has
/// never successfully connected to a Roon Core (`client.savedHost == nil`) — so
/// it keeps showing on each launch *until the user is actually connected*, then
/// never nags a returning user again. The final step hands off to `ConnectView`.
///
/// Goals: explain what RoonSage is, make clear that the full experience needs
/// the **Analyzer/server** running on an always-on Mac, and preview the headline
/// features — all in Dutch, matching the rest of the app.
@MainActor
struct OnboardingView: View {
    /// Called when the user is ready to connect (taps "Verbinden" or "Overslaan").
    let onContinue: () -> Void

    @State private var step = 0

    private let steps = OnboardingStep.all

    var body: some View {
        VStack(spacing: 0) {
            // Skip — for users who already know RoonSage and just want to connect.
            HStack {
                Spacer()
                if step < steps.count - 1 {
                    Button("Overslaan") { onContinue() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .frame(height: 44)

            // Current step
            ScrollView {
                stepContent(steps[step])
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.lg)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .id(step) // restart entrance animation per step

            Spacer(minLength: 0)

            // Page dots
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.roonGold : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 22 : 8, height: 8)
                        .animation(Motion.quick, value: step)
                }
            }
            .padding(.bottom, Spacing.lg)
            .accessibilityHidden(true)

            // Navigation
            HStack(spacing: Spacing.md) {
                if step > 0 {
                    Button {
                        withAnimation(Motion.standard) { step -= 1 }
                    } label: {
                        Label("Terug", systemImage: "chevron.left").frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if step < steps.count - 1 {
                    Button {
                        withAnimation(Motion.standard) { step += 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Volgende")
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button { onContinue() } label: {
                        Label("Verbinden", systemImage: "music.note.house.fill").frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(_ s: OnboardingStep) -> some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.lg) {
                Image(systemName: s.icon)
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(s.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(s.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch s.kind {
            case .intro:
                introBody
            case .server:
                serverBody
            case .features:
                featuresBody
            case .connect:
                connectBody
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    // Step 1 — what RoonSage is
    private var introBody: some View {
        VStack(spacing: Spacing.md) {
            Text("RoonSage is je persoonlijke AI-muziekcurator boven op Roon. Vertel in gewone taal wat je wilt horen en RoonSage stelt een playlist samen, ontdekt nieuwe muziek en bestuurt het afspelen in elke zone.")
            Text("Het kernprincipe is **bibliotheek-eerst**: elke voorgestelde track bestaat echt — in jouw Roon-bibliotheek of op Qobuz. Niets wordt verzonnen.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // Step 2 — the Analyzer/server requirement (the part the user emphasised)
    private var serverBody: some View {
        VStack(spacing: Spacing.lg) {
            Text("Installeer de **RoonSage-analyzer** op een Mac die altijd aan staat. Die doet het zware werk en deelt het met al je apparaten:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Spacing.md) {
                OnboardingBullet(icon: "waveform", title: "Audio-analyse",
                                 text: "BPM, toonsoort, energie en tags — de basis voor DJ-sets en Sonic DNA.")
                OnboardingBullet(icon: "arrow.triangle.2.circlepath", title: "Synchronisatie",
                                 text: "Bibliotheek, instellingen en analyses worden gedeeld met elk apparaat.")
                OnboardingBullet(icon: "gearshape.2", title: "Eén plek voor instellingen",
                                 text: "Stel hier je AI-provider, Last.fm en Qobuz in.")
            }

            Text("Je vindt de Analyzer-app en de installatie-instructies in de RoonSage-release. Later koppel je dit apparaat via Instellingen → Server.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // Step 3 — feature highlights
    private var featuresBody: some View {
        VStack(spacing: Spacing.md) {
            OnboardingBullet(icon: "wand.and.stars", title: "AI-playlists",
                             text: "Genereer een playlist of stel je bibliotheek een vraag — in gewone taal.")
            OnboardingBullet(icon: "waveform.path.ecg", title: "Sonic DNA & Music Map",
                             text: "Ontdek je muzikale DNA en navigeer je collectie op klank.")
            OnboardingBullet(icon: "slider.horizontal.3", title: "DJ Set & Live DJ",
                             text: "Beatmatchte, harmonisch gemixte sets — automatisch of live.")
            OnboardingBullet(icon: "sparkles", title: "Ontdekken",
                             text: "Nieuwe releases, aanbevelingen en slimme radio's op maat.")
        }
    }

    // Step 4 — how to connect
    private var connectBody: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            OnboardingStepRow(number: 1, text: "Zorg dat je Roon Core draait op hetzelfde netwerk.")
            OnboardingStepRow(number: 2, text: "Tik op **Verbinden** en kies je Roon Core (of voer het IP-adres in).")
            OnboardingStepRow(number: 3, text: "Open in Roon **Instellingen → Extensies** en schakel **RoonSage** in.")
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

// MARK: - Step model

private struct OnboardingStep: Identifiable {
    enum Kind { case intro, server, features, connect }
    let id = UUID()
    let kind: Kind
    let icon: String
    let title: String
    let subtitle: String

    static let all: [OnboardingStep] = [
        .init(kind: .intro, icon: "music.note.house.fill",
              title: "Welkom bij RoonSage",
              subtitle: "Je AI-muziekcurator voor Roon"),
        .init(kind: .server, icon: "server.rack",
              title: "Wat je nodig hebt",
              subtitle: "De analyzer op een always-on Mac"),
        .init(kind: .features, icon: "sparkles",
              title: "Wat je kunt doen",
              subtitle: "Curatie, ontdekking en DJ-tools"),
        .init(kind: .connect, icon: "link",
              title: "Aan de slag",
              subtitle: "Verbind met je Roon Core"),
    ]
}

// MARK: - Reusable rows

private struct OnboardingBullet: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.roonGold)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingStepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.roonGold)
                .frame(width: 26, height: 26)
                .background(Color.roonGold.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

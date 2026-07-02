import RoonSageCore
import RoonSageUI
import SwiftUI

/// Client approval: the Mac/iOS apps knock with an auto-generated token; unknown
/// ones queue here and the user taps "Accepteer" to pair them — no token
/// copy-pasting. Approved devices can be revoked; the master token still works.
@MainActor
struct DevicesView: View {
    @State private var pending: [LibraryShareServer.PendingDevice] = []
    @State private var approved: [LibraryShareServer.ApprovedDevice] = []
    @State private var enforce = LibraryShareServer.enforceToken

    // Pending entries update as clients poll (~1.5s); refresh on a gentle cadence.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                pendingSection
                approvedSection
                enforceSection
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Apparaten")
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apparaten").font(.title2.bold())
            Text("Keur je Mac- en iOS-clients hier goed. Nieuwe apparaten melden zich automatisch aan — je hoeft geen token te kopiëren.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Pending

    @ViewBuilder
    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Wachtend op goedkeuring", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            if pending.isEmpty {
                Text("Geen apparaten in de wachtrij. Open de RoonSage-app op je Mac of iPhone en verbind met deze server — hij verschijnt hier binnen enkele seconden.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.sm)
            } else {
                ForEach(pending) { d in
                    deviceRow(name: d.name, subtitle: "\(d.ip) · voor het eerst gezien \(relative(d.firstSeen))") {
                        Button("Weiger") { LibraryShareServer.rejectDevice(token: d.token); reload() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Accepteer") { LibraryShareServer.approveDevice(token: d.token); reload() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Approved

    @ViewBuilder
    private var approvedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Goedgekeurd", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            if approved.isEmpty {
                Text("Nog geen goedgekeurde apparaten.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.sm)
            } else {
                ForEach(approved) { d in
                    deviceRow(name: d.name, subtitle: "goedgekeurd \(relative(d.approvedAt))") {
                        Button("Verwijder toegang", role: .destructive) {
                            LibraryShareServer.revokeDevice(token: d.token); reload()
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Enforce toggle

    private var enforceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle("Forceer goedkeuring (weiger niet-goedgekeurde clients)", isOn: Binding(
                get: { enforce },
                set: { enforce = $0; LibraryShareServer.enforceToken = $0 }
            ))
            .font(.subheadline.weight(.semibold))
            Text("Aan: alleen de master-token en goedgekeurde apparaten krijgen toegang; onbekende clients belanden in de wachtrij. Uit (grace-modus): clients zonder token worden nog steeds bediend — handig tijdens het koppelen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: Row + helpers

    @ViewBuilder
    private func deviceRow<Buttons: View>(name: String, subtitle: String,
                                          @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            buttons()
        }
        .padding(Spacing.md)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func reload() {
        pending = LibraryShareServer.pendingDevices()
        approved = LibraryShareServer.approvedDevices()
        enforce = LibraryShareServer.enforceToken
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

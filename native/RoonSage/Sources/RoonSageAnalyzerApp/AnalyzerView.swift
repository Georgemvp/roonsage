import AnalyzerCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AnalyzerView: View {
    @Environment(AnalyzerModel.self) private var model
    @Environment(AnalyzerUpdater.self) private var updater
    @State private var showPicker = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let u = updater.available {
                    updateBanner(u)
                }

                // Music library
                GroupBox("Muziekbibliotheek") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.musicPath.isEmpty ? "Geen map gekozen" : model.musicPath)
                                .font(.callout)
                                .foregroundStyle(model.musicPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("Kies…") { showPicker = true }
                        }
                        Text("\(model.trackCount) geanalyseerd · \(model.taggedCount) getagd")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Analyze
                GroupBox("1 · Analyseren") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isAnalyzing ? "Analyseren…" : (model.trackCount > 0 ? "Hervat analyse" : "Analyseer bibliotheek")) {
                                model.startAnalyze()
                            }
                            .disabled(model.musicPath.isEmpty || model.isAnalyzing)
                            if model.isAnalyzing {
                                Button("Pauzeer") { model.cancelAnalyze() }
                            }
                            Spacer()
                        }
                        if let p = model.analyze, model.isAnalyzing {
                            ProgressView(value: p.total > 0 ? Double(p.done + p.failed) / Double(p.total) : 0)
                            Text(String(format: "%d / %d  ·  %.1f/s  ·  nog %.0f min  ·  %d mislukt",
                                        p.done + p.failed, p.total, p.rate, p.etaSeconds / 60, p.failed))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                // Tag
                GroupBox("2 · Taggen (LLM via Ollama)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isTagging ? "Taggen…" : "Genereer tags") { model.startTag() }
                                .disabled(model.trackCount == 0 || model.isTagging)
                            if model.isTagging { Button("Annuleer") { model.cancelTag() } }
                            Spacer()
                        }
                        if let p = model.tag, model.isTagging {
                            ProgressView(value: p.total > 0 ? Double(p.tagged) / Double(p.total) : 0)
                            Text("\(p.tagged) / \(p.total) getagd · \(p.failed) mislukt")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                // Attribute axes — derived from stored embeddings, no re-scan.
                GroupBox("2b · Sonische kenmerken (uit embeddings)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isBackfilling ? "Berekenen…" : "Bereken kenmerken") {
                                model.startAttributeBackfill()
                            }
                            .disabled(!model.clapReady || model.isBackfilling || model.isAnalyzing || model.missingAttributes == 0)
                            if model.isBackfilling {
                                ProgressView().controlSize(.small)
                            } else if case .loading = model.clapLoadState {
                                ProgressView().controlSize(.small)
                                Text("Tekstmodel laden…").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(model.missingAttributes) zonder kenmerken")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Group {
                            switch model.clapLoadState {
                            case .idle, .loading:
                                Text("CLAP-tekstmodel wordt geladen — even geduld…")
                            case .failed:
                                Label("CLAP-model kon niet worden geladen. Controleer of de modellen geïnstalleerd zijn (scripts/setup_clap_models.sh).",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            case .ready:
                                if model.missingAttributes == 0 {
                                    Text("Alle tracks hebben al kenmerken.")
                                } else {
                                    Text("Leidt valence / dansbaarheid / akoestisch / instrumentaal af uit de bestaande embeddings — geen her-analyse nodig.")
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Serve
                GroupBox("3 · Beschikbaar maken voor de app") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isServing ? "Stop met delen" : "Start met delen") { model.toggleServe() }
                                .tint(model.isServing ? .red : nil)
                            Spacer()
                            if model.isServing {
                                Label("Actief op poort \(model.port)", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        Text("In de RoonSage-app: Instellingen → Audio Analyzer → http://DIT-MAC-IP:\(model.port)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Settings
                DisclosureGroup("Instellingen") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Automatisch analyseren bij opstarten", isOn: $model.autoStart)
                        labeled("Ollama URL") { TextField("", text: $model.ollamaURL).textFieldStyle(.roundedBorder) }
                        labeled("Model") { TextField("", text: $model.model).textFieldStyle(.roundedBorder) }
                        labeled("Poort") { TextField("", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 90) }
                    }
                    .padding(.top, 6)
                }

                if !model.status.isEmpty {
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.musicPath = url.path }
        }
        .navigationTitle("Analyzer")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34)).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("RoonSage Analyzer").font(.title2.bold())
                Text("v\(AnalyzerUpdater.currentVersion) · analyseer BPM, toonsoort & tags voor DJ-sets")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func updateBanner(_ info: AnalyzerUpdater.UpdateInfo) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Update beschikbaar: v\(info.version)")
            Spacer()
            if updater.isInstalling {
                ProgressView().controlSize(.small)
            } else {
                Button("Update & herstart") { Task { await updater.installUpdate() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func labeled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }
}

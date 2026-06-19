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
                GroupBox("Music Library") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.musicPath.isEmpty ? "No folder selected" : model.musicPath)
                                .font(.callout)
                                .foregroundStyle(model.musicPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("Choose…") { showPicker = true }
                        }
                        Text("\(model.trackCount) analyzed · \(model.taggedCount) tagged")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Analyze
                GroupBox("1 · Analyze") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isAnalyzing ? "Analyzing…" : (model.trackCount > 0 ? "Resume analyzing" : "Analyze library")) {
                                model.startAnalyze()
                            }
                            .disabled(model.musicPath.isEmpty || model.isAnalyzing)
                            if model.isAnalyzing {
                                Button("Pause") { model.cancelAnalyze() }
                            }
                            Spacer()
                        }
                        if let p = model.analyze, model.isAnalyzing {
                            ProgressView(value: p.total > 0 ? Double(p.done + p.failed) / Double(p.total) : 0)
                            Text(String(format: "%d / %d  ·  %.1f/s  ·  ETA %.0f min  ·  %d failed",
                                        p.done + p.failed, p.total, p.rate, p.etaSeconds / 60, p.failed))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                // Tag
                GroupBox("2 · Tag (LLM via Ollama)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isTagging ? "Tagging…" : "Generate tags") { model.startTag() }
                                .disabled(model.trackCount == 0 || model.isTagging)
                            if model.isTagging { Button("Cancel") { model.cancelTag() } }
                            Spacer()
                        }
                        if let p = model.tag, model.isTagging {
                            ProgressView(value: p.total > 0 ? Double(p.tagged) / Double(p.total) : 0)
                            Text("\(p.tagged) / \(p.total) tagged · \(p.failed) failed")
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
                            if model.isBackfilling { ProgressView().controlSize(.small) }
                            Spacer()
                            Text("\(model.missingAttributes) zonder kenmerken")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(model.clapReady
                             ? "Leidt valence / dansbaarheid / akoestisch / instrumentaal af uit de bestaande embeddings — geen her-analyse nodig."
                             : "Wacht tot het CLAP-tekstmodel geladen is (zie Serve).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Serve
                GroupBox("3 · Serve to the app") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isServing ? "Stop serving" : "Start serving") { model.toggleServe() }
                                .tint(model.isServing ? .red : nil)
                            Spacer()
                            if model.isServing {
                                Label("Serving on port \(model.port)", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        Text("In the RoonSage app: Settings → Audio Analyzer → http://THIS-MAC-IP:\(model.port)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Settings
                DisclosureGroup("Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Start analyzing automatically on launch", isOn: $model.autoStart)
                        labeled("Ollama URL") { TextField("", text: $model.ollamaURL).textFieldStyle(.roundedBorder) }
                        labeled("Model") { TextField("", text: $model.model).textFieldStyle(.roundedBorder) }
                        labeled("Serve port") { TextField("", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 90) }
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
                Text("v\(AnalyzerUpdater.currentVersion) · analyze BPM, key & tags for DJ sets")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func updateBanner(_ info: AnalyzerUpdater.UpdateInfo) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Update available: v\(info.version)")
            Spacer()
            if updater.isInstalling {
                ProgressView().controlSize(.small)
            } else {
                Button("Update & relaunch") { Task { await updater.installUpdate() } }
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

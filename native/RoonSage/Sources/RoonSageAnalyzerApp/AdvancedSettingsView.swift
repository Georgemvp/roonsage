import SwiftUI

/// "Geavanceerd" — power-user tuning for the analysis + tagging engines that was
/// previously hard-coded. Defaults match the old constants, so nothing changes
/// unless the user opts in. Analysis-tuning takes effect on the NEXT (re-)analysis,
/// not retroactively.
@MainActor
struct AdvancedSettingsView: View {
    @Environment(AnalyzerModel.self) private var model

    private let excerptOptions: [(String, Double)] =
        [("30 s (snel)", 30), ("60 s", 60), ("120 s (standaard)", 120), ("Volledige track", 0)]
    private let sampleRateOptions: [(String, Double)] =
        [("22,05 kHz (standaard)", 22050), ("44,1 kHz (preciezer, trager)", 44100)]
    private let contextOptions: [(String, Int)] =
        [("4096", 4096), ("8192 (standaard)", 8192), ("16384", 16384)]
    private let batchOptions: [(String, Int)] =
        [("50", 50), ("100", 100), ("200 (standaard)", 200), ("500", 500)]
    private let logLevelOptions: [(String, Int)] =
        [("Debug (alles)", 0), ("Info (standaard)", 1), ("Notice", 2), ("Waarschuwingen", 3), ("Alleen fouten", 4)]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                // C1 — Analysis tuning
                GroupBox("Analyse") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $model.walkerConcurrency, in: 1...12) {
                            Text("Parallelle analyses: \(model.walkerConcurrency)")
                        }
                        Text("Laag houden (3) voor een trage externe HDD — veel parallelle reads laten de schijf juist trager worden. Verhoog alleen voor SSD/lokale opslag.")
                            .font(.caption).foregroundStyle(.secondary)

                        Picker("Fragmentlengte", selection: $model.excerptSeconds) {
                            ForEach(excerptOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        Picker("Samplerate", selection: $model.analysisSampleRate) {
                            ForEach(sampleRateOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        Divider()
                        Text("Tempo (BPM)").font(.subheadline.weight(.semibold))
                        Stepper(value: $model.bpmMin, in: 20...300, step: 5) { Text("Min. BPM: \(Int(model.bpmMin))") }
                        Stepper(value: $model.bpmMax, in: 40...400, step: 5) { Text("Max. BPM: \(Int(model.bpmMax))") }
                        Stepper(value: $model.bpmPrior, in: 40...220, step: 1) { Text("Tempo-voorkeur: \(Int(model.bpmPrior)) BPM") }
                        Text("Het bereik begrenst de tempodetectie; de voorkeur stuurt de octaaf-keuze (half/dubbel tempo) — bv. ~90 ballad, ~120 algemeen, ~128 house, ~174 drum&bass.")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("Wijzigingen gelden voor de VOLGENDE analyse; bestaande tracks moeten opnieuw geanalyseerd worden om effect te hebben.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // C2 — Tagging (Ollama)
                GroupBox("Taggen (Ollama)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $model.tagConcurrency, in: 1...16) {
                            Text("Parallelle Ollama-verzoeken: \(model.tagConcurrency)")
                        }
                        Picker("Context (num_ctx)", selection: $model.tagContextTokens) {
                            ForEach(contextOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "Creativiteit (temperature): %.2f", model.tagTemperature))
                            Slider(value: $model.tagTemperature, in: 0...1, step: 0.05)
                            Text("Lager = consistentere tags, hoger = creatiever.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Batchgrootte", selection: $model.tagBatchSize) {
                            ForEach(batchOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        Divider()
                        HStack {
                            Button("Test Ollama") { model.testOllama() }
                            Spacer()
                        }
                        if let s = model.ollamaTestStatus {
                            Text(s).font(.caption)
                                .foregroundStyle(s.hasPrefix("✓") ? .green : (s.hasPrefix("Testen") ? .secondary : .orange))
                        }
                    }
                    .padding(6)
                }

                // C3 — Server & security
                GroupBox("Server & beveiliging") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Token afdwingen voor alle clients", isOn: $model.enforceToken)
                        Text("Aan: nog niet-gekoppelde clients worden geweigerd (geen grace-window). Een fout token wordt altijd geweigerd. Het token zelf staat onder Server → Bibliotheek.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                // Dataset — offline MusicMoveArr sidecar (ISRC/MBID identity,
                // discovery candidates, DJ-tempo cross-check). One-click fetch of
                // a published release, or point at a locally distilled sidecar.
                GroupBox("Dataset (MusicMoveArr)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Verrijkt tracks met ISRC/MusicBrainz-identiteit, label/UPC/releasedatum en levert offline ontdekkingskandidaten. \(model.isrcCount)/\(model.trackCount) tracks hebben een ISRC.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.isFetchingDataset ? "Bezig…" : "Dataset ophalen") { model.downloadCuratedDataset() }
                                .disabled(model.isFetchingDataset)
                            Spacer()
                        }
                        if let s = model.datasetFetchStatus {
                            Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Divider()
                        Text("Sidecar-pad (handmatig, bv. een lokaal gedistilleerde metadata.db)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Pad naar metadata.db", text: $model.datasetSidecarPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(6)
                }

                // C4 — Maintenance
                GroupBox("Onderhoud") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Start bij inloggen (always-on server)", isOn: $model.launchAtLogin)
                        Picker("Logniveau", selection: $model.logLevelRaw) {
                            ForEach(logLevelOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        Text("Een lager niveau (Debug) helpt bij het diagnosticeren van verbindingsproblemen; logt naar het bestand onder Server → Over → Logboek.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            Button("Back-up database") { model.backupDatabase() }
                            Button("Database opschonen") { model.vacuumDatabase() }
                            Spacer()
                        }
                        if let s = model.maintenanceStatus {
                            Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle("Geavanceerd")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Geavanceerd").font(.title2.bold())
            Text("Fijnafstelling van de analyse- en tagging-motor. Standaardwaarden = de oude vaste instellingen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

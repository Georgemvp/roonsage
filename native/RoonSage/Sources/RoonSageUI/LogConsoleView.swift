import SwiftUI
import RoonSageCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Logboek-scherm: toont de staart van het gedeelde logbestand en maakt het in
// één tik kopieerbaar of deelbaar, zodat je het integraal aan Claude kunt geven.
// Werkt identiek op macOS en iOS (RoonSageCore.Log doet het zware werk).
public struct LogConsoleView: View {
    @State private var text: String = ""
    @State private var snapshotURL: URL = Log.exportSnapshot()
    @State private var copied = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Nog geen logregels." : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("logbottom")
                }
                .onChange(of: text) { _, _ in
                    withAnimation { proxy.scrollTo("logbottom", anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    copyAll()
                } label: {
                    Label(copied ? "Gekopieerd ✓" : "Kopieer alles", systemImage: "doc.on.doc")
                }

                ShareLink(item: snapshotURL) {
                    Label("Delen / bewaren", systemImage: "square.and.arrow.up")
                }

                #if os(macOS)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                } label: {
                    Label("Toon in Finder", systemImage: "folder")
                }
                #endif

                Spacer()

                Button(role: .destructive) {
                    Log.clear()
                    refresh()
                } label: {
                    Label("Wis", systemImage: "trash")
                }
            }
            .padding(12)
        }
        .navigationTitle("Logboek")
        .toolbar {
            Button {
                refresh()
            } label: {
                Label("Ververs", systemImage: "arrow.clockwise")
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        text = Log.fullText()
        snapshotURL = Log.exportSnapshot()
    }

    private func copyAll() {
        let full = Log.fullText()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        #else
        UIPasteboard.general.string = full
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

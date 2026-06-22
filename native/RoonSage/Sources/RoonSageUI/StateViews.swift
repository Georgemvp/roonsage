import SwiftUI

/// One place for the loading → error → empty → content lifecycle that every data
/// screen repeats. Replaces ad-hoc `if isLoading { ProgressView } else if …`
/// ladders — and crucially shows the skeleton *before* the empty state so lists
/// stop flashing "geen resultaten" on every open.
///
/// Flag-based (not generic over the value) so a view keeps its own `@State`
/// data and just passes its existing flags:
///
/// ```swift
/// AsyncStateView(isLoading: !loaded, isEmpty: items.isEmpty, error: errorText,
///                onRetry: { reload() }) {
///     List(items) { … }
/// } empty: {
///     ContentUnavailableView("Niets hier", systemImage: "tray")
/// }
/// ```
@MainActor
public struct AsyncStateView<Content: View, Empty: View>: View {
    private let isLoading: Bool
    private let isEmpty: Bool
    private let error: String?
    private let onRetry: (() -> Void)?
    private let content: () -> Content
    private let empty: () -> Empty

    public init(
        isLoading: Bool,
        isEmpty: Bool,
        error: String? = nil,
        onRetry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder empty: @escaping () -> Empty
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.error = error
        self.onRetry = onRetry
        self.content = content
        self.empty = empty
    }

    public var body: some View {
        if let error {
            ContentUnavailableView {
                Label("Er ging iets mis", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let onRetry {
                    Button("Opnieuw proberen", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if isLoading {
            SkeletonRows()
        } else if isEmpty {
            empty()
        } else {
            content()
        }
    }
}

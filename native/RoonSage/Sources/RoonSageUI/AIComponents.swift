import SwiftUI
import RoonSageCore

// MARK: - Shared building blocks for the AI-curation screens
//
// Generate, Ask and Recommend used to each hand-roll their own prompt field,
// zone picker, result row and scope summary, so they drifted apart. These shared
// pieces make the three screens feel like one cohesive family.

// MARK: Prompt field

/// A multi-line prompt input with a placeholder overlay, gold focus ring and a
/// card-like fill — replaces the ad-hoc `TextEditor.background(.quaternary…)`.
@MainActor
public struct AIPromptField: View {
    @Binding private var text: String
    private let placeholder: String
    private let minHeight: CGFloat

    public init(text: Binding<String>, placeholder: String, minHeight: CGFloat = 80) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.md)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .frame(minHeight: minHeight)
                .accessibilityLabel(placeholder)
        }
        .background(Color.platformQuaternaryFill, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.roonGold.opacity(text.isEmpty ? 0.10 : 0.30))
        )
        .animation(Motion.quick, value: text.isEmpty)
    }
}

// MARK: Idea / template chips row

/// A horizontal strip of tappable suggestion chips (idea prompts, quick filters).
@MainActor
public struct SuggestionChips: View {
    private let items: [String]
    private let onPick: (String) -> Void

    public init(_ items: [String], onPick: @escaping (String) -> Void) {
        self.items = items
        self.onPick = onPick
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(items, id: \.self) { item in
                    Button {
                        onPick(item)
                        Haptics.tap()
                    } label: {
                        Text(item)
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

// MARK: Zone picker

/// One zone selector bound directly to `client.selectedZone` (the single source
/// of truth) so the in-content picker and the toolbar picker never drift. Hides
/// itself when there are no zones; auto-selects the only zone when there's one.
@MainActor
public struct ZonePicker: View {
    @Environment(RoonClient.self) private var client

    public init() {}

    public var body: some View {
        Group {
            if !client.zones.isEmpty {
                Menu {
                    ForEach(client.zones) { z in
                        Button {
                            client.selectZone(z.id)
                            Haptics.tap()
                        } label: {
                            Label(z.displayName,
                                  systemImage: z.id == client.selectedZone?.id ? "checkmark" : z.state.icon)
                        }
                    }
                } label: {
                    let unset = client.selectedZone == nil
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: unset ? "exclamationmark.circle.fill"
                              : (client.selectedZone?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                        Text(client.selectedZone?.displayName ?? "Kies zone")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .opacity(0.6)
                    }
                    // When no zone is chosen, the picker is the thing standing
                    // between the user and playback — make it read as an action
                    // needed (accent tint) rather than a passive status chip.
                    .font(.subheadline.weight(unset ? .semibold : .medium))
                    .foregroundStyle(unset ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(unset ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                : AnyShapeStyle(Color.platformQuaternaryFill), in: Capsule())
                }
                .fixedSize()
                .onAppear {
                    if client.selectedZone == nil, client.zones.count == 1 {
                        client.selectZone(client.zones[0].id)
                    }
                }
            }
        }
    }
}

// MARK: Zone hint banner

/// Shown above zone-dependent actions when no zone is selected, so play buttons
/// don't just silently disable with no explanation. Embeds the `ZonePicker` so
/// the fix is one tap away. Hides itself once a zone is chosen (or none exist).
@MainActor
public struct ZoneHintBanner: View {
    @Environment(RoonClient.self) private var client

    public init() {}

    public var body: some View {
        if client.selectedZone == nil, !client.zones.isEmpty {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Kies een zone om af te spelen")
                    .font(.subheadline)
                Spacer()
                ZonePicker()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: Result row

/// A track/album row with optional index, artwork, title/subtitle and a trailing
/// action slot — replaces the three near-identical hand-rolled rows.
@MainActor
public struct AIResultRow<Trailing: View>: View {
    private let index: Int?
    private let title: String
    private let subtitle: String?
    private let imageKey: String?
    private let trailing: Trailing

    public init(
        index: Int? = nil, title: String, subtitle: String? = nil, imageKey: String?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.index = index
        self.title = title
        self.subtitle = subtitle
        self.imageKey = imageKey
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Spacing.md) {
            if let index {
                Text("\(index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .trailing)
            }
            AlbumArtView(imageKey: imageKey, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: Filter chips

/// Renders an analysed request scope as wrapping chips (genres in gold, mood tags
/// in blue, decades neutral) instead of one grey caption — feeds off the shared
/// `RequestFilters`.
@MainActor
public struct FilterChips: View {
    private let filters: RoonClient.RequestFilters
    private let poolSize: Int?

    public init(filters: RoonClient.RequestFilters, poolSize: Int? = nil) {
        self.filters = filters
        self.poolSize = poolSize
    }

    public var body: some View {
        FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
            ForEach(filters.genres, id: \.self) { Badge($0, tint: .roonGold) }
            ForEach(filters.tags, id: \.self) { Badge($0, tint: .roonInfo) }
            ForEach(filters.decades.sorted(), id: \.self) { Badge("\($0)s") }
            if filters.genres.isEmpty && filters.tags.isEmpty && filters.decades.isEmpty {
                Badge("hele bibliotheek")
            }
            if let poolSize { Badge("\(poolSize) kandidaten") }
        }
    }
}

// MARK: Staged progress

/// A horizontal stepper showing the four generation stages, with the active step
/// spinning and completed steps checked — the payoff cue during the LLM wait.
@MainActor
public struct GenerationStepper: View {
    private let current: RoonClient.GenerationPhase
    private let phases: [RoonClient.GenerationPhase]

    /// `phases` lets a shorter flow (e.g. Recommend has no naming stage) render
    /// only the steps it actually runs, so no step hangs forever as "pending".
    public init(current: RoonClient.GenerationPhase,
                phases: [RoonClient.GenerationPhase] = RoonClient.GenerationPhase.allCases) {
        self.current = current
        self.phases = phases
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(phases, id: \.rawValue) { phase in
                let state = stepState(phase)
                HStack(spacing: Spacing.xs) {
                    icon(for: state)
                        .frame(width: 16, height: 16)
                    Text(phase.label)
                        .font(.caption.weight(state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }
                if phase != phases.last {
                    Rectangle()
                        .fill(state == .done ? Color.roonGold : Color.secondary.opacity(0.2))
                        .frame(height: 1)
                        .frame(maxWidth: 24)
                }
            }
        }
    }

    private enum StepState { case done, active, pending }

    private func stepState(_ phase: RoonClient.GenerationPhase) -> StepState {
        if phase.rawValue < current.rawValue { return .done }
        if phase.rawValue == current.rawValue { return .active }
        return .pending
    }

    @ViewBuilder
    private func icon(for state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.roonGold)
        case .active:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Flow layout

/// A wrapping HStack: lays children left-to-right, moving to a new line when the
/// proposed width runs out. Used for filter/tag chips. Requires the SwiftUI
/// `Layout` protocol (macOS 13+/iOS 16+ — both below our deployment targets).
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

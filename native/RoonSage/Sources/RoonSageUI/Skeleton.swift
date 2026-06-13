import SwiftUI

/// Placeholder list rows shown while content loads — a gentle pulsing skeleton
/// instead of a blank screen or a flash of the empty state. Used by list views
/// during their initial (now async) database load.
public struct SkeletonRows: View {
    private let count: Int
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int = 10) {
        self.count = count
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: Radius.sm).frame(width: 170, height: 11)
                        RoundedRectangle(cornerRadius: Radius.sm).frame(width: 110, height: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(.quaternary)
            }
            Spacer()
        }
        .opacity(pulse ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

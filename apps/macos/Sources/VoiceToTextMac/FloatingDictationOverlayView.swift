import SwiftUI

public struct FloatingDictationOverlayView: View {
    @EnvironmentObject private var shellState: ShellState
    @State private var animateWave = false

    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(waveHeights.enumerated()), id: \.offset) { index, height in
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(width: 4, height: animateWave ? height : 8)
                        .animation(
                            .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.08),
                            value: animateWave
                        )
                }
            }

            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.84))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .onAppear {
            animateWave = true
        }
    }

    private var barColor: Color {
        switch shellState.floatingOverlayPhase {
        case .recording:
            return .white
        case .processing:
            return Color.white.opacity(0.85)
        }
    }

    private var dotColor: Color {
        switch shellState.floatingOverlayPhase {
        case .recording:
            return .red
        case .processing:
            return .blue
        }
    }

    private var waveHeights: [CGFloat] {
        switch shellState.floatingOverlayPhase {
        case .recording:
            return [10, 20, 14, 24, 12]
        case .processing:
            return [8, 14, 10, 14, 8]
        }
    }
}

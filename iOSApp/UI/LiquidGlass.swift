import SwiftUI

struct LiquidGlassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 8)
            content
                .padding(16)
        }
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var tint: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.55 : 0.8))
                    .background {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

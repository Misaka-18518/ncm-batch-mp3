import SwiftUI

enum GlassTheme {
    static let radius: CGFloat = 24
}

extension View {
    @ViewBuilder
    func liquidPanel(cornerRadius: CGFloat = GlassTheme.radius, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 10)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        }
    }

    @ViewBuilder
    func liquidButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

struct LiquidBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color.black
            } else {
                Color(red: 0.92, green: 0.90, blue: 0.85)
            }

            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.18), value: colorScheme)
        .ignoresSafeArea()
    }
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.78),
                            Color.teal.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }

            Circle()
                .fill(Color.white.opacity(0.74))
                .frame(width: size * 0.58, height: size * 0.58)
                .overlay {
                    Circle()
                        .stroke(Color.cyan.opacity(0.30), lineWidth: size * 0.035)
                }

            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(Color(red: 0.05, green: 0.18, blue: 0.22))
                .offset(x: -size * 0.02, y: -size * 0.02)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundStyle(.white)
                .padding(size * 0.09)
                .background(Color.teal, in: Circle())
                .offset(x: size * 0.28, y: size * 0.27)
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct SectionTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

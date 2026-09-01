import SwiftUI

struct TsumibenLogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color("ink.raised"), Color("ink.night")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                JarMark()
                    .padding(compact ? 5 : 6)
            }
            .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)

            Text("つみべん")
                .font(TsumibenTheme.brand(compact ? 18 : 22))
                .tracking(0.5)
                .foregroundStyle(TsumibenTheme.amber)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("つみべん")
    }
}

private struct JarMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                DropJarBody()
                    .stroke(
                        LinearGradient(
                            colors: [TsumibenTheme.auroraWarm, TsumibenTheme.auroraBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(
                            lineWidth: max(1.2, size.width * 0.075),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                Capsule()
                    .fill(Color(hex: Constants.Color.glassAbsorption).opacity(0.78))
                    .overlay {
                        Capsule().stroke(
                            LinearGradient(
                                colors: [TsumibenTheme.auroraWarm, TsumibenTheme.auroraBlue],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: max(1, size.width * 0.065)
                        )
                    }
                    .frame(width: size.width * 0.69, height: size.height * 0.16)
                    .offset(y: -size.height * 0.34)

                RoundedRectangle(cornerRadius: size.width * 0.055, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [.white, TsumibenTheme.auroraWarm, Color("subj.eng")],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: size.width * 0.22
                        )
                    )
                    .frame(width: size.width * 0.20, height: size.width * 0.20)
                    .rotationEffect(.degrees(45))
                    .shadow(color: TsumibenTheme.auroraWarm.opacity(0.55), radius: 3)
                    .offset(y: -size.height * 0.04)

                HStack(alignment: .bottom, spacing: size.width * 0.035) {
                    Circle().fill(Color("subj.jpn"))
                    Circle().fill(Color("subj.math"))
                    Circle().fill(Color("subj.eng"))
                }
                .frame(width: size.width * 0.52, height: size.height * 0.16)
                .offset(y: size.height * 0.28)
            }
        }
    }
}

private struct DropJarBody: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.24, y: rect.height * 0.22))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.13, y: rect.height * 0.42),
            control1: CGPoint(x: rect.width * 0.20, y: rect.height * 0.25),
            control2: CGPoint(x: rect.width * 0.13, y: rect.height * 0.31)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.13, y: rect.height * 0.76))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.88),
            control1: CGPoint(x: rect.width * 0.13, y: rect.height * 0.84),
            control2: CGPoint(x: rect.width * 0.20, y: rect.height * 0.88)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.69, y: rect.height * 0.88))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.87, y: rect.height * 0.76),
            control1: CGPoint(x: rect.width * 0.80, y: rect.height * 0.88),
            control2: CGPoint(x: rect.width * 0.87, y: rect.height * 0.84)
        )
        path.addLine(to: CGPoint(x: rect.width * 0.87, y: rect.height * 0.42))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.76, y: rect.height * 0.22),
            control1: CGPoint(x: rect.width * 0.87, y: rect.height * 0.31),
            control2: CGPoint(x: rect.width * 0.80, y: rect.height * 0.25)
        )
        return path
    }
}

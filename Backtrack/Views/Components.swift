import SwiftUI

enum Theme {
    static let bg = Color(red: 0.043, green: 0.051, blue: 0.039)
    static let card = Color(red: 0.078, green: 0.090, blue: 0.071)
    static let cardBorder = Color.white.opacity(0.08)
    static let lime = Color(red: 0.71, green: 0.95, blue: 0.28)
    static let limeDeep = Color(red: 0.52, green: 0.84, blue: 0.16)
    static let green = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let secondaryText = Color(white: 0.60)
}

func timeString(_ t: Double) -> String {
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// The symmetric green bars used as the app logo.
struct LogoGlyph: View {
    var barHeights: [CGFloat] = [0.30, 0.55, 1.0, 0.75, 1.0, 0.55, 0.30]
    var height: CGFloat = 56

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(barHeights.indices, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.lime, Theme.green],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: height * barHeights[i])
            }
        }
        .frame(height: height)
        .shadow(color: Theme.green.opacity(0.6), radius: 12)
    }
}

/// Small animated equalizer shown on the now-playing card.
struct EqualizerBars: View {
    @State private var animate = false
    private let base: [CGFloat] = [0.35, 0.8, 0.5, 1.0, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(base.indices, id: \.self) { i in
                Capsule()
                    .fill(Theme.green)
                    .frame(width: 3, height: 22 * (animate ? base[i] : base[(i + 2) % base.count]))
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.09),
                        value: animate)
            }
        }
        .frame(height: 24)
        .onAppear { animate = true }
    }
}

struct CardBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(highlighted ? Theme.green.opacity(0.7) : Theme.cardBorder,
                                  lineWidth: 1))
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View {
        modifier(CardBackground(highlighted: highlighted))
    }
}

/// Waveform with played/unplayed coloring, a playhead, a progress underline,
/// and drag-to-scrub.
struct WaveformView: View {
    var samples: [Float]
    var progress: Double            // 0...1
    var onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                let count = max(1, samples.count)
                let slot = size.width / CGFloat(count)
                let barW = max(1.5, slot * 0.55)
                let waveH = size.height - 10   // reserve room for the underline
                let px = CGFloat(progress) * size.width

                for i in 0..<count {
                    let x = CGFloat(i) * slot + (slot - barW) / 2
                    let amp = max(0.06, CGFloat(samples[i]))
                    let bh = max(2, waveH * amp)
                    let rect = CGRect(x: x, y: (waveH - bh) / 2, width: barW, height: bh)
                    let played = x + barW / 2 <= px
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barW / 2),
                        with: .color(played ? Theme.lime : Color(white: 0.24)))
                }

                // Progress underline.
                let lineY = size.height - 3
                ctx.fill(Path(CGRect(x: 0, y: lineY, width: size.width, height: 2.5)),
                         with: .color(Color(white: 0.18)))
                ctx.fill(Path(CGRect(x: 0, y: lineY, width: px, height: 2.5)),
                         with: .color(Theme.limeDeep))

                // Playhead.
                if !samples.isEmpty {
                    ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: waveH)),
                             with: .color(.white))
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: px - 4.5, y: -2, width: 9, height: 9)),
                        with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(1, max(0, value.location.x / max(1, w))))
                    })
            .frame(width: w, height: h)
        }
    }
}

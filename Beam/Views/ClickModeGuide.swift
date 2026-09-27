import SwiftUI

/// Click mode's gestures (BEAM-70), each with a small looping diagram in the manner of
/// the Trackpad pane in System Settings: fingertips on a phone-screen tile, and what the
/// Mac does in response drawn in Beam orange.
struct ClickModeGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(gesture: GuideGesture, title: String, detail: String)] = [
        (.tap, "Click", "Tap."),
        (.doubleTap, "Double-click", "Tap twice. Tap three times to triple-click."),
        (.holdRightClick, "Right-click", "Touch and hold until you feel a tap, then lift. Tapping with two fingers works too."),
        (.drag, "Drag", "Touch and hold until you feel a tap, then move. Moves windows, selects text, drags files."),
        (.scroll, "Scroll", "Slide two fingers."),
        (.pinch, "Zoom", "Pinch. Pinch all the way out to see the whole screen."),
        (.pan, "Move around", "Slide one finger while zoomed in."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 16) {
                            GestureDiagram(gesture: row.gesture)
                                .frame(width: 84, height: 84)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title)
                                    .font(.headline)
                                Text(row.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 100)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Click Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

enum GuideGesture {
    case tap, doubleTap, holdRightClick, drag, scroll, pinch, pan

    /// Seconds for one loop of the diagram.
    var period: Double {
        switch self {
        case .tap: return 1.6
        case .doubleTap: return 1.9
        case .holdRightClick: return 2.2
        case .drag: return 4.4
        case .scroll: return 2.0
        case .pinch: return 2.4
        case .pan: return 2.4
        }
    }
}

/// One looping diagram. Everything is a function of the time within the loop, so the
/// drawing is stateless and every row keeps its own rhythm. Each loop ends exactly where
/// it began, so there is no visible reset.
private struct GestureDiagram: View {
    let gesture: GuideGesture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            // Reduce Motion: hold one representative moment instead of looping.
            let t = reduceMotion ? 0.45 : seconds.truncatingRemainder(dividingBy: gesture.period) / gesture.period
            Canvas { context, size in
                draw(t: t, in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private static let accent = Color.orange
    private static let fingerRadius: CGFloat = 9

    private func draw(t: Double, in context: inout GraphicsContext, size: CGSize) {
        let tile = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: tile, cornerRadius: 18, style: .continuous), with: .color(Color(white: 0.15)))
        context.stroke(Path(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 18, style: .continuous),
                       with: .color(.white.opacity(0.08)), lineWidth: 1)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)

        switch gesture {
        case .tap:
            let press = pulse(t, at: 0.35)
            fingers([c], t: t, pressed: press > 0, in: &context)
            ripple(at: c, progress: ramp(t, 0.42, 0.85), in: &context)

        case .doubleTap:
            let first = pulse(t, at: 0.3), second = pulse(t, at: 0.52)
            fingers([c], t: t, pressed: first > 0 || second > 0, in: &context)
            ripple(at: c, progress: ramp(t, 0.36, 0.7), in: &context)
            ripple(at: c, progress: ramp(t, 0.58, 0.92), in: &context)

        case .holdRightClick:
            // One finger holds still (the ring fills), lifts, and a context menu opens there.
            let p = CGPoint(x: c.x - 8, y: c.y + 10)
            let held = t > 0.15 && t < 0.55
            // The finger lifts at 0.55: run its usual fade-out over the next moment.
            let fingerT = t < 0.55 ? t : min(0.9 + (t - 0.55) / 0.07 * 0.08, 0.99)
            fingers([p], t: fingerT, pressed: held, in: &context)
            let hold = ramp(t, 0.15, 0.45)
            if held, hold > 0 {
                var arc = Path()
                arc.addArc(center: p, radius: Self.fingerRadius + 5, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * hold), clockwise: false)
                context.stroke(arc, with: .color(.white.opacity(0.9)), lineWidth: 2)
            }
            let menu = ramp(t, 0.58, 0.68) * (1 - ramp(t, 0.88, 0.97))
            if menu > 0 {
                let rect = CGRect(x: p.x + 4, y: p.y - 38, width: 30, height: 34)
                context.opacity = menu
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color(white: 0.3)))
                for i in 0..<3 {
                    let line = CGRect(x: rect.minX + 5, y: rect.minY + 7 + CGFloat(i) * 9, width: i == 0 ? 20 : 16, height: 3)
                    context.fill(Path(roundedRect: line, cornerRadius: 1.5),
                                 with: .color(i == 0 ? Self.accent : .white.opacity(0.5)))
                }
                context.opacity = 1
            }

        case .drag:
            // Hold (a ring fills around the finger), carry a window across, then a second
            // drag brings it back, so the loop ends where it began.
            let a = CGPoint(x: size.width * 0.3, y: size.height * 0.62)
            let b = CGPoint(x: size.width * 0.7, y: size.height * 0.38)
            let u = t < 0.5 ? t * 2 : (t - 0.5) * 2
            let (start, end) = t < 0.5 ? (a, b) : (b, a)
            let p = lerp(start, end, ease(ramp(u, 0.45, 0.8)))
            let held = u > 0.15 && u < 0.86
            let window = CGRect(x: p.x - 22, y: p.y - 14, width: 36, height: 26)
            context.fill(Path(roundedRect: window, cornerRadius: 4),
                         with: .color(held && u > 0.42 ? Self.accent.opacity(0.9) : Color(white: 0.32)))
            context.fill(Path(CGRect(x: window.minX, y: window.minY, width: window.width, height: 6)),
                         with: .color(.black.opacity(0.18)))
            fingers([p], t: u, pressed: held, in: &context)
            let hold = ramp(u, 0.15, 0.42)
            if held, hold > 0, hold < 1 || u < 0.5 {
                var arc = Path()
                arc.addArc(center: p, radius: Self.fingerRadius + 5, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * hold), clockwise: false)
                context.stroke(arc, with: .color(.white.opacity(0.9 * (1 - ramp(u, 0.42, 0.5)))), lineWidth: 2)
            }

        case .scroll:
            // Two fingers slide up and the page scrolls with them. The lines repeat every
            // three rows and the page moves exactly three rows, so the loop has no seam.
            let spacing: CGFloat = 11
            let travel = ease(ramp(t, 0.25, 0.75)) * spacing * 3
            var content = context
            content.clip(to: Path(roundedRect: tile.insetBy(dx: 10, dy: 10), cornerRadius: 8))
            for i in 0..<10 {
                let y = 14 + CGFloat(i) * spacing - travel
                let width: CGFloat = [40, 52, 46][i % 3]
                content.fill(Path(roundedRect: CGRect(x: 16, y: y, width: width, height: 4), cornerRadius: 2),
                             with: .color(.white.opacity(0.22)))
            }
            let a = CGPoint(x: c.x - 11, y: c.y + 16 - travel), b = CGPoint(x: c.x + 11, y: c.y + 12 - travel)
            fingers([a, b], t: t, pressed: t > 0.2 && t < 0.8, in: &context)

        case .pinch:
            // Fingers spread and the picture grows, then both come back.
            let spread = ease(ramp(t, 0.25, 0.7)) * (1 - ease(ramp(t, 0.85, 1.0)))
            let scale = 1 + spread * 0.6
            let square = CGRect(x: c.x - 13 * scale, y: c.y - 10 * scale, width: 26 * scale, height: 20 * scale)
            context.fill(Path(roundedRect: square, cornerRadius: 4 * scale), with: .color(Self.accent.opacity(0.85)))
            let offset = 12 + spread * 16
            let a = CGPoint(x: c.x - offset, y: c.y + offset * 0.9), b = CGPoint(x: c.x + offset, y: c.y - offset * 0.9)
            fingers([a, b], t: t, pressed: t > 0.2 && t < 0.78, in: &context)

        case .pan:
            // One finger slides and the zoomed-in view moves under it by exactly one tile,
            // so the grid looks the same when the loop starts over.
            let step: CGFloat = 26
            let travel = ease(ramp(t, 0.25, 0.75)) * step
            var content = context
            content.clip(to: Path(roundedRect: tile.insetBy(dx: 6, dy: 6), cornerRadius: 12))
            for row in 0..<4 {
                for column in -1..<4 {
                    let rect = CGRect(x: -6 + CGFloat(column) * step + travel, y: 4 + CGFloat(row) * 22, width: 20, height: 16)
                    content.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(0.14)))
                }
            }
            let p = CGPoint(x: c.x - 13 + travel, y: c.y + 8)
            fingers([p], t: t, pressed: t > 0.2 && t < 0.8, in: &context)
        }
    }

    /// Fingertips fade in, press (brighter, slightly smaller) and fade out each loop.
    private func fingers(_ points: [CGPoint], t: Double, pressed: Bool, in context: inout GraphicsContext) {
        let visible = ramp(t, 0.05, 0.18) * (1 - ramp(t, 0.9, 0.98))
        guard visible > 0 else { return }
        let radius = Self.fingerRadius * (pressed ? 0.88 : 1)
        for point in points {
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white.opacity(0.1 * visible)))
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity((pressed ? 0.95 : 0.55) * visible)))
        }
    }

    private func ripple(at point: CGPoint, progress: Double, in context: inout GraphicsContext) {
        guard progress > 0, progress < 1 else { return }
        let radius = Self.fingerRadius + CGFloat(progress) * 18
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(Self.accent.opacity(0.9 * (1 - progress))), lineWidth: 2)
    }

    // MARK: Timing helpers

    /// 0 before `from`, 1 after `to`, linear between.
    private func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
        min(max((t - from) / (to - from), 0), 1)
    }

    /// 1 for a short press around `at`, else 0.
    private func pulse(_ t: Double, at: Double) -> Double {
        (t >= at && t < at + 0.07) ? 1 : 0
    }

    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

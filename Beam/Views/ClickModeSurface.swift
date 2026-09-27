import SwiftUI
import UIKit

/// What the click-mode surface asks the stream view to do. Locations are in the video
/// container's coordinates, the same space `StreamView.sendClick` already maps from.
struct ClickModeActions {
    /// A tap. `count` is 2 or 3 for the second or third tap of a quick series.
    var click: (_ location: CGPoint, _ count: Int, _ right: Bool) -> Void
    /// Press, drag and release.
    var pointer: (_ phase: PointerPhase, _ location: CGPoint) -> Void
    /// Two-finger scroll on the Mac, in phone points.
    var scroll: (_ location: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> Void
    /// One-finger pan of the zoomed view. `translation` is cumulative for the gesture.
    var panView: (_ translation: CGSize, _ ended: Bool) -> Void
    /// Pinch zoom of the view. `scale` is cumulative for the gesture.
    var zoomView: (_ scale: CGFloat, _ ended: Bool) -> Void
    /// Nudge the zoomed view by a delta, for dragging something past the visible edge.
    /// Returns false when the view cannot move further that way.
    var nudgeView: (_ delta: CGSize) -> Bool
}

enum PointerPhase { case down, move, up }

/// Click mode's touch surface (BEAM-70), laid over the video while a click mode is on.
///
/// - Tap: click, sent at once. Quick repeat taps at the same spot are a double- and
///   triple-click.
/// - Touch and hold (haptic), then move: press and drag (windows, text selection, files).
///   Release to drop.
/// - Touch and hold, then lift without moving: right-click.
/// - One finger moved straight away: pan the zoomed view.
/// - Two fingers: slide to scroll the Mac, pinch to zoom the view.
/// - Two-finger tap: right-click.
///
/// Hosts without pointer support only get taps and right-clicks; the hold, drag and
/// scroll gestures still pan and zoom the view.
struct ClickModeSurface: UIViewRepresentable {
    var supportsPointer: Bool
    var rightButton: Bool
    var isViewLocked: Bool
    var actions: ClickModeActions

    func makeUIView(context: Context) -> ClickModeSurfaceView {
        let view = ClickModeSurfaceView()
        update(view)
        return view
    }

    func updateUIView(_ view: ClickModeSurfaceView, context: Context) {
        update(view)
    }

    private func update(_ view: ClickModeSurfaceView) {
        view.supportsPointer = supportsPointer
        view.rightButton = rightButton
        view.isViewLocked = isViewLocked
        view.actions = actions
    }
}

final class ClickModeSurfaceView: UIView, UIGestureRecognizerDelegate {
    /// Without it, holding and moving pans the view instead of dragging on the Mac.
    var supportsPointer = false {
        didSet { hold.isEnabled = supportsPointer }
    }
    var rightButton = false
    var isViewLocked = false
    var actions: ClickModeActions?

    // Multi-click: macOS counts a click as the next of a series when it lands soon
    // after the previous one and close to it.
    private static let multiClickInterval: TimeInterval = 0.4
    private static let multiClickDistance: CGFloat = 24
    private var lastTap: (time: TimeInterval, location: CGPoint, count: Int)?

    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let onePan = UIPanGestureRecognizer()
    private let twoPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    // Two-finger gestures pick scroll or zoom from how they start, then stick with it.
    private enum TwoFingerMode { case undecided, scroll, zoom }
    private var twoFingerMode = TwoFingerMode.undecided
    /// Set once a pinch has changed the zoom, cleared when the next one starts. Kept apart
    /// from `twoFingerMode` so the zoom is committed however the two recognizers happen to
    /// finish (the pan often ends first and resets the mode).
    private var didZoom = false
    private var lastScrollTranslation = CGPoint.zero
    private var pendingScroll = CGPoint.zero
    private var scrollLocation = CGPoint.zero
    private var momentum = CGPoint.zero

    private var dragLocation: CGPoint?
    private var lastSentMove: TimeInterval = 0
    private var displayLink: CADisplayLink?

    private let ring = CAShapeLayer()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let grabHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        tap.addTarget(self, action: #selector(handleTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap(_:)))

        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 10
        hold.addTarget(self, action: #selector(handleHold(_:)))
        hold.isEnabled = false

        onePan.maximumNumberOfTouches = 1
        onePan.addTarget(self, action: #selector(handleOnePan(_:)))

        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.addTarget(self, action: #selector(handleTwoPan(_:)))
        pinch.addTarget(self, action: #selector(handlePinch(_:)))

        for recognizer in [tap, twoFingerTap, hold, onePan, twoPan, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        ring.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 2
        ring.path = UIBezierPath(ovalIn: CGRect(x: -26, y: -26, width: 52, height: 52)).cgPath
        ring.opacity = 0
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { displayLink?.invalidate() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A new touch catches a gliding scroll, like on a trackpad.
        momentum = .zero
        super.touchesBegan(touches, with: event)
    }

    // MARK: Recognizer arbitration

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Scroll and pinch both watch two fingers; the mode decides which one acts.
        let pair: Set<UIGestureRecognizer> = [twoPan, pinch]
        return pair.contains(gestureRecognizer) && pair.contains(other)
    }


    // MARK: Tap

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        let location = recognizer.location(in: self)
        let now = ProcessInfo.processInfo.systemUptime
        var count = 1
        if supportsPointer, let last = lastTap,
           now - last.time <= Self.multiClickInterval,
           hypot(location.x - last.location.x, location.y - last.location.y) <= Self.multiClickDistance {
            count = min(last.count + 1, 3)
        }
        // Later taps in a series click where the first one did, like a mouse that stays put.
        let target = count > 1 ? lastTap?.location ?? location : location
        lastTap = (now, target, count)
        actions?.click(target, count, rightButton)
        haptic.impactOccurred(intensity: count > 1 ? 0.8 : 0.6)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        lastTap = nil
        actions?.click(recognizer.location(in: self), 1, true)
        haptic.impactOccurred()
    }

    // MARK: Hold and drag

    /// Where a hold began, while it waits to become a drag (the finger moves) or a right
    /// click (the finger lifts without moving).
    private var holdOrigin: CGPoint?
    /// A finger this far from where the hold began has started a drag.
    private static let dragStartDistance: CGFloat = 6

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            // Ready, nothing sent yet: the Mac's button goes down only once the finger moves.
            stopMomentum()
            lastTap = nil
            holdOrigin = location
            grabHaptic.impactOccurred()
            showRing(at: location)
        case .changed:
            if dragLocation == nil, let origin = holdOrigin {
                guard hypot(location.x - origin.x, location.y - origin.y) >= Self.dragStartDistance else { return }
                // Moving: press where the finger first came down, then follow it.
                actions?.pointer(.down, origin)
                dragLocation = origin
                startDisplayLink()
            }
            dragLocation = location
            moveRing(to: location)
            let now = ProcessInfo.processInfo.systemUptime
            // About 60 moves a second is plenty for the Mac and keeps the channel light.
            if now - lastSentMove >= 1.0 / 60 {
                lastSentMove = now
                actions?.pointer(.move, location)
            }
        case .ended:
            if dragLocation != nil {
                actions?.pointer(.up, location)
            } else if let origin = holdOrigin {
                // Held still and lifted: a right click, like a long-press opens a context
                // menu on iOS.
                actions?.click(origin, 1, true)
                haptic.impactOccurred()
            }
            endHold()
        case .cancelled, .failed:
            if dragLocation != nil { actions?.pointer(.up, location) }
            endHold()
        default:
            break
        }
    }

    private func endHold() {
        holdOrigin = nil
        dragLocation = nil
        hideRing()
        stopDisplayLinkIfIdle()
    }

    /// While dragging near the edge of a zoomed view, slide the view so the drag can
    /// carry on past what is visible.
    private func edgeNudge() {
        guard let location = dragLocation, !isViewLocked else { return }
        let margin: CGFloat = 44
        let speed: CGFloat = 9
        var delta = CGSize.zero
        if location.x < margin { delta.width = speed * (1 - location.x / margin) }
        if location.x > bounds.width - margin { delta.width = -speed * (1 - (bounds.width - location.x) / margin) }
        if location.y < margin { delta.height = speed * (1 - location.y / margin) }
        if location.y > bounds.height - margin { delta.height = -speed * (1 - (bounds.height - location.y) / margin) }
        guard delta != .zero, actions?.nudgeView(delta) == true else { return }
        // Same finger position, new spot on the Mac under it.
        actions?.pointer(.move, location)
    }

    // MARK: One-finger pan

    @objc private func handleOnePan(_ recognizer: UIPanGestureRecognizer) {
        guard !isViewLocked else { return }
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            stopMomentum()
            lastTap = nil
            actions?.panView(CGSize(width: translation.x, height: translation.y), false)
        case .changed:
            actions?.panView(CGSize(width: translation.x, height: translation.y), false)
        case .ended, .cancelled, .failed:
            actions?.panView(CGSize(width: translation.x, height: translation.y), true)
        default:
            break
        }
    }

    // MARK: Two fingers: scroll or zoom

    @objc private func handleTwoPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began:
            stopMomentum()
            lastTap = nil
            lastScrollTranslation = .zero
            scrollLocation = recognizer.location(in: self)
        case .changed:
            if twoFingerMode == .undecided, hypot(translation.x, translation.y) > 12 {
                twoFingerMode = supportsPointer ? .scroll : .zoom
            }
            if twoFingerMode == .zoom {
                // While pinching, two fingers also move the view, as outside click mode.
                if !isViewLocked { actions?.panView(CGSize(width: translation.x, height: translation.y), false) }
                return
            }
            guard twoFingerMode == .scroll else { return }
            pendingScroll.x += translation.x - lastScrollTranslation.x
            pendingScroll.y += translation.y - lastScrollTranslation.y
            lastScrollTranslation = translation
            startDisplayLink()
        case .ended, .cancelled, .failed:
            if (twoFingerMode == .zoom || didZoom), !isViewLocked {
                actions?.panView(CGSize(width: translation.x, height: translation.y), true)
            }
            if twoFingerMode == .scroll {
                // Let the content glide on like a trackpad flick.
                let velocity = recognizer.velocity(in: self)
                momentum = CGPoint(x: velocity.x / 60, y: velocity.y / 60)
                startDisplayLink()
            }
            endTwoFingerGestureIfDone()
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            didZoom = false
        case .changed:
            if twoFingerMode == .undecided, abs(recognizer.scale - 1) > 0.08 {
                twoFingerMode = .zoom
            }
            guard twoFingerMode == .zoom, !isViewLocked else { return }
            didZoom = true
            actions?.zoomView(recognizer.scale, false)
        case .ended, .cancelled, .failed:
            if didZoom, !isViewLocked { actions?.zoomView(recognizer.scale, true) }
            didZoom = false
            endTwoFingerGestureIfDone()
        default:
            break
        }
    }

    private func endTwoFingerGestureIfDone() {
        let active: Set<UIGestureRecognizer.State> = [.began, .changed]
        if !active.contains(twoPan.state), !active.contains(pinch.state) {
            twoFingerMode = .undecided
        }
    }

    // MARK: Per-frame work: scroll batching, momentum, edge nudging

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        if dragLocation == nil, pendingScroll == .zero, momentum == .zero {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func stopMomentum() {
        momentum = .zero
        stopDisplayLinkIfIdle()
    }

    @objc private func frame(_ link: CADisplayLink) {
        if dragLocation != nil { edgeNudge() }

        if momentum != .zero, twoPan.state != .changed {
            pendingScroll.x += momentum.x
            pendingScroll.y += momentum.y
            momentum.x *= 0.92
            momentum.y *= 0.92
            if hypot(momentum.x, momentum.y) < 0.5 { momentum = .zero }
        }
        if pendingScroll != .zero {
            // The Mac's pixels are denser than the phone's view of them.
            let gain: CGFloat = 2
            actions?.scroll(scrollLocation, pendingScroll.x * gain, pendingScroll.y * gain)
            pendingScroll = .zero
        }
        stopDisplayLinkIfIdle()
    }

    // MARK: Drag ring

    private func showRing(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = point
        ring.transform = CATransform3DMakeScale(0.6, 0.6, 1)
        CATransaction.commit()
        ring.opacity = 1
        ring.transform = CATransform3DIdentity
    }

    private func moveRing(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = point
        CATransaction.commit()
    }

    private func hideRing() {
        ring.opacity = 0
    }
}

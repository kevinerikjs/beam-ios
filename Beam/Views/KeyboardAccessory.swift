import Phoros
import SwiftUI
import UIKit

struct KeyboardAccessoryView: View {
    @ObservedObject var appState: BeamAppState
    /// The window's left and right safe-area insets. The bar ignores safe areas (the keyboard
    /// would otherwise push its keys out of place), so in landscape it keeps the keys clear of
    /// the notch itself, as the system keyboard does.
    var sideInsets: (leading: CGFloat, trailing: CGFloat) = (0, 0)

    static let height = KeyboardAccessoryInputView.accessoryHeight
    // Keycaps sit on the same 6 pt gutter grid as the system keyboard's top row, so the
    // ten keys of the first page line up with Q through P underneath them.
    fileprivate static let sideInset: CGFloat = 3.5
    fileprivate static let keyGap: CGFloat = 3
    fileprivate static let keyTop: CGFloat = 6.5
    fileprivate static let keyBottom: CGFloat = 11

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                frequentKeysPage.frame(width: width)
                navigationKeysPage.frame(width: width)
                functionKeysPage.frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(appState.keyboardAccessoryPage) * width + dragOffset)
            .simultaneousGesture(pageSwipe(width: width))
        }
        .frame(height: Self.height)
        // Same outline as the bar's backing, so a key sliding in during a page swipe
        // never shows past the rounded shoulders.
        .clipShape(TopRoundedRectangle(radius: KeyboardAccessoryInputView.topCornerRadius))
        .overlay(alignment: .bottom) { pageDots }
        .ignoresSafeArea()
    }

    // MARK: Pages

    private var frequentKeysPage: some View {
        keyRow {
            textKey("esc", accessibilityLabel: "Escape", key: .escape)
            textKey("tab", accessibilityLabel: "Tab", key: .tab)
            modifierKey("ctrl", symbol: "control", accessibilityLabel: "Control")
            modifierKey("alt", symbol: "option", accessibilityLabel: "Option")
            modifierKey("shift", symbol: "shift", accessibilityLabel: "Shift")
            modifierKey("cmd", symbol: "command", accessibilityLabel: "Command")
            symbolKey("arrow.left", accessibilityLabel: "Left Arrow", key: .leftArrow)
            symbolKey("arrow.up", accessibilityLabel: "Up Arrow", key: .upArrow)
            symbolKey("arrow.down", accessibilityLabel: "Down Arrow", key: .downArrow)
            symbolKey("arrow.right", accessibilityLabel: "Right Arrow", key: .rightArrow)
        }
    }

    private var navigationKeysPage: some View {
        keyRow {
            textKey("home", accessibilityLabel: "Home", key: .home)
            textKey("end", accessibilityLabel: "End", key: .end)
            textKey("pg up", accessibilityLabel: "Page Up", key: .pageUp)
            textKey("pg dn", accessibilityLabel: "Page Down", key: .pageDown)
            symbolKey("delete.right", accessibilityLabel: "Forward Delete", key: .forwardDelete)
        }
    }

    private var functionKeysPage: some View {
        keyRow {
            ForEach(SpecialKey.functionKeys, id: \.self) { key in
                AccessoryKey(accessibilityLabel: key.rawValue.uppercased(), onPress: haptic, onTrigger: { send(key) }) {
                    Text(key.rawValue.uppercased())
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private func keyRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.leading, Self.sideInset + sideInsets.leading)
            .padding(.trailing, Self.sideInset + sideInsets.trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Keys

    private func textKey(_ title: String, accessibilityLabel: String, key: SpecialKey) -> some View {
        AccessoryKey(accessibilityLabel: accessibilityLabel, onPress: haptic, onTrigger: { send(key) }) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func symbolKey(_ systemName: String, accessibilityLabel: String, key: SpecialKey) -> some View {
        AccessoryKey(
            accessibilityLabel: accessibilityLabel,
            repeats: true,
            onPress: haptic,
            onTrigger: { send(key) }
        ) {
            Image(systemName: systemName).font(.system(size: 15, weight: .medium))
        }
    }

    /// Tap: on for the next key, then off. Long press: locked (orange) for any number of
    /// chords until tapped again.
    private func modifierKey(_ wireName: String, symbol: String, accessibilityLabel: String) -> some View {
        let state = appState.keyboardModifierState(for: wireName)
        return AccessoryKey(
            isLit: state != .off,
            isLocked: state == .locked,
            accessibilityLabel: "\(accessibilityLabel) Modifier",
            accessibilityValue: modifierStateLabel(state),
            onPress: haptic,
            onTrigger: { appState.tapKeyboardModifier(wireName) },
            onLongPress: {
                appState.lockKeyboardModifier(wireName)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        ) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: Paging

    private static let pageCount = 3

    private func pageSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                let page = appState.keyboardAccessoryPage
                let pastEdge = (page == 0 && dx > 0) || (page == Self.pageCount - 1 && dx < 0)
                dragOffset = pastEdge ? dx * 0.2 : dx
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                var page = appState.keyboardAccessoryPage
                if predicted < -width * 0.3 { page = min(page + 1, Self.pageCount - 1) }
                if predicted > width * 0.3 { page = max(page - 1, 0) }
                if page != appState.keyboardAccessoryPage {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                    appState.keyboardAccessoryPage = page
                    dragOffset = 0
                }
            }
    }

    /// Two faint dots in the gutter under the keys: no height of their own.
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == appState.keyboardAccessoryPage ? 0.5 : 0.18))
                    .frame(width: 3.5, height: 3.5)
            }
        }
        .frame(height: Self.keyBottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keys page \(appState.keyboardAccessoryPage + 1) of \(Self.pageCount)")
        .accessibilityAdjustableAction { direction in
            let page = appState.keyboardAccessoryPage
            switch direction {
            case .increment: appState.keyboardAccessoryPage = min(page + 1, Self.pageCount - 1)
            case .decrement: appState.keyboardAccessoryPage = max(page - 1, 0)
            @unknown default: break
            }
        }
    }

    // MARK: Helpers

    private func modifierStateLabel(_ state: KeyboardModifierState) -> String {
        switch state {
        case .off: return "Off"
        case .armed: return "On for the next key"
        case .locked: return "Locked"
        }
    }

    private func send(_ key: SpecialKey) {
        appState.sendLiveKeyboardSpecialKey(key)
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// One keycap styled like the system keyboard's keys. The whole slot (keycap plus its
/// share of the gutters) is the hit area. Keys fire on release like system keys do, a
/// drag that turns into a page swipe cancels the press, and repeating keys auto-repeat
/// while held.
private struct AccessoryKey<Label: View>: View {
    var isLit = false
    var isLocked = false
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    var repeats = false
    var onPress: () -> Void = {}
    var onTrigger: () -> Void = {}
    var onLongPress: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    @State private var isPressed = false
    @State private var isCancelled = false
    @State private var didRepeat = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var didLongPress = false
    @State private var longPressTask: Task<Void, Never>?

    private var cancelDistance: CGFloat { 10 }

    var body: some View {
        label()
            .foregroundStyle(isLit ? Color.black : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
            )
            .padding(.horizontal, KeyboardAccessoryView.keyGap)
            .padding(.top, KeyboardAccessoryView.keyTop)
            .padding(.bottom, KeyboardAccessoryView.keyBottom)
            .contentShape(Rectangle())
            .gesture(press)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue ?? "")
            .accessibilityAddTraits(isLit ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                onPress()
                onTrigger()
            }
            .accessibilityAction(named: "Lock") { onLongPress?() }
            .onDisappear { finish(cancelled: true) }
    }

    private var fill: Color {
        if isLocked { return isPressed ? Color.orange.opacity(0.75) : .orange }
        switch (isLit, isPressed) {
        case (true, false): return .white
        case (true, true): return Color(white: 0.78)
        case (false, false): return Color(white: 0.24)
        case (false, true): return Color(white: 0.4)
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !isCancelled else { return }
                if !isPressed {
                    isPressed = true
                    onPress()
                    startRepeating()
                    startLongPress()
                }
                if abs(value.translation.width) > cancelDistance
                    || abs(value.translation.height) > cancelDistance * 1.5 {
                    isCancelled = true
                    finish(cancelled: true)
                }
            }
            .onEnded { _ in
                if !isCancelled { finish(cancelled: false) }
                isCancelled = false
            }
    }

    private func startRepeating() {
        guard repeats else { return }
        didRepeat = false
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            while !Task.isCancelled {
                onTrigger()
                didRepeat = true
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    private func startLongPress() {
        guard let onLongPress else { return }
        didLongPress = false
        longPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            didLongPress = true
            onLongPress()
        }
    }

    private func finish(cancelled: Bool) {
        guard isPressed else { return }
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
        longPressTask?.cancel()
        longPressTask = nil
        if !cancelled && !didRepeat && !didLongPress { onTrigger() }
        didRepeat = false
        didLongPress = false
    }
}

/// A rectangle with only its top corners rounded, circular like the bar's backing path
/// (`UnevenRoundedRectangle` needs iOS 17).
private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum KeyboardShellSurface {
    static let uiColor = UIColor(
        red: 23.0 / 255.0,
        green: 23.0 / 255.0,
        blue: 23.0 / 255.0,
        alpha: 1
    )
    static let color = Color(uiColor: uiColor)
}

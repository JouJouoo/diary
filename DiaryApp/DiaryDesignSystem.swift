import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Font {
    static func appSystem(_ style: TextStyle, design: Design = .default, weight: Weight = .regular) -> Font {
        #if os(iOS) && targetEnvironment(simulator)
        return .custom("Noto Sans SC", size: style.fallbackSize, relativeTo: style).weight(weight)
        #else
        return .system(style, design: design, weight: weight)
        #endif
    }

    static func appSystem(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        #if os(iOS) && targetEnvironment(simulator)
        return .custom("Noto Sans SC", size: size).weight(weight)
        #else
        return .system(size: size, weight: weight, design: design)
        #endif
    }
}

private extension Font.TextStyle {
    var fallbackSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}

enum DiaryStyle {
    static let ink = Color.primary
    static let muted = Color.secondary
    static var historyDateFont: Font {
#if os(macOS)
        .appSystem(.body, design: .rounded)
#else
        .appSystem(.footnote, design: .rounded)
#endif
    }
    static var historyTitleFont: Font {
#if os(macOS)
        .appSystem(.title3, design: .rounded, weight: .semibold)
#else
        .appSystem(.body, design: .rounded, weight: .medium)
#endif
    }
    static var historyTagFont: Font {
#if os(macOS)
        .appSystem(.subheadline, design: .rounded, weight: .medium)
#else
        .appSystem(.caption2, design: .rounded, weight: .medium)
#endif
    }
    static var diaryDateFont: Font {
#if os(macOS)
        .appSystem(.title3, design: .rounded)
#else
        .appSystem(.subheadline, design: .rounded)
#endif
    }
    static var diaryTitleFont: Font {
#if os(macOS)
        .appSystem(size: 40, weight: .medium, design: .serif)
#else
        .appSystem(.largeTitle, design: .serif, weight: .medium)
#endif
    }
    static var diaryContentFont: Font {
#if os(macOS)
        .appSystem(size: 20, design: .serif)
#else
        .appSystem(.body, design: .serif)
#endif
    }
    static var diaryContentLineSpacing: CGFloat {
#if os(macOS)
        11
#else
        8
#endif
    }
#if os(macOS)
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let secondaryPaper = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
#else
    static let paper = Color(uiColor: .systemBackground)
    static let secondaryPaper = Color(uiColor: .secondarySystemBackground)
    static let line = Color(uiColor: .separator)
#endif
}

struct SystemGlass: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #else
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}

struct SystemGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
#else
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
#endif
    }
}

struct SystemProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

struct SystemSecondaryButton: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

struct InlineNavigationTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

struct HiddenNavigationBar: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar(.hidden, for: .navigationBar)
        #else
        content
        #endif
    }
}

struct CalendarSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.presentationDetents([.large]).presentationDragIndicator(.visible)
        #else
        content
        #endif
    }
}

struct NoAutocorrection: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content
        #endif
    }
}

struct EmailKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.keyboardType(.emailAddress)
        #else
        content
        #endif
    }
}

struct DismissKeyboardOnOutsideTap: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content.background {
            KeyboardOutsideTapInstaller()
                .allowsHitTesting(false)
        }
#else
        content
#endif
    }
}

#if os(iOS)
private struct KeyboardOutsideTapInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardOutsideTapView {
        KeyboardOutsideTapView()
    }

    func updateUIView(_ uiView: KeyboardOutsideTapView, context: Context) {}
}

private final class KeyboardOutsideTapView: UIView, UIGestureRecognizerDelegate {
    private weak var attachedWindow: UIWindow?
    private var tapRecognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard attachedWindow !== window else { return }
        if let tapRecognizer { attachedWindow?.removeGestureRecognizer(tapRecognizer) }
        attachedWindow = window
        guard let window else { return }

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        tapRecognizer = recognizer
    }

    @objc private func handleOutsideTap(_ recognizer: UITapGestureRecognizer) {
        guard let window = attachedWindow else { return }
        let point = recognizer.location(in: window)
        let touchedView = window.hitTest(point, with: nil)
        guard !isTextInput(touchedView) else { return }
        window.endEditing(true)
    }

    private func isTextInput(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UITextField || candidate is UITextView { return true }
            current = candidate.superview
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

struct SwipeBackGesture: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -100 { action() }
        })
        #else
        content
        #endif
    }
}

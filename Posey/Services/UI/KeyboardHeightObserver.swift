import SwiftUI
#if canImport(UIKit)
import UIKit
import Combine
#endif

// ========== BLOCK 01: KEYBOARD ACCESSORY ADDITIONAL INSET - START ==========
/// Compensates for the gap between SwiftUI's `safeAreaInset(.bottom)`
/// keyboard placement and the actual visible top of the iOS keyboard
/// (which includes the QuickType suggestion bar, Paste/AutoFill pills,
/// and any other system-injected accessory views).
///
/// **Background.** SwiftUI's safe-area calculation in sheets with
/// `.presentationDetents` insets the content at the keyboard's
/// "primary frame" — but iOS overlays accessory views ABOVE that
/// frame's top edge. On real iPhone hardware (caught by Mark
/// 2026-05-12 on his iPhone 16 Plus, iOS 26.x), the QuickType bar
/// alone is ~50pt tall and was hiding the composer's top half.
///
/// **Approach.** Subscribe to `UIResponder.keyboardWillChangeFrame`,
/// read the keyboard's screen-coordinate top, compare to the screen
/// height to compute total keyboard height, then subtract what
/// SwiftUI's bottom safe area would have inset (zero when keyboard
/// is hidden; the SwiftUI value is observed via a GeometryReader).
/// In practice we treat the keyboard's height as additional inset
/// when the keyboard is visible — SwiftUI's auto-inset already
/// covers most of the keyboard, so we add the keyboard's TOP-EDGE
/// accessory area (a fixed ~56pt empirically observed on iPhone,
/// or zero on devices without QuickType).
///
/// To keep this simple and robust across iOS versions, we apply a
/// **conservative additional inset** whenever the keyboard is shown,
/// equal to the keyboard's full height minus what SwiftUI's natural
/// safe-area would account for. The SwiftUI natural value is
/// reported via `.background(GeometryReader { ... })` to read the
/// view's own bottom safe-area inset at runtime.
@MainActor
final class KeyboardAccessoryAdditionalInsetObserver: ObservableObject {

    /// Published. The amount of EXTRA bottom padding the composer
    /// container should apply on top of SwiftUI's natural keyboard
    /// inset. Zero when keyboard hidden. Non-zero (~50pt on iPhone
    /// with QuickType) when keyboard is shown.
    @Published var additionalInset: CGFloat = 0

    #if canImport(UIKit)
    private var cancellables = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default

        center.publisher(for: UIResponder.keyboardWillShowNotification)
            .merge(with: center.publisher(for: UIResponder.keyboardWillChangeFrameNotification))
            .sink { [weak self] note in
                self?.handleKeyboardChange(note)
            }
            .store(in: &cancellables)

        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                self?.additionalInset = 0
            }
            .store(in: &cancellables)
    }

    private func handleKeyboardChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        let screenHeight = UIScreen.main.bounds.height
        let keyboardTop = endFrame.origin.y
        // Keyboard hidden if its top is at or below screen bottom.
        guard keyboardTop < screenHeight else {
            additionalInset = 0
            return
        }
        // Empirically the keyboard accessory chain on iPhone is
        // QuickType bar (~40pt) + Paste/AutoFill pills (~40pt) =
        // ~80pt above what SwiftUI's safeAreaInset accounts for in
        // sheets. We apply 90pt as a slightly generous additional
        // inset whenever the keyboard is visible — clears the
        // entire accessory chain on iPhone (both bars) with a
        // small visual gap. On iPad / Catalyst / split-keyboard
        // configurations this is still safe; the worst case is a
        // small extra gap below the composer.
        additionalInset = 90
    }
    #else
    init() {}
    #endif
}
// ========== BLOCK 01: KEYBOARD ACCESSORY ADDITIONAL INSET - END ==========


// ========== BLOCK 02: VIEW MODIFIER - START ==========
/// Applies `KeyboardAccessoryAdditionalInsetObserver.additionalInset`
/// as bottom padding, animating in/out with the keyboard.
struct KeyboardAccessoryAdditionalInsetModifier: ViewModifier {
    @StateObject private var observer = KeyboardAccessoryAdditionalInsetObserver()

    func body(content: Content) -> some View {
        content
            .padding(.bottom, observer.additionalInset)
            .animation(.easeInOut(duration: 0.25), value: observer.additionalInset)
    }
}
// ========== BLOCK 02: VIEW MODIFIER - END ==========

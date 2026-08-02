import SwiftUI

/// Controllable-speed animation for a bottom sheet's height.
///
/// There are two ways to move a sheet between detents and they honor a custom curve
/// differently. Animating the `CGFloat` behind a single `.height()` detent honors an
/// arbitrary spring/duration reliably (SwiftUI interpolates the value under your
/// transaction and re-applies the detent every frame). Changing a bound
/// `PresentationDetent` (the `selection:` form) only *loosely* honors it — the
/// inter-detent resize uses `UISheetPresentationController`'s own system spring.
///
/// `DynamicDetentSheetModel` therefore owns the measured, content-hugging height and
/// animates every resize with a caller-supplied curve via the value-animated path.
/// `SelectableDetentSheet` wraps the selection form for the fixed `.medium`/`.large`
/// case, where the system spring is fine.
///
/// iOS 17+ (`@Observable`, `withAnimation(_:completion:)`); the scroll measurement
/// primitive is iOS 18+ with a `GeometryReader` fallback for older content.

// MARK: - DynamicDetentSheetModel

@MainActor
@Observable
final class DynamicDetentSheetModel {

    /// The height committed to the sheet's `.height()` detent. Only the
    /// `DynamicHeightDetent` modifier body reads this, so a resize invalidates just
    /// that modifier — not the whole sheet body.
    private(set) var detentHeight: CGFloat

    /// The single curve that drives every resize. The caller owns it fully — set a
    /// slower/heavier spring here to fix a "too fast" resize.
    var animation: Animation

    /// Fixed chrome (nav bar/header + grabber + home-indicator inset) added on top of
    /// measured CONTENT height so the sheet is exactly tall enough and never clips.
    var chrome: CGFloat

    /// Floor so a nearly-empty pane never collapses to a sliver.
    var minimumContentHeight: CGFloat

    /// Cached measured content heights, keyed by each pane's OWN identity. Background
    /// panes populate this WITHOUT resizing. We store the numeric height because you
    /// cannot read the `CGFloat` back out of a `PresentationDetent`, and we need it
    /// for the >= 1pt threshold that breaks the measurement feedback loop.
    private var measured: [AnyHashable: CGFloat] = [:]

    /// Identity of the pane currently ON TOP. Only its measurements resize the sheet.
    private var activeKey: AnyHashable?

    /// First sizing snaps (clean present at the right height); later ones animate.
    private var hasSettled = false

    /// True while an animated resize is in flight. Guards against a mid-flight
    /// re-measure restarting the spring; cleared (and reconciled) on real completion.
    private var isResizing = false

    init(initialHeight: CGFloat = 320,
         chrome: CGFloat = 0,
         minimumContentHeight: CGFloat = 0,
         animation: Animation = .spring(duration: 0.45, bounce: 0.1)) {
        self.detentHeight = initialHeight
        self.chrome = chrome
        self.minimumContentHeight = minimumContentHeight
        self.animation = animation
    }

    private func resolved(_ content: CGFloat) -> CGFloat {
        max(minimumContentHeight, content) + chrome
    }

    /// Whether a pane already has a cached intrinsic height. Callers can use this
    /// to choose between a fully synchronized cached resize and a lazy first-open
    /// transition whose visible measurement starts the resize a frame later.
    func hasMeasurement<Key: Hashable>(for key: Key) -> Bool {
        measured[AnyHashable(key)] != nil
    }

    /// Raw measurement from a pane's scroll/intrinsic geometry. Cheap + idempotent:
    /// rounded, thresholded, cached under the pane's key, and it only commits an
    /// ANIMATED resize when the reporting pane is the ACTIVE one. A late measurement
    /// of an off-screen pane can therefore never kick off a competing resize.
    func report<Key: Hashable>(height rawContent: CGFloat, for key: Key) {
        let rounded = rawContent.rounded()
        let k = AnyHashable(key)
        if let existing = measured[k], abs(existing - rounded) < 1 { return }  // dedup
        measured[k] = rounded

        guard k == activeKey else { return }   // background pane: cache only
        guard !isResizing else { return }      // don't restart mid-flight — settle() reconciles
        commit(resolved(rounded))
    }

    /// Switch the on-top pane AND resize to its cached height. Call this INSIDE
    /// `animatingResize` together with your content change (e.g. `selected = section`)
    /// so the content transition and the resize start as ONE motion. Falls back to the
    /// current height when the incoming pane was never measured (first open is a single
    /// two-step: transition now, exact fit on the pane's first measurement).
    func activate<Key: Hashable>(_ key: Key) {
        let k = AnyHashable(key)
        activeKey = k
        detentHeight = resolved(measured[k] ?? (detentHeight - chrome))
    }

    /// Run `changes` (your content transition + `activate`, or an in-place resize)
    /// under the model's curve, and clear the in-flight guard on the animation's REAL
    /// completion, reconciling any measurement that landed mid-flight. Put the detent
    /// change AND any in-sheet `.transition` change in the same `changes` closure so
    /// they ride one transaction and never fight.
    func animatingResize(_ changes: () -> Void) {
        isResizing = true
        // The completion runs on the main run loop; the model is @MainActor, so hop
        // back into isolation to reconcile.
        withAnimation(animation) {
            changes()
        } completion: {
            MainActor.assumeIsolated { self.settle() }
        }
    }

    private func commit(_ target: CGFloat) {
        guard abs(target - detentHeight) >= 1 else { return }
        if hasSettled {
            animatingResize { self.detentHeight = target }
        } else {
            hasSettled = true
            detentHeight = target               // clean present: snap, no launch animation
        }
    }

    /// Completion hook: drop the in-flight guard, then commit any measurement that
    /// arrived (and was cached but skipped) while the last resize was animating.
    private func settle() {
        isResizing = false
        guard let k = activeKey, let latest = measured[k] else { return }
        commit(resolved(latest))
    }
}

// MARK: - Dynamic-height detent modifier (curve honored)

/// Applies a single content-hugging `.height()` detent driven by the model. Only THIS
/// body reads `model.detentHeight`, so an animated height change re-evaluates only the
/// modifier and rides whatever transaction mutated the height.
struct DynamicHeightDetent: ViewModifier {
    let model: DynamicDetentSheetModel
    var dragIndicator: Visibility = .visible

    func body(content: Content) -> some View {
        content
            .presentationDetents([.height(model.detentHeight)])
            .presentationDragIndicator(dragIndicator)
    }
}

extension View {
    /// Drive this sheet's height from a `DynamicDetentSheetModel` (curve-controlled).
    func dynamicHeightDetents(_ model: DynamicDetentSheetModel,
                              dragIndicator: Visibility = .visible) -> some View {
        modifier(DynamicHeightDetent(model: model, dragIndicator: dragIndicator))
    }

    /// Report a SCROLLABLE pane's real content height under `key` (iOS 18+). Feedback
    /// free: `contentSize` is INTRINSIC, so resizing the sheet does not change it — the
    /// "update multiple times per frame" loop cannot form.
    @available(iOS 18.0, *)
    func measuredDetentHeight<Key: Hashable>(
        _ key: Key, into model: DynamicDetentSheetModel
    ) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            model.report(height: height, for: key)
        }
    }

    /// Measure NON-scroll / intrinsic content, or an iOS 16–17 fallback for the scroll
    /// case. A background `GeometryReader` never joins layout, so it cannot create a loop.
    func measuredIntrinsicDetentHeight<Key: Hashable>(
        _ key: Key, into model: DynamicDetentSheetModel
    ) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.report(height: proxy.size.height, for: key) }
                    .onChange(of: proxy.size.height) { _, h in
                        model.report(height: h, for: key)
                    }
            }
        )
    }
}

// MARK: - Selection-binding detents (fixed .medium/.large; curve NOT precisely honored)

/// Wraps the `presentationDetents(_:selection:)` API for the FIXED-detent case: a
/// `Binding<PresentationDetent>`. Changing `selection` inside `withAnimation` animates,
/// but the resize uses the system spring, so a custom duration/curve is only loosely
/// applied — use `DynamicDetentSheetModel` when you need a dialable curve.
///
/// INVARIANT: the set handed to SwiftUI ALWAYS contains the current selection, so a
/// programmatic selection can never point outside the set and trigger the "selected
/// detent not in Set" fallback-snap.
struct SelectableDetentSheet: ViewModifier {
    let detents: Set<PresentationDetent>
    @Binding var selection: PresentationDetent
    var dragIndicator: Visibility = .visible

    private var resolvedDetents: Set<PresentationDetent> { detents.union([selection]) }

    func body(content: Content) -> some View {
        content
            .presentationDetents(resolvedDetents, selection: $selection)
            .presentationDragIndicator(dragIndicator)
    }
}

extension View {
    /// Snap between fixed detents with a `Binding`. The custom curve is delegated to
    /// the system spring (see `SelectableDetentSheet`).
    func selectableDetents(_ detents: Set<PresentationDetent>,
                           selection: Binding<PresentationDetent>,
                           dragIndicator: Visibility = .visible) -> some View {
        modifier(SelectableDetentSheet(detents: detents,
                                       selection: selection,
                                       dragIndicator: dragIndicator))
    }
}

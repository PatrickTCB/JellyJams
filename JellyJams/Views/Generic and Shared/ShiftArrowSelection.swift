import SwiftUI

/// Shift-arrow range selection for a List bound to a `Set<String>` selection,
/// the way every Mac table behaves: the anchor stays where the selection
/// started — the last single-row selection — while the lead moves one row
/// per press (repeating while the key is held), and the selection spans the
/// two. Extending past the lead and back shrinks the same range rather than
/// growing a second one.
///
/// Plain arrows are left to the List's own single-row selection move, and
/// mouse shift-clicks and cmd-clicks keep the List's native behaviour; this
/// only adds the keyboard equivalent. A no-op outside macOS.
///
/// Also keeps keyboard focus on the list: in a sidebar-adaptable `TabView` a
/// click on a row updates the selection but leaves focus in the sidebar, so
/// the arrows, shift-arrows and escape below would never arrive. Whenever the
/// selection becomes non-empty the list claims focus, which is what a click
/// on a row should feel like anyway.
struct ShiftArrowSelection: ViewModifier {
    /// The List's selection — the same set the List itself is bound to.
    @Binding var selection: Set<String>
    /// The rows' ids in list order. Re-evaluated by the parent on every
    /// render, so a list that loads, reorders or pages underneath stays
    /// correct mid-extension.
    var ids: [String]

    /// The row where the current extension started.
    @State private var anchor: String?
    /// The moving end of the extension.
    @State private var lead: String?
    /// True only while shift-arrow itself is rewriting the selection, so the
    /// observer below re-anchors on clicks — not on the ranges it produced.
    @State private var isExtendingSelection = false
    #if os(macOS)
    /// Keyboard focus, claimed on selection so the list — not the sidebar —
    /// receives the keys.
    @FocusState private var isListFocused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .focused($isListFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                extend(from: press)
            }
            .onChange(of: selection) { _, newSelection in
                // A click selects the row but leaves focus wherever it was
                // (usually the sidebar); pull it here so keyboard selection
                // and escape work on the list the user is looking at.
                if !newSelection.isEmpty { isListFocused = true }
                // Clicks and plain arrows re-anchor: an extension always
                // starts at the row the user last settled on. Shift-arrow's
                // own writes are flagged and skip this, so its multi-row
                // ranges don't clobber the anchor they're extending from.
                // Mouse shift-clicks and cmd-clicks (a multi-row selection)
                // keep the current anchor.
                guard !isExtendingSelection else { return }
                switch newSelection.count {
                case 1:
                    anchor = newSelection.first
                    lead = newSelection.first
                case 0:
                    anchor = nil
                    lead = nil
                default:
                    break
                }
            }
        #else
        content
        #endif
    }

    #if os(macOS)
    /// One shift-arrow press, or `.ignored` when the key isn't ours to
    /// handle. The anchor is where the extension started (the last
    /// single-row selection, or the first row with nothing earlier); the lead
    /// moves one row within the list, and the selection becomes the span
    /// between the two.
    private func extend(from press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.shift) else { return .ignored }
        guard let anchorId = anchor ?? selection.first ?? ids.first,
              let anchorIndex = ids.firstIndex(of: anchorId)
        else { return .ignored }
        let leadIndex = ids.firstIndex(of: lead ?? anchorId) ?? anchorIndex

        let step: Int
        if press.key == .downArrow {
            step = 1
        } else if press.key == .upArrow {
            step = -1
        } else {
            return .ignored
        }
        guard let next = Self.extensionStep(ids: ids, anchor: anchorIndex, lead: leadIndex, step: step) else {
            return .ignored
        }
        // At the top or bottom row the clamped lead no longer moves; consume
        // the press anyway so it can't fall through and move the single
        // selection out from under the range.
        guard next.lead != leadIndex else { return .handled }

        isExtendingSelection = true
        lead = ids[next.lead]
        selection = next.selection
        // Reset after the selection observer has run, so this extension
        // isn't mistaken for a click when it commits.
        Task { @MainActor in isExtendingSelection = false }
        return .handled
    }

    /// The lead index and selection one shift-arrow step produces: the lead
    /// moves by `step` (±1) and clamps to the list's ends, and the selection
    /// spans it and the anchor. Nil when the positions don't name rows.
    static func extensionStep(
        ids: [String],
        anchor: Int,
        lead: Int,
        step: Int
    ) -> (lead: Int, selection: Set<String>)? {
        guard !ids.isEmpty, ids.indices.contains(anchor), ids.indices.contains(lead) else { return nil }
        let newLead = min(max(lead + step, 0), ids.count - 1)
        return (newLead, Set(ids[min(anchor, newLead)...max(anchor, newLead)]))
    }
    #endif
}

extension View {
    /// Adds shift-arrow range selection to a List; a no-op outside macOS.
    func shiftArrowSelection(_ selection: Binding<Set<String>>, ids: [String]) -> some View {
        modifier(ShiftArrowSelection(selection: selection, ids: ids))
    }
}

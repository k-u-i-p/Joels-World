import Foundation

/// Which NPC owns the portrait currently on screen, and who is allowed to take it down.
///
/// `HUDView` on iOS and `AdminAvatarView` on macOS cannot be one view — UIKit and AppKit share
/// no view type, and neither framework is available in the other's app. The *rule* they both
/// enforce can be shared, though, and it is subtle enough to be worth it: walking out of one
/// NPC's radius must not clear a portrait a different NPC has raised since
/// (`cleanupNpcUI`, `ui.js:22`, which matches on `data-npc-id`).
struct PortraitOwner {
    private(set) var sourceId: Int?

    /// True when nothing holds the portrait — which is also how a finished fade-out decides
    /// whether it is still safe to throw the image away.
    var isVacant: Bool { sourceId == nil }

    mutating func claim(_ sourceId: Int) {
        self.sourceId = sourceId
    }

    /// Whether a dismissal should go ahead, releasing the claim when it should. A nil
    /// `sourceId` is the unconditional `hideAvatar`, which any source may fire; an id only
    /// dismisses the portrait that id raised.
    mutating func release(_ sourceId: Int?) -> Bool {
        if let sourceId, self.sourceId != sourceId { return false }
        guard self.sourceId != nil else { return false }
        self.sourceId = nil
        return true
    }
}

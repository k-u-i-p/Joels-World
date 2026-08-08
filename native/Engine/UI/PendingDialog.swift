import Foundation

/// What a raised `DialogRequest` is still holding: the answer Yes has to run, and whether
/// there is anything to say No to.
///
/// The same reasoning as `PortraitOwner` — the two dialog views are per-toolkit, but the rule
/// they read from the request is one rule. `uiManager.showActionDialog` (`ui.js:52`) takes a
/// typed action *and* a bare callback, and a dialog with neither is informational: its single
/// button reads OK and there is no red button beside it.
struct PendingDialog {
    let isActionable: Bool

    private var confirmAction: DialogAction?
    private var handler: (() -> Void)?

    init(_ request: DialogRequest) {
        confirmAction = request.confirmAction
        handler = request.onConfirm
        isActionable = request.confirmAction != nil || request.onConfirm != nil
    }

    /// The empty prompt a dismissed view holds, so neither app needs an optional around this.
    static let none = PendingDialog(DialogRequest(text: ""))

    /// Hands back what Yes should run, and forgets it.
    ///
    /// Both views dismiss *before* calling this, so a handler that raises a second dialog —
    /// which the minigames' "play again?" does — is not torn down by the dismissal of the
    /// first.
    mutating func take() -> (action: DialogAction?, handler: (() -> Void)?) {
        defer {
            confirmAction = nil
            handler = nil
        }
        return (confirmAction, handler)
    }
}

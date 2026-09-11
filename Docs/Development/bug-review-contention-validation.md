# Native bug review context coordination

A native acceptance run confirmed `CatalogError.busy` during ticket-draft preparation. Background context reads shared the nonblocking catalog directory lock with foreground review operations. The session now cancels and awaits its current observer before foreground context validation and skips background ticks while review actions are busy. Context/source validation, cancellation, expiry and exact publication remain enforced. Failed publication is not automatically retried.

Safe UI error categories distinguish busy storage from ineligible review, missing evidence, scope mismatch, size limits and redaction failure. No underlying source data is included in these messages.

Validation on arm64 macOS 26.5.2 / Xcode 26.0:

- `TestResults/p2-11/monitor-coordination.xcresult`: three model/lifecycle tests and the known-ticket UI scenario passed, including draft preparation, reviewed publication and v2 after relaunch.
- `TestResults/p2-11/monitor-lifecycle-final.xcresult`: three tests passed, including twenty refreshes followed by automatic invalidation of a changed context, released ownership, and busy recovery without a history mutation.
- Documentation and staged diff checks pass. This change is Mac-only; prior Phase 2 iPhone acceptance passed 337 tests.

Earlier repetition failures include a separate offscreen picker interaction. This focused correction does not claim to fix that UI-test navigation issue or finish Phase 2 acceptance. Full diagnostic history remains in the pending Phase 2 acceptance record.

# Bug Registry compact filter layout

The user screenshot and recording showed four vertically stacked filters occupying excess space above the selected bug. The all-or-nothing horizontal/vertical layout now uses an adaptive grid with 250-point minimum cells and 8-point row spacing. The tested modal presents two rows, preserving all filter labels and controls while moving the list and inspector upward.

`TestResults/bug-filter-layout/native.xcresult`: native macOS 26.5.2, Xcode 26.0, one UI regression passed. It asserts the filter block stays below 80 points and preserves registry/selected-title top alignment. The explicit app-window screenshot was exported and visually inspected. This Mac-only layout change does not change shared business logic; no additional iPhone coverage is claimed. Documentation and diff checks passed.

The broader P2-11 run was intentionally interrupted for this user-requested fix after all 518 Mac unit tests passed. Its remaining UI acceptance is incomplete and must resume separately.

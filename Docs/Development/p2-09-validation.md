# P2-09 — CityPay bug-report skill

Implemented and verified, 2026-09-11.

The built-in `CityPayBugSkill` supplies version-1 instructions and synthetic JSON/Markdown refund examples. Saving through the existing skill store creates the normal scoped `skill.json`, `instructions.md` and example files with immutable revision pinning. It requests only `readEvidence`; it grants no mutation permission and contains no executable attachments.

`CityPayBugReport` provides a structured deterministic report path: explicit component/region, fixed permitted sections, supplied reproduction/API/operational details, current active requirement content and exact source references. It refuses missing context, unverified findings and unavailable requirements. This is a trusted Core formatter, not a redaction, evidence-validation or external-publication boundary.

Checks under ignored `TestResults/p2-09/`:

- `template-tests.log`: one installation/version-pinning/project-isolation test passed.
- `report-build.log`: initial formatter compilation and the template regression; no formatter behavior coverage is claimed by that test.
- `report-tests.log`: five tests passed (four report behavior tests plus template installation), covering current requirement text, exact values including large identifiers, fixed sections and missing/stale/blocked information.
- `runtime-build.log`: nine existing duplicate-review regressions passed after adding the report service.
- The first new service test exposed over-redaction: final JSON-string masking hid the nonsecret currency alongside a masked password. The service now renders prose after structured redaction and applies text redaction to that prose. `service-tests.log` records the rerun; it covers nested/top-level/requirement secrets, duplicate denial, explicit distinct review and stale-source invalidation.
- `group-tests.log`: five report tests passed, including grouped source labeling, individual payload/result preservation and rejection of different roots/endpoints or repeated sources.
- `group-service-tests.log`: ten runtime tests passed. Report preparation supports up to 16 explicitly selected same-root observations, rejects unresolved outside candidates and already-registered findings, and preserves multiple consecutive explicit distinct decisions. Ordinary edits end the decision chain, preventing old decisions from reviving after evidence changes. Known-ticket evidence preparation uses the same resolved decisions.
- `core-final.log`: 191 passed, zero failures.
- `runtime-final.log`: 146 passed, zero failures.
- `mac-final.xcresult`: 483 passed, three failed, zero skipped on macOS 26.5.2 (25F84), arm64. Two failures are the unchanged Keychain integration tests (`-25308`). The new CityPay UI test failed to activate the app, which remained running in the background; it did not exercise the editor. A read-only `ioreg` check confirmed `CGSSessionScreenIsLocked = Yes`. This failed run produced no app-window acceptance evidence; the unlocked recheck below resolves these failures.
- `iphone-final.xcresult`: 332 passed, zero failures/skips on iPhone 16 Pro, iOS 26.0 (23A343), UDID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.
- `mac-unlocked-recheck.xcresult`: three passed, zero failures/skips: the CityPay creation/reopen UI test and both Keychain integration tests. Exported app-window screenshot `mac-attachments/5938019A-9EF4-4D37-87CE-80D5225F7D30.png` was visually inspected: instructions scroll, text is readable, and Save/Cancel remain accessible. This resolves the screen-lock validation blocker and the Keychain failures observed in P2-08/P2-09.
- Documentation integrity, 159-section coverage, local links and ignore checks passed.

The native skill editor now offers the CityPay template only for a blank new draft; it does not replace an existing edited skill or save automatically. The native UI test verifies save/reopen persistence and bundled examples.

Native report-management surfaces remain P2-10. No external ticket was published, no live Codex call was needed, and no full physical-display/device matrix is claimed. Unrelated Xcode normalization, user scheme metadata and handoff wording changes are excluded from the task commit.

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-09/mac-final.xcresult -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/AgentDeskUITests/testCityPayTemplateCreatesVersionedSkillAndReopensWithExamples -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-09/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-09/mac-unlocked-recheck.xcresult -only-testing:AgentDeskTests/KeychainIntegrationTests -only-testing:AgentDeskUITests/AgentDeskUITests/testCityPayTemplateCreatesVersionedSkillAndReopensWithExamples -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
python3 Scripts/validate-documentation.py
```

Prior failure evidence is preserved; all recorded test processes are terminal.

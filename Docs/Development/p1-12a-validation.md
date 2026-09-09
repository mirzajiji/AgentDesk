# P1-12a scoped redaction and bounded records

Date: 2026-09-10. Starting commit `1e0c4f6`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Native iPhone tests ran on **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The broader device/minimum-runtime matrix remains deferred by the user until full-project acceptance.

## Implemented behavior

The security module now constructs scoped, classified `RedactedText` from bounded text/JSON input. Known-value and pattern matching share one boundary. Reference resolution verifies all owners before reading any bytes, accepts explicit workspace/project inheritance, preserves cancellation and fails closed on missing secrets. The output cannot be forged through Decodable. JSON redaction preserves untouched source bytes and numeric precision while masking entire sensitive values/subtrees. A bounded stream buffer publishes only after a complete logical message is sanitized; partial chunks never become displayable output.

The implementation handles overlapping secrets, common Base64/hex/JSON/Unicode representations and one layer of mixed percent/form encoding. Percent matches map back to original character ranges without rewriting unrelated text. Whole SECRET records, malformed/duplicate JSON, secret-bearing JSON member names, resource overflows and foreign contexts are refused. Policy/buffer descriptions, reflection and fixed errors do not expose configured values. See the [security contract](../Architecture/security.md) for exact limits and limitations.

This task supplies the reusable boundary. It does not yet persist provider observations or expose run output in the app. P1-12b will require it for trace/artifact publication; P1-11 will connect it to the provider and UI. Arbitrary unknown unlabelled secrets and custom/binary encodings are not claimed as detectable. No real credentials or company data were read by these tests.

## Accepted validation

- **24 Security unit tests pass**, including 12 new redaction tests. Coverage exercises text/JSON happy paths, full subtree masking, exact numeric-byte preservation, escaped keys, classifications, encoded and overlapping values, cookies/headers/URLs/private keys, false positives, all byte boundaries of a Unicode secret, unavailable/foreign references, bounds, invalid UTF-8, duplicate/malformed/deep JSON, cancellation, closed-buffer behavior and diagnostic/serialization non-disclosure.
- **227 native Mac unit/integration tests and one Settings UI test pass.** The shared redaction suite runs inside the signed native test target together with existing provider, policy, storage and Keychain regressions.
- **182 native iPhone unit/integration tests pass** on the primary local Simulator, including the same redaction behavior. This is an executed simulator test suite, not just an iOS build.
- The normal signed Mac application builds with the new security module. This task makes no host, entitlement, provisioning, XPC protocol or project graph changes.
- Documentation integrity, 159-section coverage, links and ignore-rule checks pass. The final diff excludes preexisting Xcode formatting/normalization, personal scheme metadata and historical handoff wording.

The initial run had three assertions fail in one test: an over-encoded hyphen allowed a synthetic URL-encoded value through. The fix matches decoded percent/form bytes against known values while preserving the original ranges. The accepted suite adds mixed hex case, optional encoding, form spaces, Unicode surroundings and overlapping-match regressions. Failed results remain in `security-tests.log`; accepted results are in `security-tests-fixed.log` and the native bundles.

## Commands and records

All generated output is ignored under `TestResults/p1-12a/`. Native logs/bundles are `mac-accepted.log/.xcresult` and `iphone-accepted.log/.xcresult`; the ordinary build is `normal-mac.log`.

```sh
swift test --package-path Packages/AgentDeskSecurity
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-12a/mac-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-12a/iphone-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
python3 Scripts/validate-documentation.py
git diff --check
```

P1-12 is now three focused tasks: redaction (this commit), evidence storage/recovery and Git snapshots/diffs. The roadmap count reflects that decomposition without claiming later phases are complete.

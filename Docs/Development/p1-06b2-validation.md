# P1-06b2 execution configuration and output contracts

Date: 2026-09-10. Starting commit `d9ca859`, branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Native iPhone tests ran on **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The broader device/minimum-runtime matrix remains deferred until full-project acceptance, as requested by the user.

## Implemented behavior

Workspace/project execution JSON and project environments now use immutable revisions and an atomic current pointer. Stored workspace/project/environment policies retain exact scope; omitted documents deny all operations. Environment kind and workspace lock are frozen with the selected configuration. Explicit default selection never fabricates an environment. Historical agent profiles decode without the new optional fields, and ordinary agent edits preserve advanced constraints.

The composer resolves model selection, intersected model/environment allowlists, access ceilings, minimum step/time/output budgets and inherited output schemas. It retains source revisions, settings, fingerprints, winning scalar/limiting-budget origins and the complete configuration fingerprint. More-specific settings cannot widen restrictions, remove a parent schema or unlock a workspace. Native advanced settings controls, repository registration and policy-authorized app run launch remain subsequent integration work.

A bounded JSON Schema subset encodes as standard JSON, rejects unsupported/invalid schemas and validates final output deterministically. The reader rejects duplicate keys, invalid syntax/UTF-8, excessive depth/nodes/bytes and out-of-range numbers. Integers use decimal comparison; string limits count Unicode code points. Runtime builds exact scoped requests from frozen configuration, sends `outputSchema` to the CLI, enforces the combined assistant-text byte limit and rejects mismatches before emitting completion. Workspace-write intent is explicitly unsupported by the current provider. See the detailed [configuration contract and limits](../Architecture/configuration.md).

## Accepted checks

- **88 Core tests pass:** immutable save/reopen/history, stale revision, orphan preservation, scope isolation and workspace inheritance, foreign/disabled environments and agents, cancellation/symlink/malformed-pointer rejection, strict restriction decoding, legacy agent compatibility, override precedence, shrinking budgets, allowlist intersection, read-only denial, stored policy ownership/production/lock, deny defaults and deterministic fingerprints. Schema tests include closed objects, required/missing/null fields, nested arrays, types/enums/bounds, integral decimal forms, fractional boundaries, exact Unicode enums, unknown keywords, duplicate keys, invalid JSON and resource exhaustion.
- **68 Runtime tests pass:** includes frozen configuration → exact provider request, unsupported write intent, invalid contracts before launch, schema propagation to the synthetic CLI, wrong/malformed final output without completion, output budget failure and existing scope/permissions/cancellation/timeout/process/approval regressions.
- **205 native Mac unit/integration tests and one native Settings UI test pass.** Existing signed-helper health/disconnect/reconnect behavior remains working without signing out the developer.
- **161 native iPhone unit/integration tests pass** on the primary Simulator. This executes the shared configuration/schema/policy code; it does not grant the phone local execution authority.
- **A real installed Codex CLI 0.153.4 run passes.** An isolated probe creates a synthetic workspace/project/agent/environment and immutable execution settings, resolves the request, performs one read-only command on `evidence.txt`, receives schema-conforming JSON and checks its fields against exact known file contents. The schema exercises bounded string, integer, boolean and enum-array fields. The existing supported CLI login is reused; no credentials are read or changed. This exercises the internal provider, not a completed native Run UI or coordinator.
- **Normal signed Mac build passes.** `codesign --verify --strict --verbose=2` validates both app and embedded helper using system trust services. The main app still has App Sandbox enabled; the previously approved helper has no App Sandbox entitlement. No signing, provisioning, XPC API or project graph changes belong to this task. The iPhone product contains no XPC bundle.

## Commands and records

All generated logs, probe/catalog/evidence files and result bundles are ignored under `TestResults/p1-06b2/`. Accepted package logs are `core-complete.log` and `runtime-complete.log`; native logs/bundles are `mac-complete.log/.xcresult` and `iphone-complete.log/.xcresult`; normal build log is `normal-mac-build.log`; the real CLI probe is `Probe/Sources/Probe.swift`, with `live-structured.log` and synthetic storage under `Live/`.

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-06b2/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06b2/mac-complete.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-06b2/iphone-complete.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
swift run --package-path TestResults/p1-06b2/Probe \
  --scratch-path TestResults/p1-06b2/ProbeBuild CodexProbe \
  '/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk/TestResults/p1-06b2/Live'
python3 Scripts/validate-documentation.py
git diff --check
```

An initial Runtime attempt reused a stale SwiftPM dependency source plan and could not see the new Core files. A fresh scratch path resolved it; subsequent Runtime checks pass. One added test incorrectly expected a hyphenated model identifier to fail; it was corrected to use a prohibited space. No command interpolation is used for model IDs. The live probe's debug link step emitted missing debug module-cache path warnings but built and executed successfully. Native checks were repeated after stored policy snapshots were added; the earlier live schema success remains valid for unchanged provider/schema behavior.

## Review and remaining work

Configuration is not authorization, schema matching is not proof of factual correctness, and untrusted intermediate provider messages still require centralized redaction before persistence/display. Defaults do not enable execution without explicit policies and authenticated authority. The coordinator must resolve actual repository resources, revalidate the active context, bind the frozen configuration and instructions to the exact prepared action, and record run snapshots. Skill bundles, advanced native editors and live run/result UI remain separate tasks.

The final diff excludes preexisting Xcode formatting/normalization, personal scheme UI metadata and historical handoff text. Documentation integrity, all 159 section mappings, links and ignore checks pass. No generated output, credentials or company data is staged.

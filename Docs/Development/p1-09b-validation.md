# P1-09b scoped Codex provider validation

Date: 2026-09-10. Starting commit `4472b90`, branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, MacBook Pro arm64, macOS 26.5.2 (25F84). Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The broader device/OS matrix remains deferred until full-project acceptance.

## Implemented scope

This task adds a real internal `ExecutionProvider` and `CodexCLIProvider`, bounded JSON framing/typed wire values, a single-turn protocol state machine and a bounded interactive-stdin mailbox. The provider validates request identity, project directory identity and authentication, verifies the CLI's returned permissions before supplying the task, emits normalized scoped observations and only completes after valid final output and a clean exit. It enforces one active run, cancellation, an end-to-end deadline including diagnostics, byte/activity limits and explicit consumer overflow. The subprocess boundary is injectable; its production implementation always uses `MacProcessRunner`.

The supported capability is one ephemeral **read-only** local CLI turn. The main app and signed helper do not yet expose task execution; the helper's interface remains account-only. Runtime policy, effective configuration, central redaction, output schemas, persisted coordinator integration, write approvals, diffs and the native run UI remain required tasks. Raw provider values stay in bounded memory and cannot be stored or shown directly through this interface. See [provider contract](../Architecture/codex.md) and [execution responsibilities](../Architecture/execution.md).

## Exercise, regressions and fixes

The installed CLI's stable and experimental schemas were generated using its public `app-server generate-json-schema` command. Version 0.153.4 exposes named permission profiles and explicit runtime roots through its experimental app-server API. A local stdin child process lets AgentDesk verify the effective profile/root response before delivering task text. The adapter does not use an OpenAI API client, cached-token inspection or a network app-server endpoint.

A read-only CLI sandbox probe allowed reading an explicitly permitted synthetic file and denied a sibling file and a symlink into that sibling. The profile uses `:minimal` and `:workspace_roots` read access, with network disabled. These probes used fixed argument arrays and synthetic data. Network denial is verified from the effective configuration; no independent network penetration test is claimed.

The exact product configuration initially returned empty runtime roots. The provider rejected the session before supplying its task. Investigation established that supplying an empty `environments` array disables environment access and clears those roots; omitting that field retains the selected local environment and explicit root. The next attempt was rejected at `turn/start` because the CLI reloads configuration and the named profile had only been supplied at thread setup. The final implementation supplies the same generated profile at process and thread scope, with explicit selection at turn start. The successful handshake checks named profile identity/no inheritance, exact root/cwd, read-only/network-denied sandbox, never-approval policy, ephemeral thread and configured provider/model.

The first fake-producer overflow test used a startup delay that was too short for a cold Python interpreter. It now waits for bounded producer termination without consuming the stream, making the overflow assertion independent of startup timing. The first native Mac run failed because a writable temporary executable was denied; a subsequent fixture using `/usr/bin/python3` failed because its `xcrun` launcher cannot run inside App Sandbox. A targeted diagnostic confirmed that cause. The final fixture is a nonexecutable synthetic Perl script read by `/usr/bin/perl` through the injectable transport. It exercises real pipes, JSON, child exit and cleanup on both SwiftPM and the native Mac test host. Production execution permissions were not widened.

The meaningful regression cases include literal prompts and Unicode, exact identity/sequence, wrong profile/root/network/approval/ephemeral values withheld from task input, malformed JSON, invalid UTF-8/NUL and excessive depth/size, foreign thread/command directories, duplicate responses, unsupported tools and writes, unexpected approval requests, commentary without a final answer, early/nonzero exits, overflow/reaping, timeout, cancellation, concurrent-start rejection, prelaunch scope/authentication checks and replaced project directories. Shared tests validate request limits/model identifiers. Interactive-input tests cover request/response feeding, EOF, mailbox bounds and cancellation while waiting for input.

## Commands and evidence

```sh
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-09b/mac-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-09b/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
python3 Scripts/validate-documentation.py
git diff --check
```

**57 Runtime tests, 161 native Mac unit/integration tests, one affected Mac Settings UI test and 119 iPhone unit/integration tests pass.** Accepted logs are `runtime-perl.log`, `mac-final.log` and `iphone-final.log`, under ignored `TestResults/p1-09b/`. Both native targets compile the shared request/framing types. Mac-only process code/tests are excluded from iPhone. Earlier failed runs are retained, not counted as acceptance.

An ignored debug SwiftPM probe imports the same provider with `@testable` access, binds a synthetic project, asks it to read only `evidence.txt`, consumes its actual stream, and verifies one completed command and an exact final answer after process exit. The final real CLI smoke test is `TestResults/p1-09b/live-execution-final.log`, repeated against the final production transport from a fresh SwiftPM scratch build; earlier setup failures are retained separately. The developer's supported existing ChatGPT login was reused without logging out, copying credentials or changing account settings. Ordinary tests use injected diagnostics and synthetic executables and do not require that account or a live model call.

The local smoke invocation was:

```sh
swift run --package-path TestResults/p1-09b/Probe \
  --scratch-path TestResults/p1-09b/ProbeBuildFinal CodexProbe \
  '/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk/TestResults/p1-09b/SandboxProbe/Allowed' \
  --execute
```

The probe, generated schemas, synthetic files, native result bundles and logs stay under ignored `TestResults/`; they contain no company data. The smoke's fixtures and path are machine-local evidence, not a required ordinary test dependency. Future compatibility checks should regenerate schemas from the selected installed CLI and repeat this exact restricted operation before enabling a different protocol version. No multi-device coverage, UI run launch, usage values, session recovery or write capability is inferred from this test.


## Ordinary Mac build and commit review

`xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build` succeeds (`normal-mac-build.log`). System-service signing verification with `codesign --verify --strict --verbose=2` validates the app and embedded helper. `codesign -d --entitlements -` confirms that the normal main app retains App Sandbox and the approved helper has no sandbox entitlement. Initial signing inspection inside the restricted tool environment could not consult system trust; repeating the same read-only verification with system-service access succeeds. There is no provisioning or entitlement change in this task.

The final iPhone artifact contains no XPC service. The parsed Xcode graph matches HEAD after excluding the already documented unsupported copy-phase field that Xcode normalized away. Unrelated project formatting, personal scheme UI metadata and historical handoff edits remain unstaged. Documentation integrity, all 159 sections, coverage, links, ignore rules and diff checks pass. Generated outputs, credentials and company data are excluded from the commit.

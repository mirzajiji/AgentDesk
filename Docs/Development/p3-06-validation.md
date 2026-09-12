# P3-06 MCP transport validation

## Scope and protocol sources

P3-06 implements architecture sections 37–39 and phase 3 transport requirements. The new `AgentDeskMCP` module starts with working bounded wire decoding; no process launch, remote transport, handshake/discovery, request ledger, policy dispatch or native manager is complete yet.

The [current stdio specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio) retains newline-delimited JSON-RPC while changing discovery and request metadata from the [2025-11-25 base protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic). Framing does not select a protocol era or authorize server requests. Version negotiation must be explicit in the transport/session implementation. Never automatically retry mutations on reconnect.

## Wire decoder

`MCPMessage` classifies requests, notifications, object results and errors; IDs are bounded strings or signed 64-bit integers. Original JSON bytes remain intact so evidence numbers are not rewritten. Core’s strict parser rejects duplicate keys, malformed UTF-8, excessive nesting/node counts and invalid JSON before envelope decoding. Parsing errors contain fixed local cases, not remote message contents.

`MCPLineDecoder` accepts arbitrary byte fragments, including split UTF-8 scalars, with newline-delimited messages. Configurable per-message limit is 1–262,144 bytes; each feed is also capped at 262,144 bytes. Core limits nesting to 40 and nodes to 8,192. A malformed, oversized, cancelled or truncated stream becomes terminal and drops its buffer. Blank lines are rejected; CRLF works as JSON trailing whitespace. No logging or dispatch occurs. Raw message data remains untrusted and must cross redaction and policy boundaries before display or execution.

## Validation

`swift test --package-path Packages/AgentDeskMCP` passes three tests (`TestResults/p3-06-wire.log`): bytewise Unicode framing, multiple frames, exact large-number payload preservation, ID/classification, malformed/batch/duplicate fields, boolean/fractional/null IDs, invalid UTF-8, limits, truncation and uncorrelated remote errors. Simulator check pending.

This is a component of P3-06, not a complete transport. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.


Final wire tests: four tests pass on Mac (`p3-06-wire-final.log`) and iPhone 16 Pro / iOS 26.0 (`p3-06/wire-iphone-final.xcresult`). The added regression verifies exact-limit repeated frames, oversized feed rejection and cancellation on an empty chunk; it prompted moving the cancellation check before iteration. Simulator command from `Packages/AgentDeskMCP`: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-06/wire-iphone-final.xcresult -parallel-testing-enabled NO test`. Xcode 26.0 / macOS 26.5.2. No MCP server was started or contacted.


Normal application builds passed using `AgentDesk.xcodeproj`, scheme `AgentDesk`, the documented Mac/primary Simulator destinations and `TestResults/p1-01/NativeMac` / `TestResults/p1-08b/FilteredIPhone` derived data (`p3-06-app-mac.log`, `p3-06-app-iphone.log`). The app does not yet link or invoke MCP; these builds are compatibility checks, while package tests establish wire behavior. Documentation and diff checks pass.


## Connection-scoped request tracking

`MCPRequestTracker` owns one project/connection's pending metadata. Each tracker has a fresh generation and monotonically increasing request IDs, so IDs are never reused after completion/cancellation within a tracker and responses from an old connection cannot match a new tracker. It accepts only result/error envelopes for completion, rejects unmatched/duplicate responses, enforces a configurable pending cap (1–1,024), and bounds deadlines to one hour. Deadline comparison uses `ContinuousClock`; expiration at the deadline is rejected. Cancelling, expiring and closing drop pending metadata; close returns outstanding requests for the future transport to fail its waiters. No raw request/response bodies are retained by the tracker.

This is correlation state, not an execution permission, dispatch loop or timer scheduler. The transport still must schedule expiration, write cancellation notifications, fail continuations and release processes. No method is sent or run by this component.

`swift test --package-path Packages/AgentDeskMCP` passes all eight wire/tracker tests (`TestResults/p3-06-tracker.log`). Added tests cover out-of-order result/error responses, duplicate rejection, capacity release, timeout boundary, explicit expiry, cancellation, foreign connection rejection, close, notification separation and invalid limits. Native Simulator checks pending.


Final tracker checks: eight tests pass on iPhone 16 Pro / iOS 26.0 (`p3-06/tracker-iphone.xcresult`), using `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-06/tracker-iphone.xcresult -parallel-testing-enabled NO test` from the package directory. Normal Mac/iPhone app compatibility builds pass using the preceding documented commands (`p3-06-tracker-app-mac.log`, `p3-06-tracker-app-iphone.log`). MCP is not yet wired into the app. Documentation and diff checks pass. Xcode 26.0 / macOS 26.5.2. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.


## Mac stdio process transport

Runtime now depends on the MCP wire module and contains an internal `MCPStdioTransport` using the existing POSIX process-group runner and bounded stdin mailbox. The transport sends one validated JSON message per line and rejects physical CR/LF in outgoing frames. Stdout goes through strict incremental MCP decoding; stderr is drained separately, not interpreted as failure and not exposed or logged. The runner's combined lifetime output cap is 16 MiB; the message queue holds at most 128 frames and fails on overflow rather than silently dropping protocol messages. Lifetime is caller-bounded up to one hour; future request deadlines are separate.

Explicit close, stream-consumer cancellation and transport deinitialization cancel the owned process task. The existing runner kills/reaps the process group and closes pipes. `finishInput` drains accepted input and sends EOF; callers may await `waitForExit` or force close. Unexpected exit, timeout and malformed output finish the receive stream with fixed typed errors. The caller must close when abandoning a stream without cancelling its iterator.

This internal primitive accepts an already authorized local launch; it is not exposed to mobile/model tools and does not itself validate workspace filesystem configuration or grant command authority. Scoped configuration, approved executable/environment resolution, session negotiation, connection lifecycle UI and remote HTTP remain unfinished. No installed MCP server or live company process was contacted: real-process tests use `/bin/cat`, `/bin/echo` and `/usr/bin/printf` with synthetic messages.

Five focused tests pass (`swift test --package-path Packages/AgentDeskRuntime --filter MCPStdioTransportTests`, `p3-06-stdio-final.log`): real pipe round trip/EOF, malformed output, process timeout, explicit cancellation, multiline send rejection, bounded receive overflow and consumer cancellation. Full Runtime and native app checks pending. Mac-only subprocess behavior is intentionally absent from iPhone.


Final stdio checks: all 173 Runtime host tests pass (`swift test --package-path Packages/AgentDeskRuntime`, `p3-06-stdio-runtime-full.log`), including the consumer-cancellation assertion that shutdown completes before the five-second process lifetime. Normal Mac and iPhone builds pass with the new transitive MCP dependency (`p3-06-stdio-app-mac.log`, `p3-06-stdio-app-iphone.log`) using the documented AgentDesk project/scheme/destinations/derived data. Xcode 26.0 / macOS 26.5.2. No iPhone subprocess test is possible or intended; the shared wire/tracker Simulator tests were verified separately above. Documentation and diff checks pass. This does not complete P3-06: scoped launch authorization, session negotiation, remote transport and native lifecycle remain outstanding. Counts unchanged: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.


## Awaitable stdio request sessions

The internal `MCPStdioSession` now ties the process stream to the connection tracker and checked continuations. It matches concurrent replies, returns remote result/error envelopes as untrusted data, and completes waiters on process exit, explicit close, per-call timeout and caller cancellation. Cancellation sends a best-effort `notifications/cancelled`; send failure closes the session and fails remaining calls. Late/uncorrelated replies do not reach callers, and server requests fail closed rather than executing local actions. Notifications are currently ignored pending negotiated routing. No automatic retry is performed.

The wire module now encodes request/notification envelopes while retaining supplied compact object-parameter bytes. IDs/methods are JSON encoded; malformed parameters and multiline wire payloads are rejected. Protocol negotiation, modern request metadata, legacy compatibility, tool permissions and scoped launch approval are still required before native exposure.

Real-process tests use a static local Python JSON-RPC fixture passed as an argument array. They cover concurrent matching, cancellation/timeout with a later successful call, clean process exit and explicit-close waiter release. The first run exposed a deadline task cancelling itself before sending its cancellation notification, incorrectly closing unrelated requests. The corrected timeout path avoids cancelling its own task; all three session tests pass (`p3-06-session-tests-fixed.log`). Shared encoding tests also pass. Full native checks pending.


Final session validation: all 176 Runtime host tests passed (`swift test --package-path Packages/AgentDeskRuntime`, `p3-06-session-runtime-full.log`). All nine shared MCP tests passed on Mac (`p3-06-request-encoding-final.log`) and iPhone 16 Pro / iOS 26.0 (`p3-06/session-wire-iphone-final.xcresult`). The encoder checks parameter, method and string-ID sizes before envelope allocation; new tests cover oversize rejection, escaped IDs, preserved large numeric parameters and notification encoding. The Simulator command uses the existing AgentDeskMCP scheme, primary destination, `../../TestResults/p3-06/MCPIPhone` derived data and `../../TestResults/p3-06/session-wire-iphone-final.xcresult` with `-parallel-testing-enabled NO test`. Normal app builds pending. macOS 26.5.2 / Xcode 26.0. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.


Both normal app builds passed (`p3-06-session-app-mac.log`, `p3-06-session-app-iphone.log`), using the documented AgentDesk project/scheme/destinations and derived-data paths. Documentation and diff checks passed. No negotiated MCP server connection, tool execution or native manager acceptance is claimed.

## Explicit protocol negotiation

The internal negotiated stdio connection supports explicitly selected 2026-07-28 discovery and 2025-11-25 initialization. Modern discovery and ping carry protocol/client metadata; legacy initialization sends the initialized notification before ping. Responses require the selected version and object capabilities, with bounded identity fields. Server identity and advertised capabilities remain untrusted claims, never permission grants; server instructions are not consumed. Failed negotiation closes the process. Initialization timeout releases its local waiter without sending the legacy-forbidden cancellation notification.

References: [modern stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio), [discovery definition](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/server/discover.mdx), [legacy lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), and [legacy cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation).

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: 179 passed (`TestResults/p3-06-negotiation-runtime-full.log`). Includes real synthetic subprocess handshakes, notification order, mismatch cleanup, and initialize-timeout wire cancellation exclusion.
- `swift test --package-path Packages/AgentDeskMCP`: 11 passed (`TestResults/p3-06-negotiation-wire-final.log`). Includes malformed negotiation responses and unsupported versions.
- From Packages/AgentDeskMCP: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-06/negotiation-wire-iphone.xcresult -parallel-testing-enabled NO test`: 11 passed on iPhone 16 Pro / iOS 26.0.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: passed (`TestResults/p3-06-negotiation-app-mac.log`).
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone build`: passed (`TestResults/p3-06-negotiation-app-iphone.log`).

This is an internal explicit-mode implementation, not completed MCP acceptance. Automatic era/version negotiation, cancellation/send ordering hardening, scoped launch authorization, discovery routing, tool policy, HTTP transport and native manager remain outstanding. No installed third-party server was contacted. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Cancellation enqueue ordering

Each pending stdio call now retains its send task. Wire cancellation waits for a successful request enqueue; a request removed before sending or a failed send receives no cancellation notification. The local waiter is still released promptly. This prevents actor scheduling from emitting cancellation before its request. Initialization remains exempt from wire cancellation.

The synthetic subprocess now rejects cancellation IDs it has not received. A regression exercises twenty immediately expired requests after a startup ping, then checks connection usability. The initial hundred-request burst saturated the separately bounded input queue during fixture startup; the focused regression establishes readiness and stays below queue capacity. All five session tests pass (`TestResults/p3-06-cancel-order-regression.log`). Full `swift test --package-path Packages/AgentDeskRuntime` passes 180 tests (`TestResults/p3-06-cancel-order-full.log`). The normal Mac build passes using the project, scheme, macOS destination and NativeMac derived-data command above (`TestResults/p3-06-cancel-order-mac.log`). Environment: macOS 26.5.2 / Xcode 26.0. Both changed Swift files are macOS conditional; no new iPhone coverage is claimed. Shared protocol Simulator validation remains recorded above. Counts unchanged; P3-06 remains in progress.

## Automatic stdio era detection

The default connection now probes modern discovery first and retains the resulting mode for that process connection. Explicit mode remains available. Unrecognized JSON-RPC errors and probe timeout fall back to legacy initialize/initialized; malformed successful discovery fails closed. Recognized modern errors -32020, -32021 and -32022 never trigger legacy downgrade. Only modern revision 2026-07-28 is implemented, so an unsupported-version rejection is surfaced instead of retrying an unimplemented revision. Cancellation and transport failures propagate through process cleanup, not the timeout fallback branch.

This follows the [stdio compatibility rules](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio) and recognized modern codes in the [official schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts). Synthetic subprocess tests cover modern success, three different legacy errors, silence/timeout, all three recognized modern rejection codes, explicit handshakes and version mismatch cleanup. The fixture accepts legacy initialize after an error, so an accidental modern-to-legacy downgrade would make the rejection tests fail.

Validation: `swift test --package-path Packages/AgentDeskRuntime --filter MCPNegotiatedStdioTests` passes four tests (`TestResults/p3-06-auto-negotiation.log`); full `swift test --package-path Packages/AgentDeskRuntime` passes 182 tests (`TestResults/p3-06-auto-full.log`). The normal macOS app build command above passes (`TestResults/p3-06-auto-mac.log`). macOS 26.5.2 / Xcode 26.0. Only Mac-conditional runtime and tests changed; no new iPhone test coverage claimed. No live third-party MCP server contacted. P3-06 remains incomplete pending scoped launch authorization, remote transport and lifecycle integration. Counts: 52 complete; 11 Phase 3 tasks plus Phases 4–6 remain.

## Scoped local-process configuration

`MCPStdioConfiguration` is a versioned Codable launch-intent model owned by AgentDeskMCP, independently of plugin configuration. It includes connection/project/environment identity, name, absolute executable path, literal argument array, workspace-relative working directory, disabled-by-default state and environment-variable Keychain references. Initialization and decoding validate bounds, path syntax, environment names and exact secret-reference scope. AgentDeskMCP now depends on AgentDeskSecurity for the existing reference type. No secret value is serialized by that reference field.

This model does not launch anything or prove filesystem isolation. Project containment, symlink/executable resolution, policy approval, credential retrieval and authoritative configuration persistence must precede runtime use. Arguments are non-secret configuration supplied by the administrator; no shell interpolation is performed by this model and no claim is made that arbitrary argument text is automatically scrubbed of secrets. Plain environment values and remote HTTP configuration are not implemented here.

Validation: all 13 MCP package tests passed with `swift test --package-path Packages/AgentDeskMCP` (`TestResults/p3-06-configuration-tests.log`). Configuration tests cover round-trip decoding, decoder validation, disabled defaults, foreign secret scope, malformed executable paths and oversized arguments. All 13 tests also passed on iPhone 16 Pro / iOS 26.0 using the package Simulator command above with result bundle `TestResults/p3-06/configuration-iphone.xcresult` (`TestResults/p3-06-configuration-iphone.log`). Both normal app build commands above passed (`TestResults/p3-06-configuration-mac-build.log`, `TestResults/p3-06-configuration-iphone-build.log`). Environment: macOS 26.5.2 / Xcode 26.0. Documentation and diff checks pass. P3-06 remains in progress; 52 tasks complete, 11 Phase 3 tasks plus Phases 4–6 remain.

## Project MCP configuration persistence

WorkspaceCatalog now opens a typed ProjectMCPConfigurationStore under the selected project's `MCP/<connection UUID>/` directory. It uses the existing locked, no-symlink configuration directory primitives. Saves append immutable versions and publish a current pointer, rejecting stale expected revisions. Reads and environment-filtered, bounded listing validate workspace/project ownership. The store has independent MCP configuration types and directories; plugin records are not mixed with MCP records. It is local administrative storage, not launch authority.

The integration regression saves two versions, reopens the catalog, checks historical/current contents and environment listing, and rejects stale writes and foreign-project reads. All 14 MCP host tests pass (`swift test --package-path Packages/AgentDeskMCP`, `TestResults/p3-06-storage-tests.log`). All 198 Core host tests pass (`swift test --package-path Packages/AgentDeskCore`, `TestResults/p3-06-storage-core.log`). All 14 MCP tests pass on iPhone 16 Pro / iOS 26.0 with the package Simulator command above, result bundle `TestResults/p3-06/storage-iphone.xcresult` and log `TestResults/p3-06-storage-iphone.log`. Normal Mac and iPhone app build commands above pass (`TestResults/p3-06-storage-mac-build.log`, `TestResults/p3-06-storage-iphone-build.log`). macOS 26.5.2 / Xcode 26.0. Documentation and diff checks pass. Native MCP configuration UI and launch policy integration remain unfinished. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Stored launch policy boundary

The internal Mac MCPLaunchPolicySession binds a runShell action to the full stored configuration revision and a trusted resolver's physical-resource fingerprint. It rechecks both plus the current policy before preparation, approval and dispatch. Missing/disabled configuration, changed scope, changed policy/configuration and closed sessions fail. Nonlocal callers are rejected before resource resolution. The shared PolicyGate requires explicit approval for runShell even when general rules allow it, consumes approval once, and handles durable audit state. This actor does not retrieve secrets or launch a process itself; the trusted resource resolver and concrete process/credential adapter still need integration.

A synthetic dispatch-counter regression verifies rule denial, mandatory approval, single-use approved execution, edited-configuration invalidation, closure denial, and paired-device denial before resolver invocation. Its initial expectation that an allow rule could dispatch directly was corrected to match mandatory runShell review. All 183 Runtime tests pass (`swift test --package-path Packages/AgentDeskRuntime`, `TestResults/p3-06-launch-policy-full.log`); the normal Mac build command above passes (`TestResults/p3-06-launch-policy-mac.log`). Environment: macOS 26.5.2 / Xcode 26.0. Mac-only source/tests; no new iPhone coverage claimed. Documentation and diff checks pass. Native MCP launch acceptance is not complete; counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Physical launch resource snapshots

MCPLaunchResource resolves the configured working directory against host-supplied workspace/project roots and rejects canonical paths outside the project, including sibling-prefix collisions and symlink escapes. It requires a regular executable file with execute access. The action resource fingerprint contains scope, canonical paths, directory device/inode identity and executable device/inode/size/change timestamps. Normal directory-content changes do not alter directory identity. Host roots must come from the authenticated project registration, not a model or mobile request.

These are filesystem snapshots, not pinned descriptors or a process sandbox. Revalidation immediately before spawn and concrete launch wiring remain required; this does not claim elimination of concurrent filesystem replacement races or containment of arbitrary child-process file access. No process executes in these resource tests.

Two regressions cover stable identity, project/sibling/symlink/foreign-scope checks, non-executable rejection and changed executable identity. All 185 Runtime tests pass (`swift test --package-path Packages/AgentDeskRuntime`, `TestResults/p3-06-resource-full.log`). The normal Mac app build command above passes (`TestResults/p3-06-resource-mac.log`). macOS 26.5.2 / Xcode 26.0. Mac-only changes; no new iPhone coverage claimed. Documentation and diff checks pass. P3-06 remains incomplete; 52 tasks complete, 11 Phase 3 tasks plus Phases 4–6 remain.

## Approved process launch integration

MCPApprovedStdioLaunch connects stored launch policy, physical-resource revalidation, process transport and automatic negotiation. A local user reviews the exact launch; startup rechecks configuration and physical identity, passes literal arguments to the resolved executable with an empty environment, and owns the resulting connection. Duplicate starts are rejected. Startup runs in an owned cancellable task: caller cancellation or close cancels negotiation, and close awaits pending cleanup before returning. Successful connections support ping and close.

Two real-process synthetic regressions cover unreviewed rejection, approved discovery/ping, duplicate-start rejection, closed-connection behavior and close during an unresponsive startup. The latter verifies completion within two seconds rather than the server's sixty-second sleep. All 187 Runtime tests pass (`swift test --package-path Packages/AgentDeskRuntime`, `TestResults/p3-06-approved-launch-full.log`); focused tests pass (`TestResults/p3-06-approved-launch-final-tests.log`). Normal Mac build passes with the command above (`TestResults/p3-06-approved-launch-mac.log`). macOS 26.5.2 / Xcode 26.0; Mac-only changes, no new iPhone coverage claimed. Documentation and diff checks pass.

This internal integration rejects secret-environment configurations until credential-read policy is connected. Native UI/helper exposure, registration access lifetime, remote transport, secret-bearing startup and full lifecycle/discovery acceptance remain unfinished. Snapshot revalidation does not claim process sandboxing or eliminate filesystem races. No installed third-party MCP server was launched. Counts remain 52 complete; 11 Phase 3 tasks plus Phases 4–6 remain.

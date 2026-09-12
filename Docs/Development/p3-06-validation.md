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

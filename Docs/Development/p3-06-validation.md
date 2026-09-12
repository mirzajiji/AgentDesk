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

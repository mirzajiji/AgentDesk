# P3-07 MCP discovery validation

## Tool-list protocol boundary

Added bounded tools/list parameter encoding and response decoding for the implemented modern and legacy protocol modes. The decoder attaches caller-supplied workspace/project, environment and connection identity, validates tool names, duplicate names, input-schema root shape, optional output-schema object shape, metadata types and page/cursor limits. Modern responses require complete results and valid cache-hint fields. Cursor contents are opaque and encoded through JSON, including quotes and control characters.

Tool metadata and annotations are untrusted claims. Discovery grants no execution permissions. The page retains the exact original response bytes so schemas, extensions and large numeric literals are not reconstructed through a lossy numeric representation. This raw evidence is not redacted and must not be displayed or persisted until the runtime redaction boundary is applied. The decoder does not resolve external schema references, validate arbitrary arguments against full JSON Schema, cache across scopes or dispatch tools.

Protocol source reviewed on 2026-09-12: the official [2026-07-28 MCP schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts), particularly ListToolsResult, Tool, pagination and cache hints. The retained legacy mode accepts its result without modern cache fields.

## Validation

macOS 26.5.2 / Xcode 26.0; primary local Simulator: iPhone 16 Pro / iOS 26.0.

```sh
swift test --package-path Packages/AgentDeskMCP
cd Packages/AgentDeskMCP
xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-07-tool-discovery-iphone.xcresult -parallel-testing-enabled NO test
```

All 17 package tests passed on the Mac and iPhone Simulator. Three new tests cover scoped response preservation, rich schema evidence, opaque cursor encoding, metadata precedence, missing annotation defaults, malformed/duplicate tool definitions, modern result/cache validation, page size and cursor bounds. After the Mac run, metadata-object conversion was changed to throw rather than fall back to an empty dictionary; the final Simulator run covers that change. Logs: `TestResults/p3-07-tool-discovery.log`, `TestResults/p3-07-tool-discovery-iphone.log`.

Both native app builds passed using the existing Mac and iPhone destination/derived-data commands. Logs: `TestResults/p3-07-tool-discovery-mac-build.log` and `TestResults/p3-07-tool-discovery-iphone-build.log`. Documentation and diff checks pass. No external MCP service was contacted by tests.

## Remaining work

P3-07 remains in progress. Live discovery request integration, tools/resources/prompts browsing, permission and approval binding, capability changes and dispatch are not completed by this parser. No native capability browser is claimed. Counts remain 52 documented tasks complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Scoped tool pagination

`MCPToolPagination` owns one bounded discovery traversal. It verifies every page's workspace/project, environment and connection identity, matches the requested cursor, rejects repeated cursors/cycles and duplicate tool names across pages, and limits page count, tool count and accumulated response bytes. Empty-string cursors remain valid opaque cursors. A completed catalog retains the original pages and is published only after a terminal page. Invalid input, exceeded limits, cancellation during append or explicit close clears partial state; a failed traversal cannot publish a catalog.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskMCP`: all 21 tests passed (`TestResults/p3-07-pagination-final.log`).
- The same package's local iPhone 16 Pro / iOS 26.0 Simulator run passed all 21 tests, using the preceding command with result bundle `TestResults/p3-07-pagination-iphone.xcresult` (`TestResults/p3-07-pagination-iphone.log`).
- Four new tests cover complete-only publication, retained page bytes, all four identity boundaries, wrong/repeated/cycling cursors, duplicate tools, page/tool/byte limits and cancelled append.
- Both native app builds passed (`TestResults/p3-07-pagination-mac-build.log`, `TestResults/p3-07-pagination-iphone-build.log`). Documentation/diff checks pass.

This is the shared traversal boundary, not live transport integration or permission to call tools. P3-07 remains in progress; counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

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

## Live negotiated tool traversal

The internal Mac negotiated connection now sends `tools/list` requests with the negotiated protocol metadata and follows opaque cursors through the scoped pagination boundary. The transport supplies workspace/project and connection identity; the authorized caller will supply its environment. One 30-second deadline bounds the entire traversal, rather than restarting the timeout per page. Errors and cancellation discard partial catalogs. This API remains internal: public discovery still requires independent policy review and redaction before display or persistence. No tool dispatch or native capability browser is claimed.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: 200 tests passed, zero failures (`TestResults/p3-07-live-discovery.log`).
- After adding cancellation coverage, `swift test --package-path Packages/AgentDeskRuntime --filter MCPNegotiatedStdioTests`: all 7 tests passed (`TestResults/p3-07-live-discovery-focused.log`). Synthetic local processes verify modern and legacy pagination, protocol metadata, preserved transport identity, repeated-cursor rejection, timeout, and cancellation without damaging the connection's subsequent ping.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed native build passed (`TestResults/p3-07-live-discovery-mac-build.log`).
- This implementation and its tests are macOS-only; no new Simulator coverage is claimed. Documentation and diff checks pass.

P3-07 remains in progress. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Independent discovery policy

The internal MCP policy session prepares, reviews and executes a separate `readEvidence` action for `tools/list`. Its payload binds the method and immutable configuration revision fingerprint; resource, workspace/project and environment remain bound by the action. Launch approval does not authorize discovery. The policy/configuration/resource checks run before dispatch and again before returning claims, so a configuration changed during traversal cannot publish a stale catalog. Closed sessions and missing operation authority fail closed.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime --filter MCPLaunchPolicyTests`: both policy tests passed (`TestResults/p3-07-discovery-policy.log`).
- After extending successful-read and missing-authority coverage, `swift test --package-path Packages/AgentDeskRuntime`: all 202 tests passed (`TestResults/p3-07-discovery-policy-final.log`). The discovery regression exercises deny/allow/approval policies, launch-approval substitution, independently approved execution, stale configuration during execution and closed-session rejection with synthetic storage.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-discovery-policy-mac-build.log`). Documentation and diff checks pass. This Mac-only change adds no Simulator coverage.

The public native connection still needs to combine this gate with live discovery and redaction. Tool invocation, capability UI, resources and prompts are not completed by this component. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Authorized native discovery presentation

`NativeMCPConnection` now exposes discovery preparation, review and execution through the independent policy gate. The approved launch combines that gate with the live negotiated traversal and returns only scoped display descriptions. Tool names, titles and descriptions pass through the launch's retained `ContentRedactor`, including the actual child-process secret values. Discovery does not reread Keychain; the retained redaction policy is released when the connection closes. Raw protocol pages, schemas and cursors do not escape through this presentation API. Redacted tool names are display labels, not executable identifiers; annotation hints remain untrusted claims and grant no authority.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime --filter MCPApprovedLaunchTests`: all 3 process integration tests passed (`TestResults/p3-07-native-discovery.log`).
- `swift test --package-path Packages/AgentDeskRuntime`: all 202 tests passed after extending missing-authority coverage (`TestResults/p3-07-native-discovery-final.log`). Synthetic servers echo a known child credential in all three display fields. Tests verify redaction and scope, allowed and separately approved discovery, approval-required denial, no extra secret reads, launch-only authority denial and closed-connection rejection.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-native-discovery-mac-build.log`). Documentation and diff checks pass. This Mac-only API adds no Simulator coverage.

Native discovery UI and its host authority wiring remain next; schema browsing and tool invocation are not implemented by the display API. P3-07/P3-08 remain in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Prompt discovery metadata

`MCPPromptDiscovery` decodes scoped `prompts/list` pages with bounded names, titles, descriptions, argument counts, prompts per page and cursors. It rejects duplicate prompt/argument names, malformed argument flags, invalid modern completion/cache metadata and cancellation. Optional argument-required hints remain optional; the original wire response preserves unknown metadata exactly. Prompt descriptions are untrusted server data and are never inserted into agent instructions by discovery.

Protocol fields were checked against the [official 2026-07-28 schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts) on 2026-09-15. Both legacy and modern metadata forms are supported. The decoder itself performs no prompt retrieval, cursor traversal or caching; live prompt discovery and its policy/UI integration remain outstanding.

Validation on macOS 26.5.2 / Xcode 26.0, local iPhone 16 Pro / iOS 26.0:

- `swift test --package-path Packages/AgentDeskMCP`: all 24 tests passed (`TestResults/p3-07-prompts.log`). After tightening the cancellation test to cancel after wire-fixture construction, all 24 passed again (`TestResults/p3-07-prompts-final.log`).
- From `Packages/AgentDeskMCP`: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-07-prompts-iphone.xcresult -parallel-testing-enabled NO test`: all 24 passed before the cancellation-test refinement (`TestResults/p3-07-prompts-iphone.log`). Production source was unchanged afterward.
- Both app builds passed using the standard Mac and primary-iPhone build commands (`TestResults/p3-07-prompts-mac-build.log`, `TestResults/p3-07-prompts-iphone-build.log`). Documentation/diff checks pass.

Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining. This component does not complete P3-07.

## Live prompt traversal

The internal negotiated Mac connection now requests `prompts/list` using the negotiated protocol and follows opaque continuation cursors. A single deadline bounds the traversal. It caps results at 100 pages, 10,000 prompts and 4 MiB of original response bytes, rejects duplicate names and cursor cycles, and returns only a complete catalog. Workspace/project and connection identity come from the transport; environment identity comes from the trusted caller. Cancellation and failures release partial local state without publishing it. Prompt content is neither fetched nor applied.

Validation on macOS 26.5.2 / Xcode 26.0:

- The first runtime build used stale generated SwiftPM metadata and could not see the newly added dependency source (`TestResults/p3-07-live-prompts.log`). `swift package --package-path Packages/AgentDeskRuntime clean` refreshed that build state.
- `swift test --package-path Packages/AgentDeskRuntime`: all 205 tests passed (`TestResults/p3-07-live-prompts-final.log`). New real synthetic process tests cover modern and legacy request metadata, identity/argument preservation, repeated cursors, duplicate names, each aggregate limit, timeout, cancellation and a subsequent successful ping.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-live-prompts-mac-build.log`). Documentation/diff checks pass. The traversal is Mac-only; no new Simulator coverage is claimed.

This internal API still requires prompt-specific policy integration and redacted native presentation before exposure. P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Authorized prompt presentation

The native connection now exposes prompt discovery preparation, review and execution. `prompts/list` receives an independent read-evidence action bound to the configuration revision, resource and scope; a tools/list approval cannot substitute for it. The existing before/after policy checks apply to the selected discovery action. The returned catalog contains scoped redacted names, titles and descriptions for prompts and each argument, preserving optional required flags. It exposes no raw wire pages and never fetches or adopts prompt content. The launch's existing known-secret redaction policy is reused without another credential read.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: all 205 tests passed (`TestResults/p3-07-prompt-authorization.log`). The live credential/process integration now checks allowed and approved prompt discovery, rejection of tool-approval substitution without consuming the valid tool approval, all six redacted prompt/argument text fields, scope/identity, unchanged secret-read count, missing authority and closed connection rejection.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-prompt-authorization-build.log`). Documentation/diff checks pass. This Mac-only integration adds no Simulator coverage.

Native prompt browsing UI remains next. P3-07/P3-08 remain in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Resource discovery metadata

`MCPResourceDiscovery` now decodes scoped resources/list metadata pages. It bounds page entries/cursors and display fields, validates absolute URI syntax without normalization or fetching, rejects duplicate URI entries and malformed sizes, and preserves exact unsigned byte counts and the original response. Identical display names may identify distinct URIs. MIME types, descriptions and unknown annotations remain server claims. A file URI is not interpreted as local filesystem authority.

Fields were checked against the [official 2026-07-28 resource schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts) on 2026-09-15. The local decoder accepts nonnegative integral byte sizes within UInt64, preserves custom URI schemes and URNs, and supports modern/legacy list metadata. Resource content, templates, live paging and policy/UI integration are separate remaining work.

Validation on macOS 26.5.2 / Xcode 26.0, iPhone 16 Pro / iOS 26.0:

- `swift test --package-path Packages/AgentDeskMCP`: all 27 tests passed (`TestResults/p3-07-resource-metadata.log`). New regressions cover custom/encoded URIs, equal labels with distinct URIs, all scope fields, exact size 9007199254740993, preserved raw annotations, opaque cursor encoding, malformed/relative/duplicate URIs, invalid sizes/MIME controls, bounds and cancellation.
- From `Packages/AgentDeskMCP`: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-07-resource-metadata-iphone.xcresult -parallel-testing-enabled NO test`: all 27 tests passed (`TestResults/p3-07-resource-metadata-iphone.log`).
- Both native app builds passed with the standard Mac and primary-iPhone build commands (`TestResults/p3-07-resource-metadata-mac-build.log`, `TestResults/p3-07-resource-metadata-iphone-build.log`). Documentation/diff checks pass.

P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Live resource traversal

The internal negotiated Mac session now follows resources/list cursors under a single deadline. It preserves scoped original pages and accepts distinct URIs with identical display names, while rejecting repeated URIs, cursor cycles and catalogs exceeding 100 pages, 10,000 resources or 4 MiB. Partial results remain local and are discarded on error/cancellation. Discovery does not open any resource URI or read its content.

Validation on macOS 26.5.2 / Xcode 26.0:

- Refreshed generated runtime dependency metadata with `swift package --package-path Packages/AgentDeskRuntime clean` after adding the shared resource source.
- `swift test --package-path Packages/AgentDeskRuntime`: all 208 tests passed (`TestResults/p3-07-live-resources.log`). Three additional real-process tests cover modern/legacy metadata and scope, equal names with distinct URIs, repeated URIs/cursors, each aggregate bound, timeout, cancellation and a subsequent successful ping.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-live-resources-build.log`). Documentation/diff checks pass. This Mac-only integration adds no Simulator coverage.

Resource-specific authorization, redacted native presentation and resource reading/templates remain outstanding. P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Authorized resource presentation

The native connection now exposes resource discovery preparation, review and execution. resources/list has its own immutable read-evidence action, separate from tools/list and prompts/list. The gate checks the selected action's scope/configuration/resource/policy before dispatch and before returning claims. Every display field, including URI, MIME type and formatted byte count, passes through the retained scoped redactor. Returned URI text is display metadata, not an executable URL or filesystem grant; no resource is opened or read.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: all 208 tests passed (`TestResults/p3-07-resource-authorization.log`). Live synthetic process tests now exercise allowed and independently approved resource discovery, rejection of both tool and prompt approval substitution while retaining those approvals for their proper operations, redacted URI/name/title/description/MIME fields, scoped byte count, unchanged credential-read count, missing authority and closed-connection rejection.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-resource-authorization-build.log`). Documentation/diff checks pass. This Mac-only integration adds no Simulator coverage.

Resource browsing UI is next; reading, templates, tool invocation and remaining lifecycle/manager requirements remain outstanding. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Resource content decoding

`MCPResourceRead` encodes resources/read parameters and decodes scoped text/binary results. It preserves the requested URI separately from returned content URIs (a server can return related parts), exact wire evidence, UTF-8 text and strict canonical base64 bytes. Ambiguous text/blob fields, null or malformed bodies, invalid URI/MIME metadata and missing modern cache/completion fields fail closed. The decoder caps content at 128 items and 192 KiB of aggregate decoded bytes within the existing wire bound. An input_required result returns a dedicated error; no interaction is answered automatically. Content remains untrusted and unredacted until runtime policy/redaction integration; no file is opened or payload interpreted.

Read-resource fields were checked against the [official 2026-07-28 schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts) on 2026-09-15. This decoder does not implement transport dispatch, content rendering, authorization or caching.

Validation on macOS 26.5.2 / Xcode 26.0, iPhone 16 Pro / iOS 26.0:

- `swift test --package-path Packages/AgentDeskMCP`: all 30 tests passed (`TestResults/p3-07-resource-read-final.log`). Malformed-body regressions were refined after the initial passing run to ensure they fail independently of modern metadata checks. Tests cover exact requested identity and raw evidence, Unicode text, binary bytes, opaque URI parameters, related content URIs, ambiguity/null/base64 errors, input-required results, limits and cancellation.
- From `Packages/AgentDeskMCP`: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-07-resource-read-iphone.xcresult -parallel-testing-enabled NO test`: all 30 tests passed (`TestResults/p3-07-resource-read-iphone.log`).
- Both app builds passed using the standard Mac and primary-iPhone commands (`TestResults/p3-07-resource-read-mac-build.log`, `TestResults/p3-07-resource-read-iphone-build.log`). Documentation/diff checks pass.

Live resource reading and its exact-action authorization/redacted UI remain next. P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Live resource read transport

The internal negotiated stdio connection now dispatches resources/read with the exact requested URI and negotiated metadata, then decodes bounded scoped text/binary contents. Invalid URIs fail before dispatch. Malformed responses and input-required results fail without initiating interaction. This internal boundary is not exposed through the native connection: exact-URI authorization and redaction remain required before user-facing reads.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift package --package-path Packages/AgentDeskRuntime clean` followed by `swift test --package-path Packages/AgentDeskRuntime`: 211 tests passed, zero failures (`TestResults/p3-07-live-resource-read.log`). Three new synthetic-process tests exercise modern/legacy requests, exact request identity, text and binary bodies, malformed/input-required responses, invalid URI, timeout, cancellation and continued connection health.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-live-resource-read-mac-build.log`). This Mac-only integration adds no Simulator coverage.

P3-07 remains in progress. Exact-resource policy and redacted presentation are next; counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Exact-resource read policy

The internal launch policy session now prepares, reviews and executes a separate resources/read action. Its immutable fingerprint includes the unnormalized URI and configuration revision, with existing project/environment/resource and authority bindings. Listing, launch and different-URI approvals cannot substitute for content-read approval. Reads revalidate configuration and policy before dispatch and before returning content. The session uses one read action identifier with distinct payload fingerprints, serializing concurrent reads without retaining an unbounded URI-action cache.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: 212 tests passed (`TestResults/p3-07-resource-read-policy.log`). The added regression covers deny/allow/approval, launch/listing approval substitution, encoded versus decoded URI mismatch, preserving the proper approval after mismatch, configuration changes during dispatch and closed-session rejection.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-resource-read-policy-build.log`). No new Simulator coverage is claimed for this Mac-only boundary.

The policy boundary is internal; native resource-read dispatch and redacted content presentation are still pending. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Authorized resource content presentation

NativeMCPConnection now exposes resource-read preparation, review and execution through the exact-URI gate. Resource discovery issues opaque UUID selections; original URIs remain in a bounded connection-owned mapping and never come from redacted labels. Refresh clears prior selections, concurrent discovery generations cannot publish older mappings, and close releases mappings. Unknown or stale selections fail closed. The runtime rechecks selection validity before returning content.

Text, returned URI and MIME metadata use the retained credential-aware scoped redactor. Binary contents are represented only by a redacted byte count; binary rendering/export and raw evidence persistence are not implemented by this presentation boundary. No returned text is executed or adopted as instructions.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Packages/AgentDeskRuntime`: 212 tests passed (`TestResults/p3-07-resource-read-presentation.log`). Expanded synthetic-process integration exercises allowed and independently approved reads using the original secret-bearing URI, listing-approval rejection, unknown/refreshed/closed selection rejection, redacted text/URI/MIME fields, binary byte-count presentation, exact scope/environment/connection identity and a single credential read for the connection lifetime. The integration's outer failure assertion was strengthened so expected startup denial cannot hide errors after an authorized launch.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-resource-read-presentation-build.log`). No new Simulator coverage is claimed for this Mac-only API.

Native read controls/content UI remain next. P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Resource template metadata decoding

MCPResourceTemplateDiscovery decodes bounded resources/templates/list pages with project/environment/connection identity, exact raw evidence and opaque cursors. It preserves template expressions and optional description/title/MIME metadata, rejects duplicate templates, missing fields and oversized pages, and checks modern completion/cache metadata. Template text remains an untrusted claim: this decoder does not validate RFC 6570 grammar, expand variables, dispatch discovery or grant read permission. Relative template expressions are preserved rather than passed through an absolute-URL parser.

Fields were checked against the [official 2026-07-28 schema](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts) on 2026-09-15. Template grammar/expansion, runtime traversal, authorization and native presentation remain outstanding.

Validation on macOS 26.5.2 / Xcode 26.0 and iPhone 16 Pro / iOS 26.0:

- `swift test --package-path Packages/AgentDeskMCP`: all 33 tests passed (`TestResults/p3-07-resource-templates.log`). Three new regressions cover opaque expressions, exact extension evidence, scopes/cursors, metadata failures, duplicate templates, page limits and cancellation.
- From `Packages/AgentDeskMCP`: `xcodebuild -scheme AgentDeskMCP -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-06/MCPIPhone -resultBundlePath ../../TestResults/p3-07-resource-templates-iphone.xcresult -parallel-testing-enabled NO test`: all 33 tests passed (`TestResults/p3-07-resource-templates-iphone.log`).
- Both native app builds passed with the standard Mac and primary-iPhone commands (`TestResults/p3-07-resource-templates-mac-build.log`, `TestResults/p3-07-resource-templates-iphone-build.log`). Documentation/diff checks pass.

P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Live resource template discovery

The negotiated stdio connection now traverses resources/templates/list with modern or legacy metadata. It retains partial pages locally and publishes only a complete scoped catalog. A single deadline spans pagination; duplicate template identities, cursor cycles, over 100 pages, over 10,000 templates or over 4 MiB of aggregate wire evidence fail closed. Template expansion and interpretation do not occur. The boundary remains internal pending separate authorization and redacted presentation.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift package --package-path Packages/AgentDeskRuntime clean` refreshed the dependency graph for the new shared decoder, followed by `swift test --package-path Packages/AgentDeskRuntime`: 215 tests passed (`TestResults/p3-07-live-resource-templates.log`). Three added live synthetic-process regressions cover both protocol modes, two-page identity/scope, duplicate templates, cursor cycles, aggregate page/item/byte limits, timeout/cancellation and continued connection health.
- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`: signed Mac build passed (`TestResults/p3-07-live-resource-templates-build.log`). This Mac-only traversal adds no Simulator coverage. Documentation/diff checks pass.

Template authorization and presentation remain next. P3-07 remains in progress: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

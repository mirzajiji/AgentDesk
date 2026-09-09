# Native Apple targets and package structure

Status: initial native foundation implemented and tested on Mac/iPhone 16 Pro. Most modules remain planned. Source: [final architecture](final-architecture.txt), sections 4 and 75.
<!-- Source sections: 4,75 -->

The Mac application is the execution host. The iOS application is a constrained companion. Both share domain and protocol types through Swift packages; platform-specific adapters stay at the application/runtime boundary.

## Intended modules

| Module | Owned concerns | Platform boundary |
| --- | --- | --- |
| AgentDeskCore | IDs, scoped domain records, validation and logical execution profiles | Shareable |
| AgentDeskRuntime | Run engine, provider execution, workflows and deterministic routing | Mac execution |
| AgentDeskProtocol | Versioned Codable commands, events and safe response projections | Shareable |
| AgentDeskClient | Connection/session state and remote-client reducers | Companion/client |
| AgentDeskPersistence | SQLite operational stores and configuration adapters | Scoped local storage |
| AgentDeskSecurity | Policy, approvals, Keychain abstraction, redaction and device authority | Platform adapters where needed |
| AgentDeskMCP | Client transports, discovery, local process lifecycle | Mac authority |
| AgentDeskPlugins | Normalized integration capabilities and lifecycle | Mac authority |
| AgentDeskDatabases | Driver contracts, query controls and connection metadata | Mac authority |
| AgentDeskDesign | Shared visual components and status presentation | SwiftUI |

The source architecture places these under `Packages/`, with separate applications under `Apps/`, and shared configuration, runtime data, tests and documentation. The existing user-created project has a single multiplatform app target. Evolve it incrementally; do not discard it or mark empty package directories as implemented modules.

## Dependency direction

Core types must not import the application or concrete provider. Protocol DTOs must not contain Keychain handles, subprocess objects, database drivers, or unrestricted paths. Runtime uses abstractions and platform implementations; the mobile target must not link a Mac execution implementation to enable privileged behavior locally.

Use `async/await`, actors, structured tasks, `AsyncSequence` and `AsyncStream`. UI state lives on `@MainActor`; domain work and I/O should not block it. Explicitly account for actor reentrancy, cancellation, subscriber cleanup and backpressure. Do not silence concurrency errors using unchecked sendability as a default repair.

## Native experience

Use navigation split views, inspectors, toolbars, sheets, context menus, Commands, Settings, MenuBarExtra and appropriate native previews. Present an engineering workspace with keyboard-driven navigation and detailed inspection. Business rules and storage access belong in services, not SwiftUI view bodies.

## Decisions to close during implementation

- Verify the selected macOS 15/iOS 18 minimums on real supported runtimes before treating them as release-support guarantees.
- Establish the supported distribution/signing and Mac execution-host arrangement for Codex and local tooling. The template's app-sandbox setting alone does not prove subprocess execution can satisfy product requirements.
- Complete Xcode/runtime acceptance for Swift 6 and the new shared scheme; direct compiler checks are supplementary.
- Keep platform support aligned with Mac+iPhone; visionOS is outside current scope.

Validate both native builds, package dependency direction, platform exclusions, real unit targets, application launch and iPhone simulator execution before calling the platform foundation complete.

## Current implementation — P1-01

The original multiplatform Xcode target now links local Core and Design packages with substantive shell-navigation and shared empty-state code. The shared scheme includes both existing test targets. Swift 6 and macOS 15/iOS 18 compilation targets are selected; incidental visionOS and iPad device-family support is removed. Mac execution services, mobile pairing and the other planned modules have not been implemented.

Core has five passing SwiftPM cases, reused in native unit targets. Full Xcode builds, app launch and unit/UI tests pass on the Mac and iPhone 16 Pro/iOS 26. Mac arm64/Intel and iPhone simulator/device source compilation checks also pass. The wider device/OS matrix is deferred to final acceptance by user instruction. See [P1-01 validation](../Development/p1-01-validation.md) for exact evidence and commands.

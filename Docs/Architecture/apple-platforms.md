# Native Apple targets and package structure

Status: planned design. Source: [final architecture](final-architecture.txt), sections 4 and 75.
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

- Select minimum supported macOS/iOS versions using the required APIs and the test matrix. The current template targets version 26.0; this is a scaffold setting, not a completed product-support decision.
- Establish the supported distribution/signing and Mac execution-host arrangement for Codex and local tooling. The template's app-sandbox setting alone does not prove subprocess execution can satisfy product requirements.
- Adopt a tested Swift language/concurrency mode and shared schemes. The template currently declares Swift 5.0 despite the installed Swift 6.2 toolchain.
- Decide whether to remove incidental visionOS template support after assessing the requested Mac+iPhone scope.

Validate both native builds, package dependency direction, platform exclusions, real unit targets, application launch and iPhone simulator execution before calling the platform foundation complete.

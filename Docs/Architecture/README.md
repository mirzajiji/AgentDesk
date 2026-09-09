# AgentDesk architecture documentation

**Current product state:** the actual app repository contains the initial Xcode multiplatform scaffold. The pages below describe the intended product, implementation boundaries and acceptance requirements; they do not claim working features.

**Current location:** this documentation lives with the Xcode app in `/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk`. Source writes and implementation-branch creation now succeed. See the [current validation record](../Development/updated-project-validation.md).

## Start here

- [System overview and delivery phases](overview.md)
- [Full supplied 159-section architecture](final-architecture.txt)
- [Coverage of every source section](coverage.md) and [JSON map](coverage.json)
- [Commit-sized implementation plan](../Development/tasks.md)
- [macOS/iPhone testing requirements](../Development/testing.md)
- [Documentation maintenance rules](documentation.md)

## Subsystem documents

| Document | Primary source sections |
| --- | --- |
| [Agents, templates and skills](agents-and-skills.md) | 18–19, 21 |
| [Project dashboards and operational analytics](analytics.md) | 116 |
| [Native Apple targets and package structure](apple-platforms.md) | 4, 75 |
| [Bug registry, duplicate detection and CityPay formatting](bug-registry.md) | 51–65 |
| [Calendar sync and compact upcoming-event UI](calendar.md) | 159 |
| [Codex CLI provider and account management](codex.md) | 23–28 |
| [Configuration composition and versioning](configuration.md) | 8, 10, 131–133 |
| [Project databases and controlled SQL](databases.md) | 41–50 |
| [Device pairing, trust and revocation](device-pairing.md) | 87–88 |
| [Documentation ownership and maintenance](documentation.md) | 112–113 |
| [Runs, steps and provider execution](execution.md) | 66–67 |
| [Extension development, local CLI and CI](extensions.md) | 155–157 |
| [Context import, OpenAPI and contract drift](importing.md) | 144–146 |
| [LAN discovery, live streaming and reconnection](local-network.md) | 83, 85–86, 94–95, 97 |
| [MCP integration and future server surface](mcp.md) | 37–40 |
| [Native navigation, onboarding and interaction](native-interface.md) | 76–82, 104, 152 |
| [Retention, backup, restore and recovery](operations.md) | 137, 153 |
| [Product and system overview](overview.md) | 1–3, 5, 20, 99, 108–110, 114, 158 |
| [Policy, approvals and production safety](permissions.md) | 72–73, 129–130, 141 |
| [Local persistence and recovery](persistence.md) | 100 |
| [Plugins, connection lifecycle and diagnostics](plugins.md) | 31–36, 105–106, 142 |
| [Project memory, retrieval and knowledge relationships](project-memory.md) | 11–12, 17, 103, 107, 149–151 |
| [Projects, environments and onboarding](projects.md) | 143, 147 |
| [Mac authority and iPhone companion API](remote-access.md) | 84, 89–93, 98 |
| [Git integration and change review](repositories.md) | 71, 148, 154 |
| [Environment snapshots, reruns and comparison](reproducibility.md) | 117, 121–122 |
| [Immutable requirements and traceability](requirements.md) | 13–16 |
| [Operational events, traces, artifacts and provenance](run-events.md) | 68–70, 102, 118–119 |
| [Manual scenarios and Postman collections](scenarios.md) | 115 |
| [Security boundaries, secrets, classification and audit](security.md) | 96, 101, 138–140 |
| [Testing strategy, agent evals and coverage](testing-and-coverage.md) | 74, 111, 123–125 |
| [Provider usage and local activity](usage.md) | 29–30 |
| [Workflows, scheduling and execution controls](workflows.md) | 22, 120, 126–127, 134–136 |
| [Workspaces and company isolation](workspaces.md) | 6–7, 9, 128 |

## Status and unresolved implementation decisions

No app code, new app commit, or product unit/simulator pass was produced by this documentation task. The native scaffold still needs real domain models, services, UI flows and tests. Decisions such as supported deployment versions, execution-host distribution, concrete persistence schemas, MCP/remote protocol versions, cryptographic pairing and supported collection runners must be implemented and verified before they become release claims.

Documentation-only validation checks source integrity, section coverage, local links, required pages and formatting. Future feature commits must update their subsystem pages alongside actual test evidence.

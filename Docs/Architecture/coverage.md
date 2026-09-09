# Architecture requirement coverage

Every one of the 159 source sections has a primary documentation owner. This is **documentation coverage**, not evidence of implementation or passing tests. All mapped product features remain planned unless a later feature validation record establishes otherwise.

The exact supplied specification is [preserved here](final-architecture.txt). A [machine-readable map](coverage.json) includes original source line numbers and the source hash.

| Section | Requirement | Primary documentation | Source line |
| --- | --- | --- | --- |
| 1 | Product Vision | [overview](overview.md) | 3 |
| 2 | Non-Negotiable Architecture Decisions | [overview](overview.md) | 39 |
| 3 | Core Architecture | [overview](overview.md) | 73 |
| 4 | Apple Platform Structure | [apple-platforms](apple-platforms.md) | 149 |
| 5 | Mac Is the Execution Authority | [overview](overview.md) | 194 |
| 6 | Workspaces and Projects | [workspaces](workspaces.md) | 226 |
| 7 | Strict Company Isolation | [workspaces](workspaces.md) | 259 |
| 8 | Filesystem as Source of Truth | [configuration](configuration.md) | 291 |
| 9 | Suggested Workspace Structure | [workspaces](workspaces.md) | 309 |
| 10 | Configuration Inheritance | [configuration](configuration.md) | 356 |
| 11 | Project Memory | [project-memory](project-memory.md) | 394 |
| 12 | Temporary Context vs Permanent Memory | [project-memory](project-memory.md) | 424 |
| 13 | Requirements Versioning | [requirements](requirements.md) | 454 |
| 14 | Requirement Editing UX | [requirements](requirements.md) | 496 |
| 15 | Tests Use Latest Requirement | [requirements](requirements.md) | 513 |
| 16 | Requirement/Test Traceability | [requirements](requirements.md) | 530 |
| 17 | Knowledge Retrieval | [project-memory](project-memory.md) | 562 |
| 18 | Agent System | [agents-and-skills](agents-and-skills.md) | 587 |
| 19 | Suggested QA Agents | [agents-and-skills](agents-and-skills.md) | 617 |
| 20 | Deterministic Code vs Agent | [overview](overview.md) | 638 |
| 21 | Skills | [agents-and-skills](agents-and-skills.md) | 666 |
| 22 | Workflows | [workflows](workflows.md) | 697 |
| 23 | Codex CLI Only | [codex](codex.md) | 742 |
| 24 | Codex CLI Provider | [codex](codex.md) | 762 |
| 25 | Codex Account Management | [codex](codex.md) | 790 |
| 26 | Codex Account Switching | [codex](codex.md) | 833 |
| 27 | Execution Profiles / Model Routing | [codex](codex.md) | 847 |
| 28 | Escalation | [codex](codex.md) | 884 |
| 29 | Codex Usage Dashboard | [usage](usage.md) | 911 |
| 30 | Token Usage | [usage](usage.md) | 959 |
| 31 | Plugins | [plugins](plugins.md) | 984 |
| 32 | Plugin Isolation | [plugins](plugins.md) | 1007 |
| 33 | Plugin Lifecycle | [plugins](plugins.md) | 1028 |
| 34 | Plugin Permissions | [plugins](plugins.md) | 1056 |
| 35 | Jira Plugin Setup | [plugins](plugins.md) | 1079 |
| 36 | Plugins vs MCP | [plugins](plugins.md) | 1118 |
| 37 | MCP Is a Core Architectural Pillar | [mcp](mcp.md) | 1142 |
| 38 | MCP UI | [mcp](mcp.md) | 1161 |
| 39 | MCP Permissions | [mcp](mcp.md) | 1205 |
| 40 | AgentDesk as MCP Server | [mcp](mcp.md) | 1221 |
| 41 | Databases Per Project | [databases](databases.md) | 1248 |
| 42 | Database Setup | [databases](databases.md) | 1264 |
| 43 | Database Secrets | [databases](databases.md) | 1302 |
| 44 | Database Lifecycle | [databases](databases.md) | 1321 |
| 45 | Database Permissions | [databases](databases.md) | 1347 |
| 46 | SQL Classification | [databases](databases.md) | 1372 |
| 47 | Database Tools | [databases](databases.md) | 1391 |
| 48 | Database Schema Browser | [databases](databases.md) | 1430 |
| 49 | Database Query Console | [databases](databases.md) | 1445 |
| 50 | Database Evidence | [databases](databases.md) | 1461 |
| 51 | Bug Registry | [bug-registry](bug-registry.md) | 1481 |
| 52 | Manual Bug Registration | [bug-registry](bug-registry.md) | 1502 |
| 53 | Mandatory Duplicate Detection | [bug-registry](bug-registry.md) | 1528 |
| 54 | Duplicate Ticket Behavior | [bug-registry](bug-registry.md) | 1574 |
| 55 | Possible Duplicates | [bug-registry](bug-registry.md) | 1588 |
| 56 | Blocked Downstream Scenarios | [bug-registry](bug-registry.md) | 1606 |
| 57 | Bug Relationships | [bug-registry](bug-registry.md) | 1627 |
| 58 | CityPay Jira Bug Skill | [bug-registry](bug-registry.md) | 1645 |
| 59 | CityPay Ticket Structure | [bug-registry](bug-registry.md) | 1668 |
| 60 | CityPay Ticket Rules | [bug-registry](bug-registry.md) | 1688 |
| 61 | CityPay Failure Grouping | [bug-registry](bug-registry.md) | 1761 |
| 62 | CityPay API Validation Rules | [bug-registry](bug-registry.md) | 1777 |
| 63 | CityPay Status Bugs | [bug-registry](bug-registry.md) | 1791 |
| 64 | CityPay Concurrency Bugs | [bug-registry](bug-registry.md) | 1803 |
| 65 | CityPay UI Bugs | [bug-registry](bug-registry.md) | 1820 |
| 66 | Run Engine | [execution](execution.md) | 1837 |
| 67 | Structured Run Steps | [execution](execution.md) | 1874 |
| 68 | Event Bus | [run-events](run-events.md) | 1893 |
| 69 | Tracing | [run-events](run-events.md) | 1921 |
| 70 | Artifacts | [run-events](run-events.md) | 1946 |
| 71 | Git/File Change Tracking | [repositories](repositories.md) | 1969 |
| 72 | Policy Engine | [permissions](permissions.md) | 1990 |
| 73 | Approval Engine | [permissions](permissions.md) | 2015 |
| 74 | Agent Testing / Evals | [testing-and-coverage](testing-and-coverage.md) | 2048 |
| 75 | Native macOS UI | [apple-platforms](apple-platforms.md) | 2075 |
| 76 | Main Mac Navigation | [native-interface](native-interface.md) | 2096 |
| 77 | Overview | [native-interface](native-interface.md) | 2126 |
| 78 | Agent Editor | [native-interface](native-interface.md) | 2144 |
| 79 | Context Inspector | [native-interface](native-interface.md) | 2166 |
| 80 | Command Palette | [native-interface](native-interface.md) | 2191 |
| 81 | Menu Bar | [native-interface](native-interface.md) | 2216 |
| 82 | Native Notifications | [native-interface](native-interface.md) | 2233 |
| 83 | Local Wi-Fi Remote Operation | [local-network](local-network.md) | 2248 |
| 84 | LAN Architecture | [remote-access](remote-access.md) | 2266 |
| 85 | Bonjour / Local Discovery | [local-network](local-network.md) | 2283 |
| 86 | LAN Connection Modes | [local-network](local-network.md) | 2304 |
| 87 | Device Pairing | [device-pairing](device-pairing.md) | 2336 |
| 88 | Trusted Devices | [device-pairing](device-pairing.md) | 2365 |
| 89 | iPhone Capabilities | [remote-access](remote-access.md) | 2383 |
| 90 | iPhone Restrictions | [remote-access](remote-access.md) | 2411 |
| 91 | iPhone Run UI | [remote-access](remote-access.md) | 2429 |
| 92 | Mobile Diff Review | [remote-access](remote-access.md) | 2451 |
| 93 | Mobile Approval | [remote-access](remote-access.md) | 2465 |
| 94 | LAN Reconnection | [local-network](local-network.md) | 2485 |
| 95 | Apple Local Network Permissions | [local-network](local-network.md) | 2511 |
| 96 | Remote Security | [security](security.md) | 2523 |
| 97 | Live Socket-Based Mac ↔ iPhone Streaming | [local-network](local-network.md) | 2539 |
| 98 | Local Server | [remote-access](remote-access.md) | 2651 |
| 99 | No Mandatory Cloud | [overview](overview.md) | 2671 |
| 100 | Persistence | [persistence](persistence.md) | 2688 |
| 101 | Secrets | [security](security.md) | 2717 |
| 102 | Logging | [run-events](run-events.md) | 2743 |
| 103 | Search | [project-memory](project-memory.md) | 2761 |
| 104 | First-Run Experience | [native-interface](native-interface.md) | 2782 |
| 105 | Connections Overview | [plugins](plugins.md) | 2822 |
| 106 | Health Monitoring | [plugins](plugins.md) | 2844 |
| 107 | Project Relationship Graph | [project-memory](project-memory.md) | 2865 |
| 108 | Example Full QA Execution | [overview](overview.md) | 2898 |
| 109 | AgentDesk Product Principles | [overview](overview.md) | 2959 |
| 110 | Development Phases | [overview](overview.md) | 2996 |
| 111 | Testing Requirements | [testing-and-coverage](testing-and-coverage.md) | 3127 |
| 112 | Required Architecture Documentation | [documentation](documentation.md) | 3211 |
| 113 | AGENTS.md | [documentation](documentation.md) | 3240 |
| 114 | Final Acceptance Scenario | [overview](overview.md) | 3273 |
| 115 | Manual Scenario Runner / Postman Collections | [scenarios](scenarios.md) | 3324 |
| 116 | Per-Project Dashboard, Statistics & Tool/Model Analytics | [analytics](analytics.md) | 3576 |
| 117 | Environment Snapshot & Reproducibility | [reproducibility](reproducibility.md) | 3847 |
| 118 | Evidence Provenance | [run-events](run-events.md) | 3901 |
| 119 | Confidence / Evidence Quality | [run-events](run-events.md) | 3955 |
| 120 | Task Templates / Quick Actions | [workflows](workflows.md) | 3983 |
| 121 | Run Replay / Clone Run | [reproducibility](reproducibility.md) | 4029 |
| 122 | Compare Runs | [reproducibility](reproducibility.md) | 4055 |
| 123 | Test Coverage Map | [testing-and-coverage](testing-and-coverage.md) | 4087 |
| 124 | Missing Coverage Detection | [testing-and-coverage](testing-and-coverage.md) | 4119 |
| 125 | Test Data Management | [testing-and-coverage](testing-and-coverage.md) | 4136 |
| 126 | Preflight Checks | [workflows](workflows.md) | 4169 |
| 127 | Tool Fallbacks | [workflows](workflows.md) | 4189 |
| 128 | Workspace Lock / Visual Safety Indicator | [workspaces](workspaces.md) | 4213 |
| 129 | Production Safety Mode | [permissions](permissions.md) | 4237 |
| 130 | Dry Run Mode | [permissions](permissions.md) | 4256 |
| 131 | Workflow Versioning | [configuration](configuration.md) | 4278 |
| 132 | Agent Configuration Versioning | [configuration](configuration.md) | 4294 |
| 133 | Change Review Before Agent Configuration Save | [configuration](configuration.md) | 4313 |
| 134 | Run Budgets | [workflows](workflows.md) | 4326 |
| 135 | Concurrency Control | [workflows](workflows.md) | 4352 |
| 136 | Resource Locks | [workflows](workflows.md) | 4368 |
| 137 | Artifact Retention Policies | [operations](operations.md) | 4383 |
| 138 | Sensitive Data Classification | [security](security.md) | 4401 |
| 139 | Redaction Engine | [security](security.md) | 4423 |
| 140 | Audit Log | [security](security.md) | 4443 |
| 141 | Plugin/MCP Permission Presets | [permissions](permissions.md) | 4469 |
| 142 | Connection Diagnostics | [plugins](plugins.md) | 4491 |
| 143 | Project Onboarding Wizard | [projects](projects.md) | 4518 |
| 144 | Import Existing Project Context | [importing](importing.md) | 4539 |
| 145 | OpenAPI Support | [importing](importing.md) | 4556 |
| 146 | Contract Drift Detection | [importing](importing.md) | 4577 |
| 147 | Git Integration as First-Class Project Setup | [projects](projects.md) | 4596 |
| 148 | Repository Safety | [repositories](repositories.md) | 4615 |
| 149 | Notes / Manual Findings | [project-memory](project-memory.md) | 4630 |
| 150 | Inbox / Unclassified Information | [project-memory](project-memory.md) | 4644 |
| 151 | Universal Project Timeline | [project-memory](project-memory.md) | 4665 |
| 152 | Deep Linking | [native-interface](native-interface.md) | 4684 |
| 153 | Backup & Restore | [operations](operations.md) | 4693 |
| 154 | Git-Based Configuration Backup | [repositories](repositories.md) | 4711 |
| 155 | Extension Readiness | [extensions](extensions.md) | 4723 |
| 156 | Command-Line Interface for AgentDesk | [extensions](extensions.md) | 4743 |
| 157 | CI Invocation | [extensions](extensions.md) | 4763 |
| 158 | Final Architecture Principle: AgentDesk Is the System of Context | [overview](overview.md) | 4778 |
| 159 | Calendar Sync & Upcoming Event Widget | [calendar](calendar.md) | 4819 |

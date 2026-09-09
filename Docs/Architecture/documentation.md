# Documentation ownership and maintenance

Status: documentation contract. Source: [final architecture](final-architecture.txt), sections 112–113.
<!-- Source sections: 112,113 -->

The preserved [source architecture](final-architecture.txt) defines the target product. The [documentation index](README.md) links subsystem decisions and [coverage map](coverage.md) assigns every source section to a document. Coverage means documented scope, not implemented or tested features.

## Documentation layers

| Layer | What belongs there |
| --- | --- |
| Root README | Honest product status, entry points, current build/run/test instructions and limitations |
| AGENTS.md | Architecture and contribution rules, isolation/security, extension guidance, commit/test requirements |
| Architecture pages | Boundaries, responsibilities, data contracts, failure cases and acceptance expectations |
| Development plan | Commit-sized tasks, prerequisites, exact progress and unimplemented scope |
| Validation records | Commands, environment, simulator model/OS, measured results and known gaps |
| Future operational/user guides | Implemented installation/setup, workflows, recovery, diagnostics and supported usage |

The requested architecture pages include overview, Apple platforms, workspaces, projects, project memory, requirements, bugs, execution/Codex, plugins/MCP/databases, workflows, security/permissions, persistence/events, remote/LAN/pairing and usage. Additional pages cover later requirements including scenarios, analytics, imports, reproduction, coverage, operations, extensions and calendar.

## Update rules

When implementing a subsystem, update its design page with concrete contracts and decisions, mark its actual status, add meaningful tests, record validation and include documentation in the feature's commit. Keep historical validation records accurate; do not rewrite failed checks as passes after a later repair. Add a new record for the later result.

Label implementation proposals and unresolved decisions. Do not publish guessed CLI flags, supported OS versions, dependencies, network protocol schemas or fabricated usage as established behavior. User guides must not describe disabled placeholders as available actions.

Preserve source requirements and traceability when splitting or renaming pages. Check local links, numbered-section coverage, source integrity and accidental secret/company-data inclusion. Documentation-only changes require these checks, not unit tests that merely assert prose.

## Current locations

The app and current documentation share `/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk`. The outer workspace retains historical documentation. B01 is committed as `4d027e9`; foundation source and current test evidence are recorded in [P1-01 validation](../Development/p1-01-validation.md). Session restrictions are not product architecture decisions.

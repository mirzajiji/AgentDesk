# Native navigation, onboarding and interaction

Status: initial shell implemented and native UI-tested; full interfaces remain planned. Source: [final architecture](final-architecture.txt), sections 76–82, 104 and 152.
<!-- Source sections: 76,77,78,79,80,81,82,104,152 -->

The Mac navigation covers Overview, Workspaces, Projects, Agents, Runs, Workflows, Skills, Connections (plugins/MCP/databases/repositories), Project Memory (requirements/validation/bugs/tests/documentation), Approvals, Artifacts, Traces and Settings. Add destinations as real functionality exists; blank panels must not imply implemented features.

## Main surfaces

Overview shows active/failed runs, pending approvals, recent activity, workspace and connection status, Codex readiness, remote devices and usage. Agent editing covers general settings, instructions, execution, tools, skills, knowledge, integrations, permissions, outputs, tests and versions.

The context inspector answers what an agent will know: scope, instructions, skills, requirement versions, selected knowledge/environment, integration/repository access and prior-run context. Cross-workspace data should be absent by enforced scope. Show validation errors and unavailable sources before launch.

First run checks Codex, Git and local runtime readiness, then helps create workspace, project and first agent. Optional remote pairing follows explicit enablement. Setup must remain recoverable if a dependency is missing or the user cancels an optional connection.

## Commands and persistent controls

Command-K opens a searchable command palette for run/start, context switching, knowledge search, creation, connections, approvals and settings. Commands must share service and policy entry points with their visible UI actions. Preserve keyboard focus and predictable escape/return behavior.

MenuBarExtra shows active runs, approvals and failure counts with open/run/approval controls and appropriate pause behavior. Native notifications cover approvals, completion/failure, important results, connection loss and device events. Make notifications optional and avoid sensitive content in previews.

Stable `agentdesk://` links address authorized workspace/project resources such as runs, bugs and requirements. Validate link structure and scope on open; a deep link must not grant access or execute a side effect merely by being opened.

## Accessibility and verification

Use native labels, focus order, keyboard shortcuts, scalable layout and clear status text beyond color alone. Test empty/loading/error/offline states, long names, large text, light/dark appearance, split-view resizing, command routing, invalid/deleted deep-link targets and context switching during active work. UI success must reflect persisted/authoritative state, not optimistic placeholder data.

## Initial shell

P1-01 introduces a native Mac split-view sidebar with empty Workspaces, Runs and Connections destinations and an unpaired iPhone screen. These surfaces do not yet create resources, execute agents or pair devices. Selection is a small Core value type; views own only presentation state. Native XCTest covers selection, launch, Mac sidebar navigation, appearance, iPhone rotation and largest accessibility text. Mac and primary iPhone runs pass. See [foundation validation](../Development/p1-01-validation.md).

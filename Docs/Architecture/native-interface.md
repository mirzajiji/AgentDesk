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

### Mac window and display adaptation

The user's additional display requirement (2026-09-10) covers 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K screens. Layout follows the available logical window size and macOS scaling. It must not branch on physical diagonal or assume that a 4K screen provides 3840×2160 logical points. The [native display matrix](../Development/testing.md#mac-display-and-window-matrix) defines window, scaling and hardware acceptance, including both common interpretations of the requested 2K target until the exact panel is known.

Scrollable setup forms and JSON editors use a shared native resizable layout with a compact usable content minimum and a suggested opening size. Their content can grow as windows expand. Verify primary actions, focus and text at compact sizes, and use extra space for desktop lists, inspectors, results and diffs as those surfaces arrive. Existing fixed-size editors still need the planned P1-14/P1-15 audit. Offscreen layout measurements alone do not prove interactive or physical display acceptance.

## Initial shell

P1-01 introduces a native Mac split-view sidebar with empty Workspaces, Runs and Connections destinations and an unpaired iPhone screen. These surfaces do not yet create resources, execute agents or pair devices. Selection is a small Core value type; views own only presentation state. Native XCTest covers selection, launch, Mac sidebar navigation, appearance, iPhone rotation and largest accessibility text. Mac and primary iPhone runs pass. See [foundation validation](../Development/p1-01-validation.md).


## Project setup screens (P1-13c1)

The app provides **Workspaces → project → Setup** with native folder selection, registration/access status and versioned workspace/project execution forms. The UI uses the scoped registration and setup services described in [repositories](repositories.md) and [configuration](configuration.md). Repository access is checked on reload; registration removal preserves the actual folder. Forms preserve advanced saved constraints and make starting settings explicit review/save actions. Advanced JSON exposes the complete configuration, validates scope/limits before applying to the form and still requires an explicit Save Settings action.

Native acceptance passes: 310 Mac unit/integration tests, four Mac UI scenarios and 224 iPhone tests. External folder access survives relaunch; configuration save/cancel, advanced schema edits and compact-window keyboard actions are verified. The JSON field uses a native plain-text editor with automatic substitutions disabled so macOS smart quotes cannot corrupt the document. Physical display matrix coverage remains pending. The context inspector/live run console is described below. See [validation](../Development/p1-13c1-validation.md).


## Project run console (P1-13c2)

**Workspaces → project → Run** opens the native console. Choose an agent and environment, review the current composed instructions/source versions/effective configuration, enter a task and prepare it. Preparation freezes sanitized input and a fingerprint-bound action. The user explicitly approves and starts, or rejects, the prepared action. A stale context must be reviewed again. Opening the console never starts Codex.

The Mac displays persisted run state and step progress through an authorized sequence-based stream. Open-ended runs show no overall percentage. Cancellation and confirmed close await execution cleanup; closing releases project ownership. In-app execution-setting saves stop affected sessions before writing, while an active console checks external source changes every 500 ms and closes its session when its reviewed context becomes stale.

Final results are selected from persisted evidence with their source and observed/interpretation basis. Text and diffs are selectable plain content, not executable markup. Saved-run browsing filters workspace, project, environment and agent before pagination; it uses current policy without a provider, repository grant, execution lease or run recovery. It creates no database for an empty archive. Approval-required/denied reads fail closed, and failed refreshes clear displayed evidence.

The sheet keeps Done outside its scroll area. Native UI checks cover explicit approval, redacted output, saved-result reopening after relaunch, rejection, cancellation, closing an active run, and compact-window fit. The console prefers 640 logical points in height; the compact parent is 910×720. Larger-window diff acceptance uses 1400×900. These checks do not establish the physical-display matrix. Final acceptance passed 333 Mac unit/integration tests, ten native UI tests and 226 primary iPhone regressions; see [the validation record](../Development/p1-13c2-validation.md).

UI tests use a Debug-only provider in a UUID-scoped synthetic application-support container. Normal launches use the signed native Codex helper; Release excludes this fixture. The iPhone companion's pairing and remote run UI remain later-phase work.

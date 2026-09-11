# Native navigation, onboarding and interaction

Status: initial shell implemented and native UI-tested; full interfaces remain planned. Source: [final architecture](final-architecture.txt), sections 76–82, 104 and 152.
<!-- Source sections: 76,77,78,79,80,81,82,104,152 -->

The Mac navigation covers Overview, Workspaces, Projects, Agents, Runs, Workflows, Skills, Connections (plugins/MCP/databases/repositories), Project Memory (requirements/validation/bugs/tests/documentation), Approvals, Artifacts, Traces and Settings. Add destinations as real functionality exists; blank panels must not imply implemented features.

## Main surfaces

Overview shows active/failed runs, pending approvals, recent activity, workspace and connection status, Codex readiness, remote devices and usage. Agent editing covers general settings, instructions, execution, tools, skills, knowledge, integrations, permissions, outputs, tests and versions.

The context inspector answers what an agent will know: scope, instructions, skills, requirement versions, selected knowledge/environment, integration/repository access and prior-run context. Cross-workspace data should be absent by enforced scope. Show validation errors and unavailable sources before launch.

The Mac’s **Get Started** screen checks readable local catalog storage, project presence, a bounded Git version response and Codex/helper authentication status. Recovery actions open the existing workspace/project forms, agent management, project setup and Codex Settings. Checks are cancellable, clear stale observations and never grant execution authority. See [P1-14c validation](../Development/p1-14c-validation.md). Optional remote pairing follows explicit enablement. Setup must remain recoverable if a dependency is missing or the user cancels an optional connection.

## Commands and persistent controls

The target Command-K palette covers run/start, context switching, knowledge search, creation, connections, approvals and settings. The implemented Phase 1 palette opens Settings, workspace/project creation, workspace switching, agent/skill management, project setup and the existing run review console. Search includes workspace/project context and routes use stable identities revalidated against the current catalog; opening a command never starts or approves a run. Later capability phases add their corresponding commands. See [P1-14a validation](../Development/p1-14a-validation.md). Commands must share service and policy entry points with their visible UI actions. Preserve keyboard focus and predictable escape/return behavior.

The Phase 1 MenuBarExtra shows running, awaiting-approval and failed counts for open sessions, plus Open AgentDesk and scoped actions that focus an existing console. The Runs page also opens project consoles and saved history. Counts use persisted run sequences from the current owner, and closing a session removes it. Historical totals and pause controls remain future capabilities. See [P1-14b validation](../Development/p1-14b-validation.md). Native notifications cover approvals, completion/failure, important results, connection loss and device events. Make notifications optional and avoid sensitive content in previews.

Stable `agentdesk://` links address authorized workspace/project resources such as runs, bugs and requirements. Validate link structure and scope on open; a deep link must not grant access or execute a side effect merely by being opened.

## Accessibility and verification

Use native labels, focus order, keyboard shortcuts, scalable layout and clear status text beyond color alone. Test empty/loading/error/offline states, long names, large text, light/dark appearance, split-view resizing, command routing, invalid/deleted deep-link targets and context switching during active work. UI success must reflect persisted/authoritative state, not optimistic placeholder data.

### Mac window and display adaptation

The user's additional display requirement (2026-09-10) covers 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K screens. Layout follows the available logical window size and macOS scaling. It must not branch on physical diagonal or assume that a 4K screen provides 3840×2160 logical points. The [native display matrix](../Development/testing.md#mac-display-and-window-matrix) defines window, scaling and hardware acceptance, including both common interpretations of the requested 2K target until the exact panel is known.

Scrollable setup forms and JSON editors use a shared native resizable layout with a compact usable content minimum and a suggested opening size. Their content can grow as windows expand. Verify primary actions, focus and text at compact sizes, and use extra space for desktop lists, inspectors, results and diffs as those surfaces arrive. The P1-14c pass replaces fixed outer sizes in the older agent, skill, shared-instruction and Codex Settings editors with the shared resizable layout. Compact project rows put their full action labels below the title; larger rows use horizontal space. P1-15 and final physical display acceptance remain pending. Offscreen layout measurements alone do not prove interactive or physical display acceptance.

## Initial shell

P1-01 introduces a native Mac split-view sidebar with empty Workspaces, Runs and Connections destinations and an unpaired iPhone screen. These surfaces do not yet create resources, execute agents or pair devices. Selection is a small Core value type; views own only presentation state. Native XCTest covers selection, launch, Mac sidebar navigation, appearance, iPhone rotation and largest accessibility text. Mac and primary iPhone runs pass. See [foundation validation](../Development/p1-01-validation.md).


## Project setup screens (P1-13c1)

The app provides **Workspaces → project → Setup** with native folder selection, registration/access status and versioned workspace/project execution forms. The UI uses the scoped registration and setup services described in [repositories](repositories.md) and [configuration](configuration.md). Repository access is checked on reload; registration removal preserves the actual folder. Forms preserve advanced saved constraints and make starting settings explicit review/save actions. Advanced JSON exposes the complete configuration, validates scope/limits before applying to the form and still requires an explicit Save Settings action.

Native acceptance passes: 310 Mac unit/integration tests, four Mac UI scenarios and 224 iPhone tests. External folder access survives relaunch; configuration save/cancel, advanced schema edits and compact-window keyboard actions are verified. The JSON field uses a native plain-text editor with automatic substitutions disabled so macOS smart quotes cannot corrupt the document. Physical display matrix coverage remains pending. The context inspector/live run console is described below. See [validation](../Development/p1-13c1-validation.md).


## Project run console (P1-13c2)

**Workspaces → project → Run** opens the native console. Choose an agent and environment, review the current composed instructions/source versions/effective configuration, enter a task and prepare it. Preparation freezes sanitized input and a fingerprint-bound action. The user explicitly approves and starts, or rejects, the prepared action. A stale context must be reviewed again. Opening the console never starts Codex.

The Mac displays persisted run state and step progress through an authorized sequence-based stream. Open-ended runs show no overall percentage. Cancellation and confirmed close await execution cleanup; closing releases project ownership. In-app execution-setting saves stop affected sessions before writing, while an active console checks external source changes every 500 ms and closes its session when its reviewed context becomes stale.

The live output preview reads only persisted, redacted provider-response evidence through the same authorized reader used for saved evidence. Local refreshes read up to 50 records every 250 ms, advance an evidence sequence cursor and verify workspace/project/environment/run/agent identity. The preview retains at most 100 entries and 256 KiB, with up to 16,384 characters per entry, and explicitly labels abbreviated text and provider interpretation. Full evidence stays available separately. Cancellation or context replacement prevents late reads from restoring previous output. This local display mechanism does not implement the planned mobile socket protocol. See [Phase 1 acceptance](../Development/p1-15-acceptance.md).

Final results are selected from persisted evidence with their source and observed/interpretation basis. Text and diffs are selectable plain content, not executable markup. Saved-run browsing filters workspace, project, environment and agent before pagination; it uses current policy without a provider, repository grant, execution lease or run recovery. It creates no database for an empty archive. Approval-required/denied reads fail closed, and failed refreshes clear displayed evidence.

The sheet keeps Done outside its scroll area. Native UI checks cover explicit approval, redacted output, saved-result reopening after relaunch, rejection, cancellation, closing an active run, and compact-window fit. The console prefers 640 logical points in height; the compact parent is 910×720. Larger-window diff acceptance uses 1400×900. These checks do not establish the physical-display matrix. Final acceptance passed 333 Mac unit/integration tests, ten native UI tests and 226 primary iPhone regressions; see [the validation record](../Development/p1-13c2-validation.md).

UI tests use a Debug-only provider in a UUID-scoped synthetic application-support container. Normal launches use the signed native Codex helper; Release excludes this fixture. The iPhone companion's pairing and remote run UI remain later-phase work.

## Implemented requirement workspace

Projects expose Requirements directly and through the scoped Manage Requirements command. Native list selection opens immutable history; the detail view distinguishes active and latest published versions. Editing uses a separate review step with exact field changes and fixed publication/cancel actions. Forms scroll within compact sheets and expand in larger windows; project actions wrap across rows. See [requirement behavior](requirements.md) and [native validation](../Development/p2-02-validation.md).

The Requirements browser pins its header to the standard top inset in all content states. Empty/unavailable/selection guidance fills the body below the controls, avoiding vertical centering of the entire modal. See [modal spacing regression](../Development/p2-03a-validation.md).

## Mutation history (P3-04 component)

The native implementation adds **Run console → choose agent/environment → Mutation History**. The selected agent resolves current configuration; history itself is scoped to the project and environment and may include attempts by other agents there. This is local-user operational browsing, not mobile or agent access. Read policy is checked against fresh configuration before and after each page, and an unavailable configuration or denied read clears the model's displayed history on refresh.

Rows identify the action, approval and optional run, with start/update times. Acknowledged means Jira returned the expected success response; it does not guarantee that remote state remains unchanged. Rejected means an explicit rejection was observed. Unresolved means the app cannot prove the result, including interruption before dispatch confirmation or after sending. The screen does not authorize retry. Verify current Jira evidence and obtain a new exact review for any subsequent write.

Pages contain at most 50 rows and use stable action-ID ordering, not chronological ordering. Refresh includes new attempts whose IDs sort before the current cursor. Done remains outside the scroll area. Model tests cover failure/retry and late-result cancellation. Native Mac tests verify opening and closing empty history and displaying synthetic acknowledged/unresolved outcomes; both screenshots were inspected on 2026-09-12. See [current validation](../Development/p3-04-validation.md).

## Native Jira configuration management

The Mac Connections destination now selects an existing workspace and project, lists saved Jira configurations across that project’s environments, and supports creating/editing local configuration versions. The editor requires an existing project environment and an HTTPS site origin without embedded credentials, paths, queries or fragments. Existing connections keep their environment identity. A credential-bearing configuration cannot silently switch its site in this editor.

Refresh and bounded load-more read persisted current versions; stale saves fail rather than replacing a newer version. Disabled and enabled-but-unchecked states are displayed separately from authenticated or healthy status. Saving does not contact Jira. The native Sign In control uses a publisher-owned bundle registration and is unavailable when that registration is missing or invalid. Connection testing, remaining grant lifecycle controls, permission review and image upload review remain unfinished. See [P3-05 validation](../Development/p3-05-validation.md).


### Native Jira sign-in

`AgentDeskJiraOAuthRegistration` in the app bundle is a dictionary containing exactly `brokerOrigin`, `clientID` and `callback` strings. These are public registration values, not a client secret. The existing HTTPS/same-origin registration validator applies. Workspace files and environment variables cannot override the broker. The native flow requests read-only OAuth access; this does not grant runtime permissions. No production registration is bundled yet.

Sign In requires an enabled configuration in a current project environment. A missing credential reference is reserved in a new immutable configuration version before opening the browser. The reference is scoped to workspace/project/environment and contains no token. Native windows serialize login ownership by connection ID. Fresh configuration and environment checks run before OAuth and before/after saving a grant; a rejected save is cleaned up. These checks are not an atomic transaction with independent configuration editors or other processes.

Cancel Sign-In and leaving the project cancel the active task. Transport cleanup releases native ownership, and an independent refresh keeps the reserved configuration visible even after cancellation. Cancellation may leave an empty credential reference, which a later sign-in can reuse. Account tokens use the scoped Keychain store. Displayed errors are fixed local messages rather than raw broker responses. A successful sign-in message is an observation from that operation, not a continuously monitored health status. Live registration/deployment and complete native lifecycle acceptance remain pending.


### Local Jira logout

A credential-bearing connection exposes Log Out. It removes the exact scoped Keychain reference, retains immutable configuration history and the reference for later sign-in, and does not contact the broker or change browser sessions/Atlassian consent. An enabled connection and a currently listed environment are not prerequisites for removing a grant. The latest persisted configuration must match the selected row before deletion.

Logout shares native ownership with sign-in; an active login in another window causes a retryable local error rather than racing its credential save. In the same window, cancel sign-in before logging out. Fixed local errors distinguish a failed cleanup from successful grant removal. Existing runtime checks reject subsequent use of a missing grant; logout does not retract requests already dispatched to Jira. The ownership gate covers this app process, not external editors or other processes.

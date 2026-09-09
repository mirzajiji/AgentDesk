# Manual scenarios and Postman collections

Status: planned design. Source: [final architecture](final-architecture.txt), section 115.
<!-- Source sections: 115 -->

Projects can import Postman collection/environment JSON and run predefined API work directly. The user should not need the Postman desktop app after import, and Codex should not reconstruct a known request simply to execute it.

## Import and selection

Present collections, folders, requests, variables, environments, auth configuration and supported pre-request/test scripts in native UI. Allow selection of one request, multiple requests, a folder or full collection; inspect before execution. A `CollectionRunner`/`ScenarioRunner` abstraction hides the actual supported local runner, which may be a compatible runner such as Newman or a controlled native implementation.

Supported script/collection behavior must be explicit and tested. Unsupported features must block or explain limitations; do not silently skip assertions and report a pass. Runner selection is an implementation decision to verify against current supported behavior.

Imported variables may contain secrets. Detect candidates, let the user classify them, move sensitive values into scoped Keychain storage and persist secret references. Sanitized export never includes raw secrets. Reimport shows differences, preserves relevant version history and retains AgentDesk requirement/test/bug relationships where identities can be matched; unresolved mapping must be reviewed.

## Fast execution

Resolve the saved asset, selected environment and authorized secret references; run deterministic requests and assertions; stream progress; persist sanitized responses/results and evidence. Stop/cancellation must be supported. Prompt-driven execution first searches registered testing assets and uses Codex only when interpretation is ambiguous or analysis is needed.

Future AgentDesk-native scenarios combine API calls, database validation, Playwright, shell, MCP/plugin tools and assertions. Each step still passes through scope and policy. A predefined scenario is not blanket authorization for every embedded script or external write.

## Result contract

`ScenarioRun` records project, collection/version, selected folder/request/scenario, environment, times, status, requests/responses/assertions/errors, artifact references, parent run, bug relationships and exact requirement versions. Statuses include passed, failed, partiallyPassed, blocked, cancelled and error.

Default runs use the latest active collection and requirement versions; explicit historical reproduction uses pinned versions. A newer requirement marks linked scenarios potentially stale. On failure, the user can choose Investigate, which invokes failure analysis and the normal current-requirement/duplicate gate. Do not create a bug for every failure automatically.

Test imports, secrets, supported/unsupported scripts, variable precedence, deterministic resolution, cancelled/partial runs, assertion errors, reimport identity conflicts, relationship preservation, historical selection and sanitized exports. Verify runner fallback does not widen permissions.

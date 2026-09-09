# Policy, approvals and production safety

Status: P1-10 implements typed policy configuration, deterministic evaluation, an internal dispatch gate and durable approval/audit storage. Native review UI, authenticated LAN principals and individual integration adapters remain planned. Source: [final architecture](final-architecture.txt), sections 72–73, 129–130 and 141.
<!-- Source sections: 72,73,129,130,141 -->

All meaningful actions pass through an application-owned Policy Engine. Decisions are allow, approval or deny. Inputs include workspace/project, agent, capability/provider, action, environment, resource and client device. Missing identity or unresolved policy must not imply allow.

## Enforcement sequence

Validate caller and scope, resolve effective permissions, classify the concrete action, evaluate environment/device restrictions, then execute or request approval. Recheck relevant authority at dispatch: an approval must not override a later device revocation or removed workspace access.

The same boundary applies to UI controls, model-generated actions, workflow nodes, plugin internals, MCP calls, database console, mobile commands and future CLI/CI access. Transport choice does not change authorization.

## Approval records

Approval categories include Jira creation/modification/comments, Git commit/push/merge request/merge, database writes/destructive SQL, Kubernetes actions, external messages and sensitive filesystem operations. Statuses include pending, approved, rejected, modified and expired.

Record contract: requester/run, workspace/project/environment, exact action/resource, reviewed payload or digest, relevant file diff/version, creation/expiry time, approving principal/device, decision and execution result. A changed payload invalidates the old authorization; “modify and approve” produces a newly reviewed payload. Prevent replay or duplicate execution of a completed approval.

Show the actual effect and scope before approve/reject. High-risk mobile approval uses device authentication where appropriate, but server-side policy and binding remain mandatory. Approval delays and outcomes are operational data and significant audit events.

## Presets and production

Read Only allows declared reads and denies writes. QA Safe allows reads, requires approval for ordinary external writes and denies destructive actions. Development/Custom can be configured explicitly. Presets are editable starting points, not a reason to skip capability classification.

Production defaults deny database writes, Kubernetes exec and deployment; sensitive reads can require approval. Optional elevated production read sessions must be explicit, scoped, audited and expiring. The agent cannot elevate itself.

Dry Run prepares the proposed effect without executing it. It still resolves scope, validates inputs and evaluates what approval would be necessary. Display dry-run output distinctly from a successful remote action; never replay a dry-run plan later without checking current state and authority.

Test allow/approval/deny, policy precedence, revoked devices, expired/rejected/modified approvals, changed payloads, duplicate submission, production defaults, dry-run no-side-effects and parity across UI/provider/CLI routes. The application's runtime approval policy is separate from the user's already supplied authorization to develop and commit this repository.


## Implemented policy boundary

Core defines validated `PolicyAction`, `ActionFingerprint`, `PolicyDocument`, `PolicySnapshot` and approval records. Security owns `PolicyEngine`, authority descriptors and presets. Runtime owns the internal `PolicyGate`; Persistence owns the scoped `ApprovalStore`. Runtime now depends on Security as well as Core/Persistence. These are authorization primitives for the coordinator and integration adapters; existing app forms are not claimed to have been routed through this new gate yet.

Every action carries a fresh action UUID, exact workspace/project/environment, applicable run/agent identities, an application-selected operation classification and fingerprints of its resolved resource and prepared nonsecret payload. Canonical JSON hashing includes all action fields. Changing identity, resource, payload or operation invalidates the previous approval. These hashes are bindings, not bearer credentials or evidence of user identity. Adapters must resolve paths/resources, validate run membership and freeze the exact effect before constructing the action. Secret values must stay opaque; use scoped references in prepared metadata, not plaintext secrets or secret hashes.

`PolicyDocument` is versioned human-readable JSON with an explicit level, scope, revision and a list of unique operation rules. Unknown versions, duplicate rules and invalid scope combinations fail. Omitted operations deny. A snapshot requires workspace, project and environment policies for the same context. Evaluation takes the strictest disposition across the three levels; a child cannot widen a parent's restriction. Presets are explicit initial rule lists: Read Only, QA Safe and Development. Sensitive/secret operations remain denied or reviewed rather than becoming ordinary reads. Policy editing and filesystem loading belong to effective configuration/native Settings integration.

`PolicyAuthority` is not Codable. The trusted host must construct it from authenticated local/agent/device state, with a principal UUID, revision, project/environment grants, permitted operations, review permission, expiry and revocation. A model or device payload cannot supply this object. The gate refuses changed authority values under the same revision. Missing, expired, revoked, foreign or ungranted authority denies. Agent principals must match the action's agent and cannot expose secrets, edit configuration, run arbitrary shell or approve actions. Mobile execution currently permits only declared evidence reads; privileged operations and arbitrary provider tasks fail even under permissive rules. Mobile reviewers cannot approve secret, configuration, shell or destructive operations. Predefined mobile start/cancel routes and real pairing/authentication are still Phase 5 work.

A locked workspace permits evidence reads only. Production blocks mutations and requires review for sensitive reads. Destructive actions and arbitrary shell require review even under an otherwise permissive development policy. The engine classifies concrete adapter operations deterministically; it does not infer permission from a prompt or trust an asserted client risk level. Operation categories do not implement an external integration or expose a shell endpoint.

## Durable review and dispatch

`ApprovalStore` binds to one project and environment. Schema 4 stores immutable action metadata/digests, requester, policy/authority binding, pending/approved/rejected/modified/expired/consumed status, sequence, creation/expiry/update times and reviewer identity/revision. State and audit event commit in the same SQLite transaction. Repeating preparation for the same action returns the original record and expiry; a new payload needs a new action UUID. Exact action, requester, binding and expected sequence are checked at review/consumption. Bounds include at most 24 hours of approval life, 8 KiB action JSON, 1,000 rows per list/replay and the existing bounded SQLite lock wait.

The gate creates pending records only when policy requires review. Approval cannot turn a denied operation into an allowed one. A human reviewer can reject a pending action after its requester's authority is removed. Modify and approve marks the original record modified and creates a separately reviewed replacement in one transaction; the original action stays immutable. The replacement must independently pass current policy and review permissions.

Immediately before dispatch, the gate reevaluates current policy and requester authority, checks the exact prepared action and recorded reviewer revision, then atomically consumes the approved record. It checks policy/authority again after the storage suspension and before invoking the effect. Revocation, changed revisions, payload changes, expiry and cancellation prevent dispatch. Concurrent gates/connections can consume a grant only once. A failed or cancelled effect does not restore the grant. A crash after consumption can leave an unused grant spent; recovery must request fresh review rather than silently repeat a possibly completed external write. Consumed means reserved for one dispatch attempt, not proven successful execution; the run coordinator records the outcome separately.

Dry run returns the policy evaluation without invoking an effect or writing an approval. All stored approval content is metadata and nonsecret fingerprints. The exact human-readable prepared effect will be shown through the redacted artifact/review UI; a hash alone is not an adequate user approval screen. The gate remains internal and has no UI/XPC/LAN action endpoint. See [policy validation](../Development/p1-10-validation.md).

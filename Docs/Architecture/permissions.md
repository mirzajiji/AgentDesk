# Policy, approvals and production safety

Status: planned design. Source: [final architecture](final-architecture.txt), sections 72–73, 129–130 and 141.
<!-- Source sections: 72,73,129,130,141 -->

All meaningful actions pass through an application-owned Policy Engine. Decisions are allow, approval or deny. Inputs include workspace/project, agent, capability/provider, action, environment, resource and client device. Missing identity or unresolved policy must not imply allow.

## Enforcement sequence

Validate caller and scope, resolve effective permissions, classify the concrete action, evaluate environment/device restrictions, then execute or request approval. Recheck relevant authority at dispatch: an approval must not override a later device revocation or removed workspace access.

The same boundary applies to UI controls, model-generated actions, workflow nodes, plugin internals, MCP calls, database console, mobile commands and future CLI/CI access. Transport choice does not change authorization.

## Approval records

Approval categories include Jira creation/modification/comments, Git commit/push/merge request/merge, database writes/destructive SQL, Kubernetes actions, external messages and sensitive filesystem operations. Statuses include pending, approved, rejected, modified and expired.

Proposed record contract: requester/run, workspace/project/environment, exact action/resource, reviewed payload or digest, relevant file diff/version, creation/expiry time, approving principal/device, decision and execution result. A changed payload invalidates the old authorization; “modify and approve” produces a newly reviewed payload. Prevent replay or duplicate execution of a completed approval.

Show the actual effect and scope before approve/reject. High-risk mobile approval uses device authentication where appropriate, but server-side policy and binding remain mandatory. Approval delays and outcomes are operational data and significant audit events.

## Presets and production

Read Only allows declared reads and denies writes. QA Safe allows reads, requires approval for ordinary external writes and denies destructive actions. Development/Custom can be configured explicitly. Presets are editable starting points, not a reason to skip capability classification.

Production defaults deny database writes, Kubernetes exec and deployment; sensitive reads can require approval. Optional elevated production read sessions must be explicit, scoped, audited and expiring. The agent cannot elevate itself.

Dry Run prepares the proposed effect without executing it. It still resolves scope, validates inputs and evaluates what approval would be necessary. Display dry-run output distinctly from a successful remote action; never replay a dry-run plan later without checking current state and authority.

Test allow/approval/deny, policy precedence, revoked devices, expired/rejected/modified approvals, changed payloads, duplicate submission, production defaults, dry-run no-side-effects and parity across UI/provider/CLI routes. The application's runtime approval policy is separate from the user's already supplied authorization to develop and commit this repository.

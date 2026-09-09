# Security boundaries, secrets, classification and audit

Status: scoped secret references and Keychain adapter code implemented (P1-05); native Mac and iPhone Keychain acceptance passes with the signed app identity. Central stream redaction, runtime policy, classification and audit remain planned. Source: [final architecture](final-architecture.txt), sections 96, 101 and 138–140.
<!-- Source sections: 96,101,138,139,140 -->

The highest-priority boundary is company isolation. The model, imported documents, tool output, local processes, remote clients and extension content are not security authorities. The Mac validates scope and permission for every sensitive operation and response.

## Secrets

`AgentDeskSecurity` provides a `SecretStore` abstraction with set/get/delete/exists and an actor-isolated native Keychain adapter. `SecretScope` binds workspace and optional project/environment; an environment requires a project. Each store checks exact scope before touching Keychain, and each reference adds a UUID identity. Missing items return nil/false, deletion is idempotent, and denied/locked/failed access remains an explicit OSStatus error. Ordinary unit tests use injected fakes; native integration tests use only random-scope synthetic entries and delete them afterward.

Never put secret values into configuration JSON/YAML, logs, traces, artifacts, mobile responses, analytics or routine backups. Pass values only to the authorized execution destination and minimize exposure lifetime. Imported environments and integration configuration require secret-field review.

## Classification and redaction

Data classifications are PUBLIC, INTERNAL, CONFIDENTIAL and SECRET. Typical requirements/API evidence may be internal, DB rows confidential, and passwords/tokens secret. These are configurable defaults, not proof that all records of a type have the same sensitivity.

Classifications affect context eligibility, display, artifact retention, export and mobile projections. Treat derived content as sensitive when it contains protected source data. An agent summary does not automatically declassify its inputs.

Central redaction covers passwords, tokens, authorization headers, cookies, private keys, database URLs and configured sensitive fields. Apply it before logs, trace writes, previews, mobile streaming and analytics. Test structured fields and unstructured text, split stream chunks, escaped/encoded representations, false positives and unknown secrets. Pattern redaction is defense in depth; prevent unnecessary collection at the source.

## Remote and extension controls

Use authenticated paired-device credentials, suitable encrypted transport, revocation, workspace authorization, audit and resource/rate limits. Bonjour advertises minimal non-sensitive metadata. Do not accept LAN membership, an IP address or a device display name as identity. Exposing a local server, plugin or MCP capability must not create unrestricted shell or filesystem access.

## Audit

Keep a local append-oriented audit trail for important actions: approved/denied external writes, policy changes, pairing/revocation, production access, requirement publication and ticket registration. Record principal/agent/device, workspace/project, action, timestamp, result and related run. Audit is separate from verbose technical logs and must also be sanitized.

“Immutable-style” does not mean tamper-proof against a privileged local attacker. Any stronger integrity guarantee requires a defined threat model, key protection and verification mechanism; do not claim it simply because the UI offers no edit button.

Verify secret non-disclosure at each serialization boundary, classification propagation, scoped Keychain operations, policy invariants, replay/revocation, sanitized errors and audit completeness. Security tests are required before exposing remote or integration execution.

## Implemented Keychain behavior

The adapter uses generic-password items in the data-protection Keychain, with synchronization disabled and `WhenUnlockedThisDeviceOnly` accessibility. It never falls back to plaintext files or memory when Keychain fails. Apple recommends the [data-protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain) for modern cross-platform behavior. Security calls execute within the store actor, away from UI state; [SecItemAdd is a blocking API](https://developer.apple.com/documentation/security/secitemadd%28_%3A_%3A%29). An authentication context disables interactive prompts; unavailable access fails visibly for the consuming service.

Setting updates an existing identity or adds a missing one, handling a concurrent add with one bounded update retry. Existence checks never request secret bytes. The service namespace is fixed to AgentDesk; accounts derive only from scoped identities. There are no account enumeration or bulk-delete operations. Cancellation is checked before each operation; an in-flight synchronous Security call cannot be interrupted safely.

`SecretReference` is Codable and contains no value. `SecretValue` is not Codable, accepts bounded nonempty bytes, and redacts ordinary descriptions, debug descriptions and Mirror-based dumps. Authorized adapters must explicitly access bytes with `withBytes`. This wrapper does not guarantee memory zeroization or prevent deliberate misuse by code holding the value. It supplements the future centralized redaction pipeline and operation policy; it does not grant permission to an agent, plugin or phone.

The package builds on Mac and iPhone so future paired-device credentials can use native protection. Its presence in the iPhone binary does not expose Mac secrets or add any remote operation. No provider credentials are copied: Codex continues to own its supported CLI authentication.

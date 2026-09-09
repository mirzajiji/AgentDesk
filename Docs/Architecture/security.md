# Security boundaries, secrets, classification and audit

Status: planned design. Source: [final architecture](final-architecture.txt), sections 96, 101 and 138–140.
<!-- Source sections: 96,101,138,139,140 -->

The highest-priority boundary is company isolation. The model, imported documents, tool output, local processes, remote clients and extension content are not security authorities. The Mac validates scope and permission for every sensitive operation and response.

## Secrets

Provide a `SecretStore` abstraction with set/get/delete/exists and a Mac Keychain adapter. References are scoped by workspace/project/connection as appropriate. Handle missing items, denied Keychain access and authentication failures explicitly. Ordinary unit tests use a fake store; live Keychain integration tests must not alter unrelated user credentials.

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

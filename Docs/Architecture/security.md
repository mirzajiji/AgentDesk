# Security boundaries, secrets, classification and audit

Status: scoped Keychain storage (P1-05), deterministic policy and durable approval/audit storage (P1-10), scoped redaction (P1-12a), and sanitized trace/artifact storage (P1-12b) are implemented. Provider coordination, native approval review and remote projections remain subsequent work. Source: [final architecture](final-architecture.txt), sections 96, 101 and 138–140.
<!-- Source sections: 96,101,138,139,140 -->

The highest-priority boundary is company isolation. The model, imported documents, tool output, local processes, remote clients and extension content are not security authorities. The Mac validates scope and permission for every sensitive operation and response.

## Secrets

`AgentDeskSecurity` provides a `SecretStore` abstraction with set/get/delete/exists and an actor-isolated native Keychain adapter. `SecretScope` binds workspace and optional project/environment; an environment requires a project. Each store checks exact scope before touching Keychain, and each reference adds a UUID identity. Missing items return nil/false, deletion is idempotent, and denied/locked/failed access remains an explicit OSStatus error. Ordinary unit tests use injected fakes; native integration tests use only random-scope synthetic entries and delete them afterward.

Never put secret values into configuration JSON/YAML, logs, traces, artifacts, mobile responses, analytics or routine backups. Pass values only to the authorized execution destination and minimize exposure lifetime. Imported environments and integration configuration require secret-field review.

## Classification and redaction

Data classifications are PUBLIC, INTERNAL, CONFIDENTIAL and SECRET. Typical requirements/API evidence may be internal, DB rows confidential, and passwords/tokens secret. These are configurable defaults, not proof that all records of a type have the same sensitivity.

Classifications affect context eligibility, display, artifact retention, export and mobile projections. Treat derived content as sensitive when it contains protected source data. An agent summary does not automatically declassify its inputs.

Central redaction covers passwords, tokens, authorization headers, cookies, private keys, database URLs and configured sensitive fields. Apply it before logs, trace writes, previews, mobile streaming and analytics. Test structured fields and unstructured text, split stream chunks, escaped/encoded representations, false positives and unknown secrets. Pattern redaction is defense in depth; prevent unnecessary collection at the source.

### Implemented redaction contract

`ContentRedactor` binds a project, environment and run. `load` accepts deliberately supplied `SecretReference` values and an authorized resolver; it checks every reference before resolving any bytes. Workspace-wide and project-wide references may be inherited only within their owner. Foreign references, unavailable secrets, failed resolution and cancellation fail closed. Loading is not a permission grant or Keychain enumeration. No provider credential is extracted, and ordinary tests use synthetic values.

Only this boundary constructs `RedactedText`. It is Encodable but cannot be decoded from arbitrary JSON to assert that content was sanitized. It carries the exact context, classification, mask count and redaction policy version. A changed record becomes CONFIDENTIAL; untouched content retains its caller-supplied classification. Whole records classified SECRET are refused. The wrapper does not authorize display, export, retrieval or transfer to another principal; consumers must check their own policy and exact scope.

Text matching masks configured secret bytes in UTF-8, standard/URL-safe Base64, lower/upper hex, common JSON escapes and Unicode escapes. One layer of percent encoding is decoded solely for matching, with original source ranges retained: mixed hex case, optional encoding of unreserved characters and form `+` spaces are recognized. Overlapping occurrences merge before replacement. Password/token assignments, authorization/cookie headers, credential-bearing connection URLs, private-key blocks and recognizable token formats provide additional pattern coverage. Configured field names are literal validated names, never caller-supplied regular expressions.

JSON uses a bounded lexical scanner. It masks a sensitive field's entire value, including arrays/objects; known sensitive values mask their entire scalar. Field names and string escapes are decoded for matching, while all other bytes, whitespace and number spelling/precision remain untouched. Secret-bearing object keys are rejected instead of renamed. Duplicate keys (including escaped equivalents), malformed syntax, invalid string escapes, excessive depth and excessive token counts fail without partial output. Masking a numeric/object value changes its JSON type to the redaction marker string; validate raw provider output against its output schema before redaction, then store the sanitized representation as evidence.

`RedactionBuffer` holds one logical UTF-8 text/JSON message and emits nothing from `append`. `finish` is the only publication point, after the complete record is sanitized. This prevents a secret spanning chunks from leaking through a previously emitted prefix. Cancellation, invalid UTF-8 and overflow close/discard the record; subsequent appends/finishes fail. Live progress can continue using separately validated metadata events while text remains incomplete. Independent records must have real logical boundaries, not arbitrary transport chunk boundaries.

Limits: 256 KiB input and 1 MiB sanitized output per record; 64 unique references and 64 KiB combined raw secret bytes; at most 1,024 generated variants totaling 4 MiB; 64 extra field names of at most 64 UTF-8 bytes; JSON depth 40, 8,192 values and 256 bytes per numeric token. Match collection is bounded. Policy/buffer descriptions and reflection hide private contents; errors contain fixed cases, not source text. Ordinary memory lifetime management does not guarantee zeroization.

This is deterministic defense in depth, not discovery of every possible secret. Unknown unlabelled values, custom encodings, encrypted/compressed content and arbitrary binary artifacts require source minimization, an appropriate parser or denial before collection/publication. The [evidence store](persistence.md) now requires this wrapper for writes. The provider still returns untrusted observations in memory; the coordinator must route them through this API before storage or UI. See [redaction validation](../Development/p1-12a-validation.md).

## Remote and extension controls

Use authenticated paired-device credentials, suitable encrypted transport, revocation, workspace authorization, audit and resource/rate limits. Bonjour advertises minimal non-sensitive metadata. Do not accept LAN membership, an IP address or a device display name as identity. Exposing a local server, plugin or MCP capability must not create unrestricted shell or filesystem access.

## Audit

Keep a local append-oriented audit trail for important actions: approved/denied external writes, policy changes, pairing/revocation, production access, requirement publication and ticket registration. Record principal/agent/device, workspace/project, action, timestamp, result and related run. Audit is separate from verbose technical logs and must also be sanitized.

“Immutable-style” does not mean tamper-proof against a privileged local attacker. Any stronger integrity guarantee requires a defined threat model, key protection and verification mechanism; do not claim it simply because the UI offers no edit button.

Verify secret non-disclosure at each serialization boundary, classification propagation, scoped Keychain operations, policy invariants, replay/revocation, sanitized errors and audit completeness. Security tests are required before exposing remote or integration execution.

## Implemented Keychain behavior

The adapter uses generic-password items in the data-protection Keychain, with synchronization disabled and `WhenUnlockedThisDeviceOnly` accessibility. It never falls back to plaintext files or memory when Keychain fails. Apple recommends the [data-protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain) for modern cross-platform behavior. Security calls execute within the store actor, away from UI state; [SecItemAdd is a blocking API](https://developer.apple.com/documentation/security/secitemadd%28_%3A_%3A%29). An authentication context disables interactive prompts; unavailable access fails visibly for the consuming service.

Setting updates an existing identity or adds a missing one, handling a concurrent add with one bounded update retry. Existence checks never request secret bytes. The service namespace is fixed to AgentDesk; accounts derive only from scoped identities. There are no account enumeration or bulk-delete operations. Cancellation is checked before each operation; an in-flight synchronous Security call cannot be interrupted safely.

`SecretReference` is Codable and contains no value. `SecretValue` is not Codable, accepts bounded nonempty bytes, and redacts ordinary descriptions, debug descriptions and Mirror-based dumps. Authorized adapters must explicitly access bytes with `withBytes`. This wrapper does not guarantee memory zeroization or prevent deliberate misuse by code holding the value. It supplements the centralized redaction pipeline and operation policy; it does not grant permission to an agent, plugin or phone.

The package builds on Mac and iPhone so future paired-device credentials can use native protection. Its presence in the iPhone binary does not expose Mac secrets or add any remote operation. No provider credentials are copied: Codex continues to own its supported CLI authentication.

# Bug registry, duplicate detection and CityPay formatting

Status: persistent registry, reviewed manual ticket associations, duplicate comparison, evidence drafts and CityPay report services implemented. Native bug management is implemented and validated in P2-10b. Source: [final architecture](final-architecture.txt), sections 51–65.
<!-- Source sections: 51,52,53,54,55,56,57,58,59,60,61,62,63,64,65 -->

Each project maintains a persistent Bug Registry for generated/manual defects, external ticket associations, failures, evidence, regressions and relationships. Every bug has an internal identity even when it also has a Jira key.

## Registration and relationships

Allow a user to mark a manually created ticket as registered by ID, URL or both. Validate and display the link; allow changing or unlinking it without deleting the local defect history. Preserve duplicates/duplicatedBy, blockedBy/blocks, relatedTo, regressionOf, affectsRequirement, introducedByRequirement and coveredBy relationships.

## Mandatory duplicate gate

Before creating an external ticket: gather evidence, identify observed/root behavior, check downstream reachability, load current active requirements, search the scoped registry, and compare candidates. Use deterministic fingerprints first; invoke Codex semantic comparison only when needed.

Compare endpoint, module/component, validation field, states/transitions, expected/actual behavior, HTTP/application errors, persisted database state, requirement, scenario and environment. Similar titles alone are insufficient.

| Classification | Resulting behavior |
| --- | --- |
| New | Prepare a new defect for the normal approval path |
| Duplicate | Show the existing ticket and prepare additional evidence/comment; do not create another |
| Possible duplicate | Explain overlap, differences and uncertainty; store explicit override decisions |
| Related | Link distinct but related behavior without collapsing defects |
| Blocked downstream | State which upstream defect prevented verification; do not claim unreachable behavior was tested |

A failed scenario need not create any ticket automatically. Investigate and review are explicit actions. Approval binds to the actual ticket/comment payload and scope.

## CityPay Jira skill

Use `[Component - Environment] Area - Module | Problem`, with known Backend/Frontend and UZ/GEO/TR prefixes. Do not guess component or environment. Sections, when applicable: Title, Environment, Preconditions, Description, Reproduce Steps, Actual Result, Expected Result, Endpoint, Payload, Response and Additional Information. Do not add an Impact section.

Titles are concise and specific. Descriptions explain the behavior and violation without repeating the steps. Reproduction is chronological and evidence-based. Preserve supplied endpoints, IDs, currencies, filters, statuses and payload values. Expected behavior comes from current requirements; do not invent HTTP status codes or missing actions/evidence.

Group failures sharing the same root behavior, such as invalid PINFL length/characters caused by one missing validation, but keep unrelated defects separate. Distinguish hard-stop validation, manual-review outcomes, optional fields, malformed input and business conflicts; state whether accepted invalid data persisted.

For status propagation, record applicable channel verification/account/master statuses and sibling evidence where relevant. Concurrency evidence should retain request A/B, shared/different fields, both responses/statuses, before/after DB counts, persisted request and any cross-caller identifiers. Frontend tickets can use the simpler environment/description/steps/actual/expected/evidence structure.

## Verification

Test manual registration/relinking, exact duplicate, ambiguous overlap, unrelated defects with similar titles, cross-environment differences, multiple same-root failures, blocked downstream scenarios, override history and evidence attachments. Validate CityPay section/title rules and reject invented evidence in fixture-based output checks.

## Persistent registry service (P2-07)

`WorkspaceCatalog.bugStore(in:)` opens a project-bound administrative store. Every bug has a stable internal UUID, regardless of registration status. `prepare` creates an exact in-memory proposal; `publishReviewed` consumes that store-bound proposal, checks expiry and the unchanged base version, validates its references and writes a new immutable version. Cancel/replay/stale proposals do not create a new committed version. At most 16 pending proposals are retained, each for five minutes.

Storage is `Memory/Bugs/<UUID>/bug.vN.json` plus `current.json`. History retains title, origin, reported/observed/blocked assessment, status, environment, root/expected/actual behavior, reproduction, structured observed attributes, provenance, exact evidence references, requirement references, coverage subjects, relationships and ticket association. Timestamps preserve fractional source instants. Each version links to its predecessor's fingerprint; bounded reads verify the entire committed chain. Symlinks, multiple hard links, mismatched ownership and tampered chains fail closed. Orphan versions remain preserved and unadopted; later publication skips their version numbers.

A reported finding need not invent root/expected/actual behavior. An observed assessment requires explicit observed provenance and those behavior fields. A blocked assessment requires a blocked-by relationship. These are stored declarations, not proof that an operation executed. Runtime consumers must verify and authorize the referenced operational artifacts; manual provenance is never silently upgraded to independently verified evidence. Evidence references retain project/environment/run/agent/artifact identity and sanitized fingerprints. Automated intake must pass the existing redaction and permission boundaries before proposing records.

Manual Jira registration accepts a key, an HTTPS URL, or both. Supported keys use an uppercase project prefix and positive numeric issue suffix. Links reject user/password components, query strings, fragments, executable schemes and malformed encoding. These are inert, user-supplied associations: saving a link neither contacts Jira nor verifies a remote issue. Editing the association or setting it to nil preserves the same bug ID and all earlier link versions. Listing can filter registration, status and exact environment, with UUID keyset pages of at most 100 records. Archived records are excluded by default but remain available when explicitly requested.

Requirement requests distinguish affects/introduced-by relationships. Explicit requests resolve latest-active versions by default; historical versions must be requested deliberately. Review publication re-resolves references and writes the bug version while holding the same catalog root descriptor lock used by requirement publication. An intervening requirement change rejects the review. Ordinary edits with nil requirement requests preserve the original creation references, including their original historical-selection flag; they do not rewrite old expected behavior to a newer requirement. An explicit empty request list removes references in a new version. Duplicate analysis must still load current active requirements separately.

Bug links preserve duplicate-of, blocked-by, related-to and regression-of direction. Their inverse views (duplicated-by/blocks) can be derived from stored source/target identities; native relationship views are implemented in P2-10b. Targets must already exist in the same project. Self-links, duplicate edges and directed cycles are rejected; related-to is allowed to be symmetric. Coverage references are limited to test subjects. Documents are bounded to 256 KiB; each history is bounded to 1,024 versions/16 MiB. Relationship traversal is bounded to 64 visited bugs per directed edge.

See [registry validation](../Development/p2-07-validation.md). P2-08 consumes the registry for duplicate checks; P2-10b implements native bug management. This task creates no external tickets, performs no semantic comparisons and runs no company infrastructure.

## Duplicate comparison and review services (P2-08)

`ProjectBugStore.comparisonSnapshot` reads current bug heads and their current active requirements under one catalog lock. It includes archived records within the exact environment, with a 256-record/16 MiB bound and at most 1,024 distinct requirement resolutions. Exceeding bounds fails explicitly. Its private-data fingerprint detects changed records and requirements; runtime consumers must authorize access before collection and redact before persistence, display or provider input.

`BugComparison` ignores titles and compares normalized root/expected/actual text, exact structured attributes, environment and current requirement references. Text normalization preserves case and internal whitespace. An exact duplicate also needs a meaningful endpoint/module/component/validation-field/scenario anchor or shared requirement. Same-root differences become possible duplicates; shared context without matching behavior is related. Cross-environment comparisons cannot become exact duplicates. Reported, blocked, missing-environment and stale-requirement findings expose explicit readiness outcomes; no matches is not proof that a defect is new or verified.

`NativeRunService.prepareBugReview` authorizes the read before opening the registry and rechecks access after collection. Referenced artifacts/traces must match project, environment, run, agent, artifact identity and the sanitized content fingerprint. Provider responses remain interpretations; manually recorded observations remain user-attested. The sanitized packet includes at most 32 relevant records and 128 references within 32 KiB. Raw registry/requirement history hashes are not copied into it. Oversize or missing evidence fails rather than silently omitting required source content.

`prepareBugAmbiguity` accepts possible-duplicate cases and prepares a normal Codex execution behind the existing policy/approval controls. Exact sanitized comparison bytes enter the frozen task and dispatch fingerprint. Source validation runs before start and immediately before provider dispatch after repository capture. Codex can explain overlap, differences and uncertainty; its output does not grant authority or automatically mutate the registry. The review expires after five minutes and fails on access revocation or changed sources.

`ProjectBugStore.prepareComparisonDecision` creates a separate local administrative proposal for duplicate/related/distinct resolution. It records compared immutable revisions, deterministic suggestion, selected resolution and reason; an override is explicit. `publishReviewed` consumes the exact proposal and validates the complete snapshot under the publication lock. Earlier decisions remain in immutable history. The general draft API cannot replace decision metadata. Duplicate decisions cannot promote reported/blocked/stale incoming findings or treat an unobserved/stale existing record as a verified duplicate. Native decision editing and publication controls are P2-10; read-only Codex authority does not imply registry write access.

`prepareBugTicketEvidence` prepares text for an existing ticket only after exact comparison or a fresh explicit duplicate decision. It copies the selected incoming source, current requirement versions, reproduction and verified evidence provenance; unrelated candidates are excluded. Ticket identity, source versions, scope, read policy and expiry remain bound to the draft. A ticket change invalidates it. This service sends no network request; later external publication requires its own exact payload approval and integration. See [duplicate-review validation](../Development/p2-08-validation.md).

## CityPay template and report preparation (P2-09)

The native blank skill editor offers `citypay-jira-bug`. Selecting it fills an editable draft; the user chooses project/workspace scope and saves through the existing versioned skill store. It includes version-1 instructions and synthetic refund input/output examples, requests only evidence-read access and has no scripts or mutation grant. Existing skill edits are not overwritten by the template. Ordinary agent skill pinning uses the saved revision.

`CityPayBugReport` formats supplied observations with explicit Backend/Frontend and UZ/GEO/TR context. It does not infer region from currency or project naming. The title follows the required component/environment/area/module/problem format. Sections are fixed to the permitted report structure, without an Impact section; optional API/precondition content is omitted when absent. Missing reproduction actions or persistence observations remain explicit. Expected results come from the current active requirement content and versions rather than historical bug prose. Supplied status, concurrency, payload, response, identifiers and artifact references remain source-labeled.

The runtime prepares this report only from an authorized, verified `PreparedBugReview`. It redacts structured content before converting fields into prose, then redacts the final rendered text. This preserves nonsecret payload siblings when a password is masked. Drafts retain source/access/expiry validation and do not send external requests. Unresolved duplicates are rejected; known tickets use the additional-evidence path instead. A current explicit distinct decision can resolve its exact candidate. Consecutive decisions on unchanged evidence can resolve multiple candidates; an ordinary edit ends that chain, and changed candidate revisions invalidate their decisions.

Explicit grouping supports 2–16 observations sharing the same project/environment, root and expected behavior, active requirements and structured anchors. At least one meaningful endpoint/module/component/validation-field anchor is required. The caller supplies a group problem title; each finding's reproduction, actual result and payload/response stay labeled by source ID. Different roots or anchors, repeated sources, stale/unverified observations, already-registered findings and unresolved candidates outside the group prevent a new grouped draft. Grouping cannot authorize publication. See [CityPay validation](../Development/p2-09-validation.md).

## Native registry management (P2-10b)

Open **Bugs** beside a project, or choose **Bug Registry** in the command palette. Actions resolve current project identity rather than relying on its name. The browser filters current records by status, exact environment, ticket association and archive inclusion. A bounded literal search checks title, root/expected/actual behavior, reproduction, structured details, ticket key/URL and internal UUID. It is case/diacritic insensitive, accepts up to 1,024 characters, and pages through 50 matches at a time. This administrative search is separate from duplicate classification.

**New Bug** starts a reported, manual finding with a local human-statement source. The Behavior tab edits assessment, environment, root behavior, expected/actual behavior and individually preserved reproduction steps. Ticket & Links manages supplied ticket keys/HTTPS URLs and directed links to existing same-project bug UUIDs. Sources & Details allows explicit user-attested observations or interpretations; declaring a source does not verify an operational artifact. Structured Fields edits bounded structured details, exact evidence references, coverage subjects and provenance. Protected comparison-decision metadata remains immutable through this generic editor.

**Review Changes** redacts the candidate using centralized content redaction and shows exact changed fields. Publish writes the reviewed version; a later binding edit cannot replace the candidate. Cancelling writes nothing, stale/expired proposals fail, and archive/unlink retain history. Earlier versions can be inspected; Edit Latest Version always starts from the current head. Ordinary edits preserve their original requirement references. Requirement/coverage navigation and impact management are P2-10c; duplicate/report decision UI is P2-10d.

The inspector shows outgoing links from the selected version and separately labeled incoming links from current registry heads, including archived sources. Incoming links have bounded keyset pagination. Following either direction reopens the target within the same project. Supplied HTTPS tickets are inert until the user explicitly selects Open Linked Ticket; local publication neither verifies nor modifies the remote issue. New ticket creation remains subject to the mandatory duplicate and policy gates.

Mac views use scrollable forms, an explicit review footer, and adaptive logical sizing. The registry and nested editor/JSON sheets bound their height using the actual presenting view, retaining room for the sheet attachment within short windows. Preview redaction uses ephemeral local context and never records a fake execution or changes source provenance. Source-history integrity hashes are not presented as sanitized operational evidence. See [P2-10b validation](../Development/p2-10b-validation.md) for acceptance and platform coverage.

## Native associations (P2-10c)

Ticket & Links now provides an explicit Edit requirement associations toggle. Leaving it off preserves the exact saved references on ordinary bug edits. Turning it on reviews latest-active requirements by default, allows deliberately historical versions and roles, and permits an explicitly empty selection to clear all associations. The review includes before/after requirement IDs, versions and historical choices. A requirement changing between review and publication rejects a latest-active request.

Coverage subjects support adding/removing manual or automated test identities. These are inert associations, not claims of execution or correctness. The traceability inspector includes current, potentially stale and unavailable Bug Registry requirement associations and opens the scoped bug editor for review. Archived bug heads are excluded from impact. Bugs retain their immutable revision history. See [P2-10c validation](../Development/p2-10c-validation.md) for native UI, Mac and iPhone coverage.

## Native comparison and report review (P2-10d)

The current implementation opens **Review Duplicates** from a selected bug. Select an agent and environment, review the context, then compare current evidence. This opens a read-only review service without requiring a Codex login. The service holds the project lease and validates context, scope, source revisions and expiry. Changing context or closing the sheet releases that lease.

The comparison separates deterministic suggestions, recorded user decisions, current requirements and source provenance. Choosing Duplicate, Related or Distinct and entering a reason prepares an exact local decision for review. Saving consumes that proposal; cancellation leaves history unchanged. A changed comparison invalidates publication. These native administrative controls do not give the agent registry-write authority.

For a matching registered ticket, **Prepare Ticket Addition** creates a local evidence draft. **Prepare CityPay Report** requires explicit component, region, area and module; grouping additionally requires compatible observations and a shared problem title. Unresolved duplicate candidates block a new report. **Copy Reviewed Draft** revalidates the context and bound sources before writing the clipboard. Neither action creates or updates an external ticket.

A possible duplicate can open the existing Codex run console. The read-only review releases its lease first; the console prepares a fresh comparison and displays the exact comparison evidence before the normal execution approval. Its result remains interpretation and does not save a duplicate decision automatically.

Native interactive scenarios and the unlocked-session Keychain recheck passed. See [P2-10d validation](../Development/p2-10d-validation.md) for passing model, Runtime and iPhone coverage and the blocked UI runs.

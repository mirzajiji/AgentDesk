# Bug registry, duplicate detection and CityPay formatting

Status: persistent registry, reviewed manual ticket associations, duplicate comparison and evidence-draft services implemented. CityPay report generation and native management remain planned. Source: [final architecture](final-architecture.txt), sections 51–65.
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

Bug links preserve duplicate-of, blocked-by, related-to and regression-of direction. Their inverse views (duplicated-by/blocks) can be derived from stored source/target identities; native relationship views are P2-10. Targets must already exist in the same project. Self-links, duplicate edges and directed cycles are rejected; related-to is allowed to be symmetric. Coverage references are limited to test subjects. Documents are bounded to 256 KiB; each history is bounded to 1,024 versions/16 MiB. Relationship traversal is bounded to 64 visited bugs per directed edge.

See [registry validation](../Development/p2-07-validation.md). P2-08 consumes the registry for duplicate checks; P2-10 adds native bug management. This task creates no external tickets, performs no semantic comparisons and runs no company infrastructure.

## Duplicate comparison and review services (P2-08)

`ProjectBugStore.comparisonSnapshot` reads current bug heads and their current active requirements under one catalog lock. It includes archived records within the exact environment, with a 256-record/16 MiB bound and at most 1,024 distinct requirement resolutions. Exceeding bounds fails explicitly. Its private-data fingerprint detects changed records and requirements; runtime consumers must authorize access before collection and redact before persistence, display or provider input.

`BugComparison` ignores titles and compares normalized root/expected/actual text, exact structured attributes, environment and current requirement references. Text normalization preserves case and internal whitespace. An exact duplicate also needs a meaningful endpoint/module/component/validation-field/scenario anchor or shared requirement. Same-root differences become possible duplicates; shared context without matching behavior is related. Cross-environment comparisons cannot become exact duplicates. Reported, blocked, missing-environment and stale-requirement findings expose explicit readiness outcomes; no matches is not proof that a defect is new or verified.

`NativeRunService.prepareBugReview` authorizes the read before opening the registry and rechecks access after collection. Referenced artifacts/traces must match project, environment, run, agent, artifact identity and the sanitized content fingerprint. Provider responses remain interpretations; manually recorded observations remain user-attested. The sanitized packet includes at most 32 relevant records and 128 references within 32 KiB. Raw registry/requirement history hashes are not copied into it. Oversize or missing evidence fails rather than silently omitting required source content.

`prepareBugAmbiguity` accepts possible-duplicate cases and prepares a normal Codex execution behind the existing policy/approval controls. Exact sanitized comparison bytes enter the frozen task and dispatch fingerprint. Source validation runs before start and immediately before provider dispatch after repository capture. Codex can explain overlap, differences and uncertainty; its output does not grant authority or automatically mutate the registry. The review expires after five minutes and fails on access revocation or changed sources.

`ProjectBugStore.prepareComparisonDecision` creates a separate local administrative proposal for duplicate/related/distinct resolution. It records compared immutable revisions, deterministic suggestion, selected resolution and reason; an override is explicit. `publishReviewed` consumes the exact proposal and validates the complete snapshot under the publication lock. Earlier decisions remain in immutable history. The general draft API cannot replace decision metadata. Duplicate decisions cannot promote reported/blocked/stale incoming findings or treat an unobserved/stale existing record as a verified duplicate. Native decision editing and publication controls are P2-10; read-only Codex authority does not imply registry write access.

`prepareBugTicketEvidence` prepares text for an existing ticket only after exact comparison or a fresh explicit duplicate decision. It copies the selected incoming source, current requirement versions, reproduction and verified evidence provenance; unrelated candidates are excluded. Ticket identity, source versions, scope, read policy and expiry remain bound to the draft. A ticket change invalidates it. This service sends no network request; later external publication requires its own exact payload approval and integration. See [duplicate-review validation](../Development/p2-08-validation.md).

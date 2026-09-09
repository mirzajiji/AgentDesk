# Bug registry, duplicate detection and CityPay formatting

Status: planned design. Source: [final architecture](final-architecture.txt), sections 51–65.
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

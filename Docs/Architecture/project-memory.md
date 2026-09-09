# Project memory, retrieval and knowledge relationships

Status: planned design. Source: [final architecture](final-architecture.txt), sections 11, 12, 17, 103, 107 and 149–151.
<!-- Source sections: 11,12,17,103,107,149,150,151 -->

Project Memory holds reusable confirmed knowledge: project descriptions, accepted behavior, rules, API/state/environment semantics, test expectations, architecture, QA decisions, terminology and linked defects. Store separate structured JSON records rather than one growing monolithic document.

## Information classes

| Class | Meaning | Promotion behavior |
| --- | --- | --- |
| Run context | Information relevant to a single execution | Does not automatically become permanent |
| Evidence | Observed technical facts and source metadata | Retain provenance and classification |
| Project memory | Reusable confirmed knowledge | Review proposed changes |
| Requirement | Versioned authoritative expected behavior | New immutable version for changes |
| Bug registry | Known defects and external associations | Preserve duplicate/evidence relationships |
| Notes | Manual or uncertain findings | Explicit promotion to other record types |
| Inbox | Imported information with unresolved destination | User classifies, attaches, promotes or dismisses |

An agent may propose a requirement or memory update. It must not silently convert ambiguous statements, analysis or imported screenshots into authoritative behavior.

## Retrieval

Search is scoped to the active workspace/project by default. Start with metadata, structured relationships and SQLite FTS5 indexing; retain an abstraction for future local semantic search. Agents can declare include/exclude knowledge paths. Scope and classification checks occur before results enter context.

Do not inject the whole project into every request. Build a bounded context selection tied to the task, with record IDs, requirement versions and source references shown in the context inspector. Missing or contradictory knowledge should remain visible rather than filled with invented rules.

An explicit global dashboard/search mode may aggregate allowed metadata. It must not silently combine confidential company content into model context or weaken underlying access checks.

## Relationship graph and timeline

Track requirement versions linked to tests, automation, bugs, documentation and workflows. Support questions about current behavior, changes, stale tests, coverage, blocked scenarios and known ticket associations. Project timeline events include requirement changes, runs, collection imports, duplicate findings, evidence attachments and approved actions.

Proposed implementation: indexes and timeline projections are rebuildable from authoritative records and operational events. Deleted or unavailable sources should produce clear dangling-reference states rather than silently rewriting history.

## Verification

Test selective retrieval and exclusions, two-project/workspace isolation, latest vs historical requirement resolution, FTS index rebuilds, stale references, note/inbox promotion, classification filtering and source provenance. A generated interpretation must remain distinguishable from observed evidence after persistence and reload.

# Context import, OpenAPI and contract drift

Status: planned design. Source: [final architecture](final-architecture.txt), sections 144–146.
<!-- Source sections: 144,145,146 -->

Projects can import Markdown documentation, JSON requirements, OpenAPI, Postman collections/environments, repository/test-directory references, bug exports, Jira keys/links and CSV test cases. Imported content is untrusted data and must remain scoped to its selected workspace/project.

## Import boundary

Inspect format, size, encoding, schema and references before writing authoritative records. Classify content and suggest destinations. Ambiguous information belongs in notes/inbox/evidence pending review, not an automatically published requirement. Preserve source/provenance and report unsupported input clearly.

Proposed import transaction: parse into temporary typed records, validate scope/references/secret candidates, show preview/diff, then apply approved changes with recoverable writes. Do not execute embedded scripts or fetch arbitrary referenced URLs merely while parsing. Handle archive/path traversal if archives are added later.

## OpenAPI

Import JSON/YAML specifications and provide native endpoint/schema/required-field browsing. Link endpoints to requirements, Postman requests and test scenarios. Validate request/response evidence against the supported specification version and clearly label unsupported features or unresolved references.

Scenario generation and missing-coverage suggestions require review and the normal execution permissions. Documentation describing an endpoint does not grant permission to call it.

## Drift analysis

Compare specification or requirement versions for new/removed endpoints, required-field changes, removed properties, enum changes and response-shape changes. Identify affected collections, automated tests, requirements and scenarios through recorded links. Distinguish deterministic structural change from semantic interpretation; flag uncertain impact instead of declaring unrelated tests broken.

Test malformed/oversized input, dangerous references, secret detection, scope selection, dry preview/cancellation, duplicate/reimport conflicts, unsupported schema versions, preserved identities/provenance and deterministic drift fixtures. See [scenarios](scenarios.md) for Postman-specific import/export behavior.

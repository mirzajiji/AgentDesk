# Testing strategy, agent evals and coverage

Status: planned design and acceptance requirements. Source: [final architecture](final-architecture.txt), sections 74, 111 and 123–125. No product test results are claimed here.
<!-- Source sections: 74,111,123,124,125 -->

AgentDesk's code and configured agents must both be testable. Ordinary tests use synthetic data, fake providers and isolated temporary storage. Real company integrations and paid/live Codex execution must not be prerequisites for routine unit tests.

## Required suites

| Subsystem | Important behavior and failure cases |
| --- | --- |
| Isolation | Cross-workspace/project file, memory, MCP, plugin, database, trace and artifact denial; path traversal and symlink escape |
| Requirements | Creation, immutable history, increment/publication, latest-active resolution, stale tests and impact links |
| Bugs | Manual registration/linking, exact/possible/unrelated duplicates, blocked scenarios and additional evidence |
| Codex | Detection, supported auth states, safe arguments/stdin, partial output, exits, cancellation, timeout and cleanup |
| Plugins | Scoped setup/auth/lifecycle, disable/disconnect, permissions and exact approvals |
| MCP | Discovery, denied tools/resources/prompts, server isolation, restart and failed health |
| Databases | Configuration/Keychain, connection tests, dialect-aware classification, approved writes, destructive denial and scope |
| Mobile | Pairing, unpaired/revoked denial, discovery, reconnect/replay, live state, diffs, approvals and secret/shell denial |

## Agent evals

Configured-agent assertions can test expected/forbidden concepts, output schema, required classifications, permitted/prohibited tools, artifacts, duplicate decisions and deterministic validation. The UI should run one case or a suite and show actual results with fixtures/evidence. Distinguish stochastic live-agent evals from deterministic unit tests and record provider/config versions for reproducibility.

Test the oracle as well as the result. A string match is insufficient for permissions or duplicate correctness. Proposed fixtures include explicit counterexamples: same title/different root defect, different title/same observed defect, missing evidence, stale requirement and blocked downstream behavior.

## Coverage graph

Map requirement → scenario → automation → latest result. Display covered, partially covered, not covered, stale, blocked, failing or unknown. Counts should reflect actual linked tests, not an agent's claim that coverage is comprehensive. A blocked result is not a pass or a verified downstream failure.

After requirement changes, identify missing linked tests deterministically first. Semantic comparison may help suggest coverage, but ambiguous matches require review. Preserve exact requirement versions and environment scope.

## Test data

Store scoped definitions for generators, reusable fixtures, setup/cleanup workflows, expiry, ownership and environment. Prefer synthetic/generated identities over permanent real customer data. Cleanup actions obey the same permissions as other writes and must not destroy unrelated shared data. Named resource locks coordinate shared fixtures when needed.

## Development gate and native matrix

For every important task: implement/exercise, add unit/regression tests, run affected suites, review, then commit separately. Test both native targets for shared changes. Run local iPhone Simulator tests on compact/large models and minimum/newest installed supported OS versions; record commands, model/OS and unavailable cases. Build-only validation is not a simulator test.

Detailed execution records belong in [development testing](../Development/testing.md). Physical-device testing remains necessary for final LAN, device authentication and background/Wi-Fi behavior. CI supplements local verification; it does not substitute for the user's requested local emulator coverage.

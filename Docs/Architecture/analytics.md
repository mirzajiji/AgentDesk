# Project dashboards and operational analytics

Status: planned design. Source: [final architecture](final-architecture.txt), section 116.
<!-- Source sections: 116 -->

Provide application overview, workspace dashboards and a detailed per-project analytics view. Every query must enforce the selected scope. An explicit global dashboard can aggregate authorized totals without merging confidential company content into prompts.

## Measures and dimensions

| Area | Measures |
| --- | --- |
| Runs | Total/success/failure/cancellation/blocked/active, approval wait, runtime/average duration, agent/scenario/workflow distinctions |
| Agents/profiles | Run counts, durations and outcomes per agent and logical execution profile; real underlying model only when available |
| Tools/plugins/MCP | Calls, success/failure, measured latency, connection errors, read/write and approval counts |
| Databases | Read/write queries, approvals, denials and failures per connection; no sensitive result rows |
| Scenarios | Collection/scenario runs, passed/failed/blocked, frequently failing scenarios |
| Bugs | New defects, duplicates, possible duplicates, blocked scenarios, registered tickets and added evidence |
| Requirements | Active records, updates, stale scenarios/tests, unlinked tests and impact analyses |
| Provider usage | Genuine token/profile metadata where available; missing stays unavailable |

Filters include Today, Last Five Hours, Seven Days, Thirty Days, This Week, Previous Week and custom range where useful. Explain timezone and time boundaries. Show daily/weekly trends, agent/tool/profile combinations and environment breakdowns. Define denominators for percentages and distinguish zero activity from missing data.

## Source and accuracy

Aggregate existing structured runs, steps, traces/call events, scenarios, approvals, artifacts, bugs, requirements and provider metadata. Do not build a disconnected second analytics tracker. Proposed implementation: query scoped indexed records first, then add materialized summaries only when measured performance warrants them.

Deduplicate events and define whether retries count as separate attempts or logical operations. Distinguish elapsed duration, active execution time and approval wait. Show cancellation/blocked/error separately so failures are not hidden by blended success rates. Historical configuration/model metadata must reflect what actually ran.

Later exports can produce scoped JSON/CSV/reports using the same classification and redaction rules. Test time-window boundaries, filtering, duplicated/late telemetry, interrupted runs, denominator handling, absent provider metadata, aggregation consistency and two-company isolation. Performance tests should use representative thousands-of-run fixtures without real sensitive content.

# Provider usage and local activity

Status: planned design. Source: [final architecture](final-architecture.txt), sections 29–30.
<!-- Source sections: 29,30 -->

Settings → AI → Usage separates provider-reported allowances from local AgentDesk activity. These data sources answer different questions and must remain distinguishable.

## Provider-reported values

When supported by the installed Codex CLI, capture plan, five-hour/weekly allowance, remaining amount, reset times, model/profile metadata and genuine token counts. Missing information displays “Unavailable from installed Codex CLI.” Do not estimate a remaining provider allowance from the number of local runs.

Store input, cached input, output and total tokens only when machine-readable provider metadata supplies them. Preserve the source and meaning of counters; cached tokens may be a subset of input tokens, so do not blindly add every field. Unknown is distinct from zero. Late or duplicate metadata must not double-count usage.

## Local metrics

Always derive local counts and timings from actual runs: today, last five hours, this week, per workspace/agent/profile, failures, cancellations, total/average duration and active work. Explain the chosen timezone and time-window boundaries. Show approval wait separately where the metric needs execution time rather than wall-clock time.

Use scoped operational records as the source for the richer [project analytics](analytics.md). Historical account switches must not delete local run history or retroactively assert the new provider account owned prior usage.

Tests should cover unavailable vs zero, partial token metadata, repeated provider events, interrupted runs, date boundaries, timezone changes, scoped aggregation and filtering. Validate actual provider metadata contracts during CLI integration work before calculating totals or percentages.

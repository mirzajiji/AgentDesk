# Project databases and controlled SQL

Status: planned design. Source: [final architecture](final-architecture.txt), sections 41–50.
<!-- Source sections: 41,42,43,44,45,46,47,48,49,50 -->

Database connections belong to a project and environment inside one workspace. PostgreSQL is the first driver; a driver boundary allows future engines without changing agent definitions. The Mac is the only database execution authority.

## Setup and secrets

Store connection ID/name, type, host/port, database/schema, username, SSL mode, environment, description and validated additional parameters. Passwords and other sensitive credentials are Keychain references. Duplicating a connection must not silently cross scope or clone authority.

UI supports configure, test, connect, disconnect, edit, duplicate, delete and update password. Distinguish not configured, configured, connecting, connected, authentication failed, network unavailable, connection failed and disconnected. Show actual diagnostics rather than a generic connected badge after saving.

## Capability and query boundary

Normalized capabilities include listSchemas, listTables, describeTable, executeReadQuery, executeWriteQuery and explainQuery. Each call carries workspace/project, connection, environment, run/agent and query context.

Dispatch sequence: validate scope → select connection → classify query → evaluate policy → obtain any exact approval → execute → sanitize/record result. The manual query console uses this identical boundary.

| SQL category | Baseline treatment in the source architecture |
| --- | --- |
| SELECT | Read, subject to environment policy |
| INSERT / UPDATE | Write, typically approval |
| DELETE | Destructive write, denied by default examples |
| CREATE / ALTER | DDL |
| DROP / TRUNCATE | Destructive |
| Multiple statements | Highest risk of any statement |

Proposed hardening: classification must parse the selected dialect rather than inspect only the first word. Account for writable CTEs, procedural calls/functions, comments, quoted strings and engine-specific operations. Ambiguous/unsupported statements fail closed. Restrict driver/database credentials and read-only sessions as defense in depth; a textual SELECT label alone does not prove side-effect freedom.

Production defaults are stricter: reads can require approval, while writes/DDL/destructive operations are denied. Agents cannot elevate themselves or switch to a more privileged connection after denial.

## Inspection and evidence

Schema browsing shows schemas, tables, columns, indexes, constraints and relationships, with scoped refreshable metadata caching. Query results show rows, duration, affected rows, errors and approval status. Apply row/size/time limits and cancellation as explicit implementation policies.

Evidence records connection/environment/run identity and a safe summary. Full result retention is configurable because DB rows may be confidential. Do not put credentials, raw sensitive rows or unredacted connection strings in analytics/mobile responses.

Tests cover configuration, Keychain references, lifecycle/errors, scope isolation, SQL edge cases, multi-statement highest risk, approved payload binding, denied destructive queries, console parity, cancellation/timeouts, safe schema refresh and result redaction.

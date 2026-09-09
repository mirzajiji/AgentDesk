# Plugins, connection lifecycle and diagnostics

Status: planned design. Source: [final architecture](final-architecture.txt), sections 31–36, 105–106 and 142.
<!-- Source sections: 31,32,33,34,35,36,105,106,142 -->

A Plugin is AgentDesk's user-facing integration abstraction. Implementations may use MCP, REST, CLI, native Swift or a local process. Agents normally depend on normalized capabilities rather than provider internals. Examples include Jira, GitLab/GitHub, Confluence, Slack, Grafana, PostgreSQL, Kubernetes, Playwright, browser and filesystem capabilities.

## Scope and configuration

Each workspace/project configures integrations independently. Authenticating one company's Jira does not authenticate another company's instance. Persist non-secret setup and Keychain references; keep authentication state, granted permissions and runtime connection state distinct.

Lifecycle states are disabled, enabled/not configured, connecting, connected, authentication expired, error and disconnected. Actions include enable/disable/connect/login/reauthenticate/disconnect/logout/reset/test. Disconnect must actually stop/remove the relevant local connection state. Define whether logout removes credentials separately from disabling a configured integration.

## Capability enforcement

Every capability declares its action/resource and passes through allow/approval/deny policy. Jira issue read and comment read can be allowed while creation/update/comment write requires approval and deletion is denied. A plugin implementation cannot invoke an internal transport directly to avoid its capability gate.

For Jira onboarding: enable, configure instance, authenticate, validate account, discover supported capabilities, configure permissions, save and test. Display instance, account, scope, status, permissions and health. Do not send a message or create a ticket merely to test a read-only connection.

## Diagnostics

One connections overview shows Codex, plugins, MCP, databases, repositories and remote devices. Each integration reports real status and an actionable last error. Distinguish authentication expiry, network failure, invalid configuration and a stopped local process.

Diagnostics should expose staged checks where supported: DNS/TCP/TLS/authentication/project access for a remote service; process/transport/handshake/discovery for MCP; authentication/database/schema for a DB. Show latency only when measured and label unsupported checks. Sanitize diagnostic output and never reveal tokens or full sensitive endpoint credentials.

## Verification

Test lifecycle transitions, actual disconnect cleanup, expired login, enable without configuration, denied capabilities, exact approved writes, two-company account isolation and diagnostics that identify the failed layer. Verify a fallback transport goes through policy and cannot gain broader permissions. A stored configuration is not evidence of a successful live connection.

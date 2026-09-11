# Optional Jira OAuth exchange service

Status: implementation in progress. The runnable Swift service includes authorization attempts, confidential code/refresh exchange, bounded loopback HTTP, global admission limits, expiry maintenance and graceful shutdown. Synthetic and local socket tests cover these paths. Native UI integration, trusted TLS proxy configuration and live registration validation remain unfinished; nothing is deployed.

AgentDesk's core app and Mac–iPhone LAN connection remain local-first and do not require this service. Jira Cloud's distributable OAuth integration requires a confidential client secret for authorization-code exchange and refresh. That secret must belong to the AgentDesk integration and stay on a service controlled by its publisher; it must not be embedded in the native application or requested from every user.

## Required flow

1. The Mac creates an ephemeral verifier and challenge and starts a broker attempt. The broker chooses an unpredictable OAuth state and returns a bounded authorization URL for the single registered AgentDesk integration. The Mac binds the attempt to its exact project, environment and connection.
2. The system browser opens Atlassian consent. The broker receives the registered HTTPS callback, validates state, expiry and single use, and exchanges the code with Atlassian. It does not return tokens through browser redirects or query strings.
3. The Mac claims the result over HTTPS by proving possession of its verifier. The broker releases the token bundle once and removes it from memory. The Mac validates the selected site/account and saves the grant in its scoped Keychain entry.
4. Refresh passes through a bounded authenticated exchange tied to the same grant and integration. Rotating refresh values replace the complete local token bundle atomically. Ambiguous refresh outcomes require reauthentication instead of blindly replaying a consumed token.
5. Cancellation, denial and expiry destroy the attempt. Logout closes the local session and deletes the local grant; a pending callback/refresh must not restore a logged-out grant.

## Server requirements

- Fixed Atlassian endpoints; no caller-supplied exchange destination, redirect URI or client identity.
- Client secret provided through deployment secret storage, never source, response bodies or logs.
- HTTPS termination, strict request sizes, deadlines, attempt TTL, bounded concurrent attempts and rate limits. Listen on loopback by default behind the configured TLS proxy.
- No request-body, authorization-header, code, token or callback-query logging. No third-party analytics on callback pages. No referrer leakage or external assets.
- Compare proof values in constant time. Distinct OAuth state and native claim proof; neither is a project ID or predictable connection identifier.
- Keep tokens only for the bounded claim window. A restart invalidates unclaimed attempts. No company issue data passes through the broker.
- Test foreign/wrong proofs, callback replay, claim replay, expiry, cancellation, missing registration, upstream errors, size bounds and refresh ambiguity before native integration.

## Configuration still needed

The publisher's public client ID, registered HTTPS callback, service hostname and deployment secret channel are not configured. Public registration details have been requested. No live user credentials have been accessed. This document is not authorization to deploy a service or create a paid account.

Official reference: [Atlassian OAuth 2.0 (3LO)](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/). Native read-backend acceptance: [P3-03a](../../Docs/Development/p3-03a-validation.md). Interactive authentication remains P3-03b.

## Run locally on macOS

Build with `swift build --package-path Services/JiraOAuthBroker` from the repository root. Run the local process check with `python3 Services/JiraOAuthBroker/Scripts/smoke-test.py`. It uses only synthetic values, binds an ephemeral loopback port, checks a request and shuts the process down.

The executable is `Services/JiraOAuthBroker/.build/debug/jira-oauth-broker`. Configure these public environment variables through the service manager:

- `AGENTDESK_JIRA_CLIENT_ID`: registered publisher integration ID.
- `AGENTDESK_JIRA_CALLBACK`: exact registered HTTPS callback with a dedicated path outside `/v1/`.
- `AGENTDESK_JIRA_PORT`: local TCP port, 1–65535.

Supply the client secret as raw bytes on standard input from deployment secret storage, then close that input. One trailing LF or CRLF is accepted. The executable rejects interactive terminal input, empty/multiline secrets and inputs over the token size bound. Do not pass the secret as a command argument, paste it into shell history, or put it in the source tree. It prints only the loopback listening address and fixed failure diagnostics. SIGINT/SIGTERM stop active connections and close the exchange session.

This is a macOS service executable, not a deployment or a public HTTPS endpoint. A TLS reverse proxy and public registration are still needed for browser consent. Keep body/header/query logging disabled in that proxy. The trusted proxy configuration and live registration validation are unfinished; do not expose this development service publicly yet.

The listener now applies a global token-bucket admission budget: burst 120, refill 20 connections/second, before reading requests or invoking OAuth work. Exhaustion returns HTTP 429 and closes the connection. Credits use monotonic time and remain capped after idle periods. This complements the 64 concurrent-connection cap and 45-second deadline. A trusted TLS proxy must still impose per-client limits; the broker deliberately does not trust caller-supplied forwarding headers as client identity. Global admission protects process workload but does not provide fair allocation between users.

A one-second maintenance task removes expired attempts even without incoming requests. All API operations also enforce the ten-minute expiry directly. SIGINT/SIGTERM stop maintenance, cancel exchanges and clear the attempt registry; an existing registry cannot reopen after shutdown. Memory reclamation follows normal Swift lifetime management, not guaranteed secure byte erasure or real-time scheduling.

# Codex CLI provider and account management

Status: planned design. Source: [final architecture](final-architecture.txt), sections 23–28. No particular CLI flag or machine-readable event format is claimed as verified here.
<!-- Source sections: 23,24,25,26,27,28 -->

Codex CLI is the sole current AI backend behind `ExecutionProvider` and `CodexCLIProvider`. Agent definitions refer to logical execution profiles so provider-specific model names do not spread through domain code.

## Capability discovery

Locate the executable, detect its installed version and supported capabilities, and evaluate readiness/authentication using official mechanisms exposed by that installation. A successful file existence check does not establish that execution or authentication is ready. Validate configured executable locations without scanning or extracting unrelated account secrets.

The provider must support safe prompts, working-directory selection, noninteractive execution where supported, stdout/stderr streaming, cancellation, timeouts, exit status, changed-file/diff collection, operational events, redaction and execution metadata. Implement against installed CLI documentation and fixtures; unavailable capabilities must remain visibly unavailable.

## Safe execution

Launch `Process` with an executable and argument array. Supply prompt data through a supported non-shell channel such as stdin or a scoped file. Never interpolate user prompts or repository content into shell command strings. Use a validated repository, controlled environment and runtime-enforced policy.

Provider output is untrusted data. Bound buffering, handle partial UTF-8 and split structured records, separate stdout/stderr, redact before persistence, and handle malformed/unknown events. Distinguish a clean process exit from successful task validation. Process cancellation/timeout must address descendants, pipe draining and resource cleanup using the supported host architecture.

## Account UI

Settings → AI → Codex shows installed/version, authentication, safely available account/plan metadata and Health Check, Login, Logout, Reconnect and Disconnect actions. States include not installed, installed/logged out, authenticating, authenticated, expired, usage limited, CLI error and unavailable.

Use officially supported login/logout flows. AgentDesk must not manage ChatGPT cookies or inspect hidden session tokens. Switching accounts logs out, initiates the supported login, then refreshes state; workspace/project data survives. Define how active runs react to logout or disconnect and make that behavior visible.

## Profiles and escalation

Map FAST, BALANCED, REASONING, CODING and MAX to current installed-provider configuration. Agent routing choices include AUTO, FASTEST, BALANCED, BEST_QUALITY and FIXED. Deterministic classification comes before model reasoning. Escalation is driven by output-schema validity, required fields/evidence, test outcomes, exit codes and missing information; self-reported confidence alone is insufficient.

Test missing/wrong executables, logged-out/expired/limited responses, safe argument/stdin handling with shell metacharacters, streaming chunks, malformed events, failure exits, cancellation, timeout, profile mapping and validator-driven escalation. Never use fabricated account, model or usage values to make a UI appear connected.

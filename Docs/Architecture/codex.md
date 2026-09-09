# Codex CLI provider and account management

Status: executable discovery, normalized diagnostics, supported account-command adapters, native Settings and the signed Mac host are implemented in P1-08a/b. The execution provider follows separately. Source: [final architecture](final-architecture.txt), sections 23–28. See [diagnostics validation](../Development/p1-08a-validation.md).
<!-- Source sections: 23,24,25,26,27,28 -->

Codex CLI is the sole current AI backend behind `ExecutionProvider` and `CodexCLIProvider`. Agent definitions refer to logical execution profiles so provider-specific model names do not spread through domain code.

## Capability discovery

Locate the executable, detect its installed version and supported capabilities, and evaluate readiness/authentication using official mechanisms exposed by that installation. A successful file existence check does not establish that execution or authentication is ready. Validate configured executable locations without scanning or extracting unrelated account secrets.

The provider must support safe prompts, working-directory selection, noninteractive execution where supported, stdout/stderr streaming, cancellation, timeouts, exit status, changed-file/diff collection, operational events, redaction and execution metadata. Implement against installed CLI documentation and fixtures; unavailable capabilities must remain visibly unavailable.

## Safe execution

Launch native subprocesses with an executable and argument array. Supply prompt data through a supported non-shell channel such as stdin or a scoped file. Never interpolate user prompts or repository content into shell command strings. Use a validated repository, controlled environment and runtime-enforced policy.

Provider output is untrusted data. Bound buffering, handle partial UTF-8 and split structured records, separate stdout/stderr, redact before persistence, and handle malformed/unknown events. Distinguish a clean process exit from successful task validation. Process cancellation/timeout must address descendants, pipe draining and resource cleanup using the supported host architecture.

## Account UI

Settings → AI → Codex shows installed/version, authentication, safely available account/plan metadata and Health Check, Login, Logout, Reconnect and Disconnect actions. States include not installed, installed/logged out, authenticating, authenticated, expired, usage limited, CLI error and unavailable.

Use officially supported login/logout flows. AgentDesk must not manage ChatGPT cookies or inspect hidden session tokens. Switching accounts logs out, initiates the supported login, then refreshes state; workspace/project data survives. Define how active runs react to logout or disconnect and make that behavior visible.

## Profiles and escalation

Map FAST, BALANCED, REASONING, CODING and MAX to current installed-provider configuration. Agent routing choices include AUTO, FASTEST, BALANCED, BEST_QUALITY and FIXED. Deterministic classification comes before model reasoning. Escalation is driven by output-schema validity, required fields/evidence, test outcomes, exit codes and missing information; self-reported confidence alone is insufficient.

Test missing/wrong executables, logged-out/expired/limited responses, safe argument/stdin handling with shell metacharacters, streaming chunks, malformed events, failure exits, cancellation, timeout, profile mapping and validator-driven escalation. Never use fabricated account, model or usage values to make a UI appear connected.

## Implemented diagnostics adapter

`MacCodexDiagnostics` uses a fixed list of common installation locations or an explicitly selected executable. Paths must resolve to executable regular local files. Discovery does not search repositories, shell startup scripts, browser data or credential stores. Version output must match the Codex CLI format; supported capabilities are extracted from that installation's help. Optional capabilities stay false when absent.

The installed CLI verified on 2026-09-09 is `0.153.4`, located in the ChatGPT application's Resources directory. Its public help supports `login`, `login status`, `logout`, noninteractive `exec`, stdin prompts, JSON events, ephemeral sessions and ignoring user configuration. These facts do not claim that the future execution provider is implemented. Official references: [CLI commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli) and [authentication](https://learn.chatgpt.com/docs/auth).

The status adapter requires both the recognized public status text and matching exit code. It distinguishes ChatGPT credentials present, signed out, unsupported authentication method and unknown/error. Credentials present does not prove network availability, token freshness, subscription plan or remaining usage; these remain unavailable unless later supported diagnostics establish them. Raw command output never enters the public snapshot. Login/logout recheck executable capabilities and refresh status afterward; overlapping account operations are rejected. The live development probe ran only version/help/status and preserved the existing login.

Commands use argument-array `posix_spawn`, a fresh process group, default signal dispositions, empty signal mask, null stdin and a private temporary working directory. A small explicit environment allowlist forwards normal CLI home/location context without arbitrary token variables. Stdout/stderr are drained independently into a combined 64 KiB bounded buffer. Ordinary diagnostics time out after 10 seconds; browser login after 180 seconds. Cancellation, timeout, output overflow and process exit clean up descriptors and remaining group children. The adapter does not interpret a login URL, read cached tokens, invoke a shell or expose arbitrary command execution to iPhone.

## Native Settings and execution host

P1-08b adds Settings → AI · Codex, reachable from the Mac toolbar and standard Settings command. It displays normalized installed version, executable, credential status and failures. Health Check refreshes diagnostics; Sign In uses the supported CLI browser flow; Sign Out requires a confirmation explaining that the shared CLI account also signs out. Disconnect persists AgentDesk's disabled state without logging out Codex. Connect restores access and refreshes status. Busy operations expose cancellation; duplicate requests and late cancelled results cannot replace current state. No active provider runs exist yet; their account-change coordination is a later execution gate.

The UI remains sandboxed. The separately signed `AgentDeskCodexHost.xpc` is embedded only in the Mac bundle and runs as the current macOS user without App Sandbox, retaining hardened runtime. It is an app-private XPC service, not a root daemon or LAN endpoint. Both peers require the exact counterpart bundle identifier and signing team. Its current Codable interface accepts only inspect/login/logout, validates a 16 KiB message bound and local paths, and returns normalized diagnostics. Each connection has one cancellable operation. Invalidation cancels the command and descendants; the client also imposes a deadline. There is no arbitrary shell endpoint.

This arrangement was explicitly [approved by the user](../Development/native-codex-host-proposal.md). The helper can access the user's CLI context and files allowed by ordinary macOS permissions; future repository operations must independently enforce scope and policy. Distribution currently targets a directly distributed signed Mac app; Mac App Store eligibility is not established. Apple's [XPC service design](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html) and [peer signing requirement API](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)) inform this boundary.

Settings persist only nonsecret machine-local configuration in the sandbox's Application Support/AgentDesk/Settings/codex.json: schemaVersion 1, enabled and an optional absolute executablePath. Files are bounded, validated and written atomically; malformed/future/linked records are preserved and configuration fails closed. This record contains no account tokens, prompt history or workspace data. See [native acceptance](../Development/p1-08b-validation.md). The installed account's login/logout was not mutated during acceptance; supported flow routing and cancellation use fake services in tests, while native health checks use the real CLI.

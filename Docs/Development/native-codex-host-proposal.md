# Native Codex host approval and implementation

The ordinary sandboxed AgentDesk launch detects Codex 0.153.4 but sees a different CLI home/sign-in context from the terminal. The terminal adapter confirmed existing ChatGPT credentials; the app originally reported signed out in its container. The full product also requires launching Codex and deterministic local tools against explicitly scoped repositories.

## Approved change

Add a separately signed, bundled macOS XPC service named `com.mirza.AgentDesk.CodexHost`, using the existing team `3R9673A8NL`. Keep the main app sandbox enabled. The helper runs as the current user with its own app-sandbox setting disabled, retaining hardened runtime. It is embedded under the Mac app's `Contents/XPCServices` and excluded from iPhone builds. This is a local direct-distribution host arrangement, not a Mac App Store acceptance claim.

The current prepared interface accepts only typed inspection, browser-login and logout requests. It validates bounded messages and local executable paths, rechecks CLI capabilities, captures bounded command output and returns normalized status. It does not provide a generic shell-command endpoint. Both sides set exact code-signing requirements for the other bundle and the existing team. The service is app-private; it opens no LAN port. Connection invalidation cancels its command and child process group.

An unsandboxed helper can access files and resources allowed to the current macOS user, including the installed CLI's own authentication/configuration context. A defect or compromise of that helper could therefore have a wider impact than a defect confined to the UI sandbox. It receives no root privilege, Full Disk Access grant, global security change or new provider credential from this proposal. AgentDesk calls supported CLI login/status/logout mechanisms; it does not extract cached credentials itself.

Prepared source for review:

- [Helper entry point](../../AgentDeskCodexHost/main.swift)
- [Bounded request contract and connection session](../../Packages/AgentDeskRuntime/Sources/AgentDeskRuntime/CodexHostProtocol.swift)
- [Signed native client](../../Packages/AgentDeskRuntime/Sources/AgentDeskRuntime/CodexHostClient.swift)
- [Existing command adapter](../../Packages/AgentDeskRuntime/Sources/AgentDeskRuntime/MacCodexCommandRunner.swift)
- [Helper bundle metadata](../../Configuration/CodexHost-Info.plist)

Automatic approval review initially rejected enabling this helper because earlier development authorization did not explicitly cover its broader file/account access. The user then reviewed this proposal and explicitly answered “Approve the signed Mac helper.” The approved target has now been added, signed, embedded and exercised through the native app. The app reports the existing CLI's ChatGPT credential status without copying credentials. The main app retains its sandbox. See [validation](p1-08b-validation.md) for checks and remaining scope.

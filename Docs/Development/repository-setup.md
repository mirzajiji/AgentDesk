# Personal repository and development access

## Repository

- App Git root: `/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk`.
- Personal fetch/push remote: `https://github.com/mirzajiji/AgentDesk.git`.
- Implementation branch: `codex/native-foundation`, based on `89905ae` (`Initial Commit`).
- Repository-local and effective author/committer: `Mirza Jijieshvili <mirzajijieshvili@gmail.com>`.
- Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64.

The outer `/Users/mirza/Documents/ChatGPT/AgentDesk` workspace has a separate empty repository. Run all app Git commands from the app Git root above. The user authorized separate commits and pushes to the supplied personal remote. Preserve history and global/work Git settings; never force-push.

## Current access

After the user moved the complete project, source writes and branch creation succeed. Git integrity passes after removal of stray Finder metadata from its references directory. The initial commit and staged documentation survived the move.

Session approval review now permits the authorized GitHub and native development commands. Personal branch push succeeds; ordinary SwiftPM tests and native Mac tests pass. Simulator runtimes can be enumerated and iPhone tests run. Current evidence is in [foundation validation](p1-01-validation.md); the earlier permission failures are historical. GitHub authentication uses the user's existing configuration; no credential is stored in this repository.

## Development sequence

1. B01 documentation is committed as `4d027e9`; do not repeat the import.
2. Complete validation for the native foundation already in the working tree; see [P1-01 evidence](p1-01-validation.md) and the [task plan](tasks.md).
3. Build both platforms and run local Mac/iPhone tests according to [testing](testing.md), recording unavailable checks honestly.
4. Commit each validated task independently. Verify effective author/committer and remote before a normal push of the intended branch when connectivity permits.

The user's existing authorization remains sufficient. Environment restrictions must be respected; do not extract credentials or disable security controls to bypass them.

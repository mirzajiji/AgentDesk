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

GitHub DNS remains unavailable. CoreSimulator cannot be reached, so device/runtime enumeration and iPhone tests remain blocked. The earlier default Mac build reported a missing development signing certificate; native build verification must distinguish compilation from signing, launch and UI-test coverage. Exact evidence and historical results are in [validation](updated-project-validation.md).

## Development sequence

1. Validate and commit B01 documentation separately.
2. Implement the native foundation in the [task plan](tasks.md), including meaningful unit tests and shared schemes.
3. Build both platforms and run local Mac/iPhone tests according to [testing](testing.md), recording unavailable checks honestly.
4. Commit each validated task independently. Verify effective author/committer and remote before a normal push of the intended branch when connectivity permits.

The user's existing authorization remains sufficient. Environment restrictions must be respected; do not extract credentials or disable security controls to bypass them.

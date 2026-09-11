# Explicit Jira write consent

The OAuth registration now accepts a typed read-only/read-write choice, defaulting to read-only. The native client sends this choice and rejects an authorization URL with different scopes. The broker accepts only `read` or `write`, preserves read-only behavior when omitted, and adds `write:jira-work` only for explicit write consent. This does not authorize individual Jira operations; runtime policy review is separate.

Validation on macOS 26.5.2 / Xcode 26.0:

- `swift test --package-path Services/JiraOAuthBroker`: 22 passed, including explicit/default consent and malformed access rejection. Log: `TestResults/p3-04/write-consent-final-broker.log`.
- `swift test --package-path Packages/AgentDeskPlugins`: 73 passed in the working tree, including native scope mismatch rejection. Log: `TestResults/p3-04/issue-edit-session.log`.
- From `Packages/AgentDeskPlugins`, `xcodebuild -scheme AgentDeskPlugins -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-04/PluginsIPhone -resultBundlePath ../../TestResults/p3-04/plugins-edit-iphone.xcresult -parallel-testing-enabled NO test`: 73 passed on iPhone 16 Pro / iOS 26.0.
- Native Mac and iPhone application builds passed; logs `TestResults/p3-04/app-edit-mac.log` and `app-edit-iphone.log`. These working-tree builds also include ongoing mutation implementation, which is not part of this consent commit.

Tests use synthetic transport fixtures. No live OAuth consent, broker deployment or external Jira mutation is claimed. P3-03b live acceptance, P3-04 mutations, and P3-05 native setup remain open. This is a focused prerequisite commit within that existing scope, not completion of P3-04.

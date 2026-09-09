# Device pairing, trust and revocation

Status: planned design. Source: [final architecture](final-architecture.txt), sections 87–88.
<!-- Source sections: 87,88 -->

Pairing establishes a device identity and explicit permissions. Same Wi-Fi is not authorization. The Mac user enables remote access and initiates Pair Device, then displays a QR code, short-lived single-use pairing code and host fingerprint/identity for verification.

## Trust establishment

After successful pairing, create cryptographic device credentials. The short pairing code must not become a permanent bearer credential. Bind the resulting trust to the intended host/device and granted workspace access. Protect local identity material using suitable platform storage.

The source does not specify a cryptographic protocol, certificate lifecycle, QR payload format or code lifetime. These are security-sensitive implementation decisions: choose a reviewed protocol and native cryptographic primitives, define host authentication and resistance to interception/replay/guessing, and test before enabling LAN access. Do not design an unauthenticated exchange and call it secure because it uses a QR code.

## Trusted devices

Mac Settings lists device name, last-seen state and permitted capabilities, such as run/artifact read, approvals and predefined workflow start, with administrative access denied by default. Support rename, permission changes and revoke. Display names are presentation only and never authorization identifiers.

Revocation must affect new requests and existing sessions. Recheck authority before executing a pending approved action. A removed device cannot regain access by replaying an earlier code, command or socket token. Loss of credentials requires explicit recovery/re-pairing rather than an insecure fallback.

## Verification

Test expired/consumed codes, wrong host fingerprint, replay, repeated guesses/rate limits, incomplete pairing cancellation, credential persistence, permission changes, revocation during streaming and revocation between approval and execution. Test high-risk device authentication on supported real hardware; simulator behavior cannot establish every hardware security property.

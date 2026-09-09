# LAN discovery, live streaming and reconnection

Status: planned design. Source: [final architecture](final-architecture.txt), sections 83, 85–86, 94–95 and 97.
<!-- Source sections: 83,85,86,94,95,97 -->

Local Wi-Fi operation is a required V1 capability. A paired iPhone and Mac on the same LAN must exchange run state and authorized actions without a cloud server, VPN or internet connection. External provider/integration availability remains independent.

## Discovery and connection modes

Use Apple-native discovery/networking where appropriate, such as Bonjour/mDNS and Network.framework. The conceptual service is `_agentdesk._tcp.local`; finalize actual service declarations, transport and privacy metadata in implementation. Advertise only minimal non-sensitive host information.

Explicit modes are local-only loopback, enabled local-network access, optional future private VPN and optional future relay. Binding beyond loopback is a deliberate user setting. A discovered endpoint still requires cryptographic authentication; matching name/address is insufficient.

Configure required local-network privacy declarations. Permission denied must show Permission Required rather than falsely reporting a sleeping/offline Mac. Connection states include discovering, connecting, authenticating, connected, reconnecting, Mac sleeping, unavailable and permission required. Report only states supported by actual evidence.

## Live connection

Use a persistent authenticated socket, preferably WebSocket, while the mobile client is active. Events cover runs, stages, steps, tools, integrations, files, artifacts, approvals and terminal outcomes. Bidirectional commands cover constrained approvals/cancellation/control/predefined starts and detail refresh.

Periodic polling is a recovery fallback, not the primary live-progress mechanism. The Mac owns authoritative state. Calculate progress from known structured stages where measurable; open-ended runs show stages without invented percentages.

## Replay and recovery

After a drop, rediscover the paired Mac when needed, authenticate again, request events after the last acknowledged sequence, reconstruct state and resume streaming. Define per-run sequence ordering and deduplicate events. Proposed fallback: if the retained replay window cannot cover the gap, return a scoped snapshot plus a consistent sequence boundary and resume from there.

Handle iPhone lock/unlock and foreground/background, Wi-Fi changes, DHCP address changes, temporary loss and Mac sleep/wake. Use bounded reconnect backoff and cancellation; avoid endless aggressive connection attempts. A backgrounded iPhone may suspend its socket, so UI must reconcile on return rather than assume continuous delivery.

Verify no-cloud LAN operation, discovery after IP change, permission denial, authenticated reconnect, gap replay/snapshot, duplicate/out-of-order messages, sleeping/offline ambiguity, event flood limits and identical desktop/mobile progress. Physical-device tests are needed beyond Simulator for complete LAN acceptance.

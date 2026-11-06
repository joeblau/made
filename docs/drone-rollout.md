# Drone installation and controlled rollout

Drone is a per-user worker for running Cockpit terminals, builds, tests, and
provider-neutral tool calls on another Mac over a trusted LAN. It is not a
GitHub Actions runner and does not use VNC, the rendezvous relay, or a cloud
control plane. Drones remain disabled unless the worker owner explicitly
configures an authorized workspace and operation permissions.

## Prerequisites and installation

- macOS 26 or later and `tmux` on both Macs.
- A checkout of this repository and the pinned Xcode toolchain used for Apple
  builds. Build `DroneTools` or use `apple/bin/build-drone.sh` for a signed
  universal package.
- Direct TCP reachability between the Macs. Internet access is not required for
  LAN execution; provider and build traffic is separate and is never proxied by
  Cockpit.

```bash
apple/bin/install-xcodegen.sh generate --spec apple/project.yml --project apple
xcodebuild build -project apple/made.xcodeproj -scheme DroneTools \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/drone-release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development'

export BLAU_DRONE_WORKSPACE='/absolute/path/to/authorized/checkout'
export BLAU_DRONE_PERMISSIONS='terminal,jobs,files,git'
drone install
drone status
drone doctor
```

`BLAU_DRONE_WORKSPACE` registers the root used by typed workspace operations.
Terminals and process jobs intentionally run with the worker user's authority;
they are not an OS sandbox. Use trusted controllers and grant only the
capabilities required for the controlled rollout. Tool calls additionally need
a worker-issued lease from the local approval/control path. The hardening and
recovery checklist remains a prerequisite for broader rollout. Installation creates a per-user `app.blau.drone` LaunchAgent with
`RunAtLoad`, crash supervision, restart throttling, private state directories,
and two bounded log generations. It does not install a root daemon, cron job,
or unmanaged shell loop.

## Pairing Cockpit

1. Start `droned` on the worker and keep Cockpit on the same LAN.
2. In Cockpit, open **Settings > Drones**. Select a Bonjour candidate or add a
   hostname/IP and port manually. Discovery is only a reachability hint and is
   never authorization.
3. Compare the verification code shown by Cockpit with the code printed by
   `drone pairings` on the worker. Approve on both sides: **Approve** in
   Cockpit and `drone approve <request-id>` on the worker. Use `drone reject`
   or **Reject** for an unexpected identity. A changed key requires a fresh
   approval and never replaces the old pin implicitly.
4. Confirm the worker shows Connected before selecting it in **New Terminal**.
   Offline, unauthorized, incompatible, and busy workers remain visible but
   cannot be selected. Cockpit never substitutes Local or another Drone.

Each Cockpit/controller and worker has independent key material in
Keychain-protected storage. No fleet-wide key exists. Private keys and provider credentials must not be copied between workers or to
Cockpit. Registry and Bonjour metadata are separate from command output. Treat
job output and file/diff results as sensitive: arbitrary executed programs can
print secrets, and bounded output is not automatic redaction.

## Execution and recovery semantics

- Remote tmux sessions survive Cockpit disconnects and application restarts.
  Reattach uses stable terminal IDs and bounded output cursors. Detach is not
  terminate; **Close** is the explicit destructive action.
- One-shot jobs are idempotent per controller/key. Accepted state is committed
  before execution. Retry returns the original job instead of duplicating side
  effects. Interrupted nonterminal jobs fail explicitly as `workerRestarted`;
  they are not rerun automatically.
- Cancellation signals the owned process group, not unrelated user processes.
  Output, history, frame size, connection queues, sessions, jobs, path lengths,
  environments, and retained replay histories are bounded.
- A network partition or unavailable worker produces an actionable offline
  state. It never silently moves a live pane to another destination.
- Transport revocation closes active channels and blocks reconnect until fresh
  approval. Detached terminals may still run processes; detachment is not
  suspension. Verify the running-work policy as part of the #327 checklist;
  do not treat detachment as proof that execution has stopped.
- Worker updates preserve identity, pins, and durable records. Protocol
  incompatibility blocks execution and requires a compatible upgrade rather
  than an unsafe downgrade. `status` and `doctor` distinguish stopped, paired,
  listening, unhealthy, and incompatible states without printing secrets.
- Sleep/wake and Wi-Fi/Ethernet changes cause supervised reconnects with fresh
  session keys. Job and terminal identities do not change. Disk-full or corrupt
  state produces a failed health check; do not delete identity or job records
  to bypass it.

## Security and operations checklist

The automated lanes cover wrong keys, replay, malformed and oversized input,
resource limits, cancellation, restart recovery, idempotency, 15 independent
worker identities, a real PTY, and a real read/edit/build/test/diff cycle.
Before a physical rollout, verify on at least two worker Macs:

- Clean install and upgrade, launch after login/reboot, and crash recovery.
- Destination selection and `hostname`/`pwd` proving execution and cwd are on
  the selected worker, with no Local fallback.
- Interactive shells, full-screen TUIs, Unicode, resize, mouse traffic, slow
  output, and several independent terminals.
- Cockpit quit/relaunch, Drone restart, host reboot, sleep/wake, network
  changes, partitions, slow clients, cancellation, and reattach without
  duplicates or orphaned processes.
- Wrong-key pairing, key change, revocation, stale endpoints, protocol
  mismatch, resource exhaustion, disk pressure, and no-internet LAN operation.
- A 15-Drone registry/connection simulation and isolation of an unhealthy
  worker from the rest of the fleet.

**Current rollout record:** the coordinator verified successful CI for the
#335 implementation at `5d060f3f52dbf2ad9c236aca2e44176ec887f593`
([run 41701765935](https://github.com/joeblau/made/actions/runs/41701765935)).
This is historical automated evidence, not physical fleet acceptance or a test
of subsequent changes. The two-worker-Mac matrix, full-screen-TUI checks,
concurrent fleet load, sleep/wake, disk-pressure recovery, and signing/upgrade
results still need a dated record identifying hardware, OS, revision, commands,
and observed outcomes. Keep broader rollout disabled until these checks and
#326/#327's authorization and recovery gaps are resolved. Explicit workspace and
permission configuration is the current opt-in gate, not a completed security
certification.

## Revocation, backup, rollback, and uninstall

- **Forget and Revoke** in Cockpit removes the local pin and metadata. Revoke a
  controller on the worker when replacing or retiring it. Backup and restore
  identity directories only with equivalent Keychain material and file
  permissions; a files-only backup is not a portable identity backup.
- To roll back an upgrade, stop the service, reinstall a compatible signed
  worker, and restart it. Preserve identity and pairing state when protocol
  versions match. An incompatible version is rejected rather than allowed to
  execute with weaker security.
- `drone uninstall` stops the listener and removes the LaunchAgent and release
  binaries. Identity, pairing state, configuration, and logs intentionally
  remain. Remove those directories manually only after deciding that no
  reinstallation or audit trail is needed.

Provider-neutral tool calls use the same lease-bound filesystem, process, and
Git operations as the durable job engine. A future provider adapter should map
its tools to `DroneToolClient`; it must not copy provider credentials to
Cockpit or another worker. Remote terminal agents use credentials already
present on their selected Drone.

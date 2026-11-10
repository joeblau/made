# Drone execution architecture and wire protocol

Status: protocol baseline plus #335 execution foundation; #326–#328 acceptance remains open

Tracking: [#317](https://github.com/joeblau/made/issues/317),
[#318](https://github.com/joeblau/made/issues/318), and
[#320](https://github.com/joeblau/made/issues/320)

The baseline below specifies the trust and transport contract. #335 added
Drone destinations, launchd service, remote PTYs, durable jobs, and typed tools.
These implementations do not yet establish production rollout readiness. See
the tool contract and implementation limits below and the
[controlled rollout guide](drone-rollout.md).

## Decision and roles

Cockpit is the **controller**. A Drone worker (`drone`, with persistent process
`droned`) owns execution. The controller initiates one direct TCP connection to
a selected worker; that connection owns requests and streams until it fails or
is replaced. A worker accepts multiple authenticated controller connections,
but only one active connection per controller identity may attach a particular
session. Revoking that identity closes all of its connections.

A controller registry must support at least 15 independently paired workers;
the v1 resource budget reserves 32 worker slots. Each worker is paired and
revoked independently. Bonjour `_blau-drone._tcp` advertisements contain only a
random, rotatable service instance identifier and protocol TXT version. Names,
hostnames, TXT records, IP addresses, and reachability are discovery hints,
never identity or authorization.

The worker runs as the checkout-owning user, never root. It alone maps opaque
workspace IDs to registered local roots and owns terminal/job/session state.
Remote sessions survive controller disconnect. Cockpit never treats transport
loss as permission to terminate execution.

## Trust boundary and reusable security pieces

The trust boundary is the authenticated, per-pairing session established after
TCP connect and before the first execution envelope. Discovery, socket
metadata, unauthenticated handshake bytes, decoded JSON, environment values,
stream offsets, and reconnect requests are untrusted. No execution state may
change before pinned-peer authentication and envelope validation succeed.

- Reuse `DeviceIdentity.parsePeerPublicKey`, X25519 key generation, and the
  existing Keychain accessibility policy. Do **not** reuse its singleton local
  identity or singleton peer account. Drone identities and pins need separate
  namespaced stores: `app.blau.drone.identity.controller`,
  `app.blau.drone.identity.worker`, and
  `app.blau.drone.pairing.<role>.<stable-peer-id>`. Stable peer IDs are local
  registry keys, not claimed Bonjour identity. Key changes require a new
  verification ceremony and never replace a pin in place.
- Reuse `PeerSyncAuthenticator.pairingCode` for the two-sided verification
  display. Its single-peer authentication envelope and pin are not Drone
  stores. Pairing UI and revocation must be keyed by the registry peer ID.
- Reuse FrameLink's bounded length-prefix decoder pattern, replay window,
  direction-specific ChaChaPoly protection, and fail-closed record handling.
  `FrameLinkSecureSession` itself remains media-specific and is not a Drone
  session store.
- Reuse the pinned-peer `NoiseIK` handshake, `PacketCodec`, `CryptoCore`, and
  `ReplayWindow` for the protocol proof. The controller is the Noise initiator
  and already pins the worker; the worker requires the recovered controller key
  to equal that pairing's pin. Noise payloads carry bounded version/capability
  hellos inside the authenticated handshake. Fresh ephemeral keys make records
  from prior connections invalid.

Production code must not silently fall back to an unpinned key, a fleet-wide
key, plaintext TCP, or relay-provided identity. Discovery/UI registry policy is
#321 work.

## Pairing and LAN transport

`DroneIdentityStore` and `DronePairingStore` keep private identities, approved
pins, and the bounded peer-ID index in the existing Keychain storage with
`AfterFirstUnlockThisDeviceOnly` accessibility. Controller and worker accounts
are separate even when they share a process. A controller store supports 32
independent workers; no identity or session key is shared between pairings.
Approval compares the expected old pin, so an unknown key cannot replace an
existing key and a changed key requires an explicit replacement decision.
Rejecting a request leaves the old pin untouched. Duplicate keys under distinct
local peer IDs are rejected.

Pairing starts only after a direct TCP connection. Each side sends a bounded
announcement containing a public key and fresh random nonce, then displays the
same `PeerSyncAuthenticator.pairingCode`. The local peer ID and any discovery
label are not inputs to identity or authorization. Only after approval on the
appropriate side does the controller start pinned Noise IK on that connection.
The worker holds at most one bounded Noise message while its approval is
pending. Rejection, timeout, malformed announcements, or a second pre-approval
record closes the connection. Pairing announcements cannot carry execution
envelopes.

`DroneLANTransport` owns the production `NWConnection`/`NWListener` path and
exposes connection IDs, local peer IDs, validated envelopes, approval requests,
and disconnect events to later lifecycle supervisors. Ordinary reconnects load
the per-peer pin and derive fresh Noise session keys. Revocation deletes the
pin and immediately cancels every active connection for that local peer ID;
normal reconnect remains blocked until another approval ceremony. Transport
disconnects do not mutate `DroneSessionID`, `DroneJobID`, or terminal state.

The listener enforces the eight-connection budget before authentication, an
8-second handshake deadline, five-second heartbeats, and a 15-second valid-record
timeout. Optional Bonjour publication accepts only a random/rotatable service
instance identifier and publishes the protocol version TXT value. It never
publishes names, pins, identity keys, registry IDs, or session material. No
transport diagnostics contain keys or payloads.

## Version and capability negotiation

The Noise initiator payload is a `DroneHello` containing at most eight
`UInt16` versions and 32 capability strings (each at most 64 UTF-8 bytes). The
worker selects the highest mutually supported version and returns it with the
intersection of capabilities. No common version fails the handshake. Unknown
capabilities are ignored; unknown message kinds or an unsupported envelope
version fail validation and close the connection after an authenticated
protocol error when one can be sent.

Version 1 is the only version defined here. New optional capabilities and new
message kinds require a negotiated capability; changing the meaning or retry
semantics of an existing kind requires a protocol major-version bump.
Receivers may ignore unknown JSON object fields but must enforce all known
field bounds. JSON uses UTF-8, and canonical encoding uses sorted keys. Numeric
wire prefixes and secure-packet headers are big-endian.

The outer TCP format is:

```
UInt32 payloadLength || payload
```

A handshake payload is one bounded Noise message. An application payload is the
existing version/type/counter ChaChaPoly packet. Its `reliableControl` plaintext
is one `DroneEnvelope`. Zero, over-budget, truncated-after-disconnect, unknown
packet type, bad authentication tag, and replayed records are rejected without
allocating attacker-selected buffers.

## v1 identifiers and schemas

`DroneSessionID` identifies a persistent remote terminal session and is also
the terminal ID exposed to Cockpit. `DroneJobID` independently identifies a
typed job; a later job API must not overload terminal IDs. Request IDs are
UUIDs used for correlation. Create requests also carry a 16–128 byte ASCII
idempotency key, unique within one controller/worker pairing. Session/job IDs
are worker-generated, never controller-selected paths or process IDs.

Every envelope contains `version`, `kind`, optional `requestID`, optional
`sessionID`, optional `idempotencyKey`, and a typed `body`. The implemented
Swift schema is `DroneEnvelope`; the required shape is:

| Kind | Body | Required correlation/state |
| --- | --- | --- |
| `create` | workspace ID, allowed environment, columns, rows | request + idempotency key; no session yet |
| `created` | empty | original request + assigned session |
| `attach` | last received output sequence/byte offset | request + existing session |
| `attached` | empty | attach request + session |
| `input` | bounded bytes | request + attached session |
| `resize` | columns, rows | request + attached session |
| `output` | sequence, byte offset, bytes, final flag | session stream; no request |
| `detach` / `detached` | empty | request + session; execution continues |
| `close` / `closed` | empty | request + session; explicitly destructive |
| `cancel` / `cancelled` | empty | request + session; process-group cancellation, session retained |
| `reconnect` / `reconnected` | resume sequence/offset | request + detached session |
| `resync` / `ack` | empty | request + session; reset replay to a fresh visible snapshot |
| `ack` | empty | accepted input/resize/resync request + session |
| `heartbeat` | empty | authenticated connection liveness only |
| `error` | stable error code and retryable flag | related request/session when available |

`DroneProtocolCodec` is the authority for field requirements. `DroneWire` and
`DroneSecureChannel` enforce bounds before JSON decoding or state mutation.
The later filesystem, Git, process, and job APIs must extend this envelope and
negotiation model rather than create an unversioned side channel.

## Lifecycle and state transitions

Creation starts detached. Attach and reconnect make a live session attached;
input and resize require attachment. Output continues to be buffered while
detached. Network loss performs the same non-destructive transition as detach.

```
create ──▶ detached ──attach/reconnect──▶ attached
             ▲  │                           │  │
             │  └────── detach ─────────────┘  │
             │                                 │ disconnect/detach
             └─────────────────────────────────┘
                │                              │
                └──────── close ───────────────┴──▶ closed

cancel: attached/detached ──▶ same state (cancel current process group)
close: closed ──▶ closed (idempotent response; never recreates the session)
```

`DroneSessionStateMachine` rejects input/resize on detached or closed sessions,
attach/reconnect after close, and cancel after close. Detach and close retries
are safe responses, not new execution requests. Detach leaves tmux/job state
and reconnect queues intact. Close explicitly destroys the selected session
after the worker has authenticated and authorized it.

Attach/reconnect resumes after the supplied acknowledged stream position. The
worker replays bounded retained output in order, then live output. A position
older than retained scrollback returns a non-retryable `outputGap`; the client
must explicitly resynchronize rather than silently lose bytes. Stream sequence
numbers and byte offsets are per session, not per TCP connection.

## Ambiguous disconnect and idempotency

The worker commits create state and its response under the idempotency key
**before** sending `created`. A retry on a new authenticated connection with
the same key and an equivalent validated request returns the stored response; it does
not invoke tmux, spawn a process, or allocate another session/job. Reusing a
key with a different request is `idempotencyConflict` and is not retryable.
Entries live for 24 hours and the table is bounded at 1,024 entries per
pairing. An unexpired full table rejects new creates; it must not evict entries
and risk duplicate execution. Later durable job storage (#322) must persist
this decision atomically with job creation.

TCP retransmission and replay-window rejection are not execution idempotency:
both layers are required. Requests other than create either are naturally
idempotent state reads/transitions or carry request IDs so implementations can
suppress duplicate side effects. Input is not blindly retried after an
ambiguous send; Cockpit must reattach and reconcile terminal state first.

Cancellation targets the current job/process group owned by the session. It is
not SIGHUP to only the shell's immediate child, not detach, and not close.
Implementations must create an isolated process group, signal the group,
escalate after a bounded grace period, and authorize that the session belongs
to the authenticated pairing.

## Protocol resource and authorization requirements

These are worker/controller protocol requirements, not UI hints:

| Resource | v1 limit and behavior |
| --- | --- |
| Independently paired workers | 32 registry slots per controller (minimum product requirement: 15) |
| Secure TCP record | 1 MiB including packet header/tag; larger prefix closes connection |
| Handshake payload | 16 KiB; bounded before Noise/JSON processing |
| Output chunk | 64 KiB; larger chunks rejected, not split by the receiver |
| Terminal scrollback | 8 MiB per session; bounded replay with explicit gaps |
| Detached reconnect queue | 1 MiB and 256 records per session; stop reads on overflow and emit `backpressure` |
| Worker sessions / concurrent jobs | 64 live sessions and 32 running jobs; excess create returns `resourceLimit` |
| Connections | 8 per worker and one active attachment per session; excess/surplus connections rejected |
| Idempotency records | 1,024 per pairing, 24-hour TTL; fail new creates when full |
| Heartbeats | every 5 seconds; no valid record for 15 seconds closes transport only |
| Handshake / request deadlines | 8 seconds / 30 seconds; deadlines never terminate detached execution |
| Environment | at most 32 entries; 64-byte names and 4 KiB values |

Only `HOME`, `LANG`, `LC_ALL`, `PATH`, `TERM`, `COLORTERM`, and `TMPDIR` may be
requested. The worker may further restrict or replace values. Provider tokens,
Keychain items, SSH agents, arbitrary `*_KEY`, `*_TOKEN`, and `*_SECRET` values
are never inherited or forwarded. A future secret API must use worker-local,
short-lived references with explicit user approval; secrets must not appear in
frames, logs, diagnostics, idempotency records, or persisted request JSON.

Backpressure applies at the worker PTY/job reader. A slow attached client must
not grow memory without bound: coalesce only where semantics permit, otherwise
pause process reads and apply OS pipe backpressure. Detached output uses the
bounded queue and scrollback; overflow is reported as a gap/backpressure
condition. Control, cancel, and close frames are never starved behind output.

## Rejected alternatives

- **Multipeer Connectivity:** its practical eight-peer session constraint and
  peer-to-peer lifecycle do not fit at least 15 independently owned workers or
  persistent worker/service reconnect semantics. Its encryption is also not a
  substitute for per-pairing identity checks.
- **VNC:** it is a display/input protocol, not typed execution, idempotent job
  ownership, structured cancellation, or resumable output. Existing VNC
  connections remain a separate product concept and store.
- **Rendezvous relay:** it adds a cloud availability/control-path dependency to
  an owner LAN and cannot authorize a worker. Direct TCP gives explicit
  connection ownership and backpressure without relaying terminal contents.
  A future relay would need the same end-to-end pinned session and is not v1.
- **Trusting Bonjour or transport encryption alone:** either permits identity
  substitution. Explicit pairing and mutual possession proofs are mandatory.

## Gate proof and downstream boundaries

Run `apple/bin/test-drone-protocol.sh`. It compiles the production value-layer
schemas/security code with a test-only executable, starts a loopback worker
process, and launches a separate controller process. The proof covers mutual
pinned authentication, wrong-key rejection, malformed lengths, replayed secure
records, bounded create/attach/input/output/resize/cancel/detach/close,
same-key create retry after replay and ambiguous disconnect, and 15 independent
worker approvals with explicit rotation/revocation. No command, terminal,
remote workspace, or job is executed.

`apple/Tests/SharedTests/DroneProtocolTests.swift` covers schema/state/limits
and the in-memory security state machines. `DronePairingTests.swift` adds
namespaced stores, changed-key rules, multi-peer authentication, cross-peer and
prior-session record rejection, and real loopback pairing/reconnect/revocation.
Physical fleet behavior, durable recovery, pairing UI, launchd supervision, PTY
execution, and production Drone destinations remain in their respective
#319–#328 issues and are not claimed by this gate.

## Provider-neutral tool contract and current implementation limits

`DroneToolClient` accepts a `DroneToolTransport` and a `DroneToolLease` binding
controller, Drone, job, workspace, lease ID, and expiry (Unix-epoch seconds).
The intended trust boundary requires a worker-approved lease, validated against
the authenticated channel and the approved job/workspace. A caller-provided
lease is not evidence of authorization.

A future Claude or other provider adapter should map tools as follows:

| Provider operation | Typed operation | Adapter responsibility |
| --- | --- | --- |
| Read a file | `read` / `toolRead` | Relative path, bounded bytes, handle truncation |
| Replace text | `edit` / `toolEdit` | Unique old bytes, optional SHA-256 precondition, stable retry key |
| Build or test | `run` / `toolRun` | Executable and argument vector, timeout and output budget |
| Inspect changes | `diff` / `toolDiff` | Relative paths, bounded diff output |
| Resume output | `toolAttach` | Original request ID, next sequence and per-stream offsets |
| Cancel | `cancel` / `toolCancel` | Original operation request ID, retain job outcome |

`DroneAgentDriver` demonstrates read/edit/build/test/diff orchestration without
an interactive terminal. Adapters must preserve idempotency keys across retries,
report ambiguous outcomes instead of starting replacement work, and keep source,
stdout, stderr, and diffs out of diagnostics. `diagnosticSummary` reports counts
and statuses only. Provider authentication remains with the agent's host;
remote terminal agents use credentials already on their Drone. This interface
does not authorize copying credentials to Cockpit or another worker.

Worker-local approval issues non-tool permission grants and bounded tool leases
to an authenticated controller. `BLAU_DRONE_PERMISSIONS` limits what the owner
may grant; it does not implicitly authorize paired controllers. `drone grant`
sets a controller's non-tool permissions, while `drone grant-tools` issues an
independent lease tied to the worker identity and configured workspace. Both
kinds of grant are held in memory and expire on worker restart. Older clients
that construct their own leases are rejected, and there is no remote first-use
registration. The lease job ID identifies the approved orchestration session;
individual operations retain their own durable job records. A conditional edit
is one durable typed job: its SHA/precondition check, unique-byte replacement,
and atomic file replacement run under the same per-workspace typed-mutation
lock. It is not a read job followed by an independently racing write job.

Tool correlation is persisted with the job before execution and keyed by the
authenticated controller and original request ID, not by lease ID, lease job ID,
or expiry. After a restart, the owner must issue a fresh grant for the same
controller, Drone, and workspace; the operation's original files/jobs/Git
permission is checked again before retry, cancellation, or replay. Retained
terminal results and output/cursors replay from the durable job record, and
same-key retries return that record without executing again. Jobs interrupted
before a terminal record fail explicitly as `workerRestarted`; retained-history
gaps remain `outputGap` rather than silently dropping output. In-memory output
history is only a replay fast path, not the durable authority.
Finished job records older than the 24-hour idempotency lifetime are deleted
for every controller: at startup they are removed rather than reloaded, and a
periodic purge removes them while the worker runs, whether or not that
controller creates more jobs. Revoking a controller deletes its finished
records at once; its in-flight records are deleted by the next purge after
they finish. Only records that exist at revocation are affected: a controller
approved again under the same peer ID keeps its new records for the full
idempotency lifetime.
A process job runs as its own process group (#441). The record is marked
`launching` before the leader is spawned, and the leader starts suspended until
its group ID and start time are persisted. Every exit path kills the group and
waits, bounded, for it to disappear before the job is recorded finished. On
restart, recovery kills a matching leftover group before finalizing the job.
When a group cannot be confirmed gone (a member owned by another user, a
member still running after SIGKILL, a record that does not match the live
process table, or a `launching` record whose group was never persisted), the
job is still finalized but carries a `processGroupUnverified` notice, worker
storage health reports unhealthy, and the record is exempt from automatic
deletion until a later recovery confirms the group gone. Descendants that call
`setsid`/`setpgid` to leave the job's group are outside this guarantee.

Authorization, resource-governance and recovery acceptance remains tracked in
#326/#327. Keep detailed security findings and remediation evidence in private
review as described in [SECURITY.md](../SECURITY.md). The fake tool proof does
not replace production integration or physical rollout checks.

Run `apple/bin/test-drone-tools.sh` for the typed client/fake-engine proof and
`apple/bin/test-drone-worker.sh --tool-replay-authorization` for the encrypted
production controller-grant and attach-route ownership proofs without creating
a terminal. The full worker proof exercises a real terminal and agent cycle.
None substitutes for the physical matrix or adverse recovery checks in the
rollout guide.

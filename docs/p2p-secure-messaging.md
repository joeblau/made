# Peer-to-peer secure messaging (issue #51)

End-to-end encrypted, peer-to-peer messaging between two paired devices —
Copilot (iOS, the **initiator**) and Pilot (macOS, the **responder**). The two
devices discover each other's public UDP endpoint through a tiny Cloudflare
rendezvous Worker, punch a hole through their NATs, run a simplified Noise IK
handshake to establish directional transport keys, and then exchange
ChaChaPoly-sealed packets directly. The Worker only ever sees routing metadata
(a public key, an observed IP, a UDP port) — never plaintext, session keys, or
the handshake secrets.

This document describes what is actually implemented, file by file:

| Concern | Where it lives |
| --- | --- |
| Long-term identity key (Keychain) | `apple/Sources/Shared/SecureChannel/DeviceIdentity.swift` |
| Crypto primitives (DH, HKDF, transcript) | `apple/Sources/Shared/SecureChannel/CryptoCore.swift` |
| Noise IK handshake | `apple/Sources/Shared/SecureChannel/NoiseIKHandshake.swift` |
| Wire packet format + AEAD | `apple/Sources/Shared/SecureChannel/PacketCodec.swift` |
| Replay protection | `apple/Sources/Shared/SecureChannel/ReplayWindow.swift` |
| Reliability (ack/retransmit) | `apple/Sources/Shared/SecureChannel/ReliableMessenger.swift` |
| Connection lifecycle | `apple/Sources/Shared/SecureChannel/ConnectionState.swift` |
| Rendezvous HTTP client | `apple/Sources/Shared/SecureChannel/SignalingClient.swift` |
| Shared role-parameterized transport | `apple/Sources/Shared/SecureChannel/SecureChannelCore.swift` |
| Deadlines + duplicate-msg1 recovery | `apple/Sources/Shared/SecureChannel/SecureChannelDeadline.swift` |
| Pairing / key-sharing UI | `apple/Sources/Shared/SettingsView.swift`, `Sources/{Copilot,Pilot}/SecureMessaging/SecureMessagingView.swift` |
| Rendezvous Worker | `workers/rendezvous/src/{index.ts,signaling.ts}`, `wrangler.jsonc` |

---

## 1. The simplified Noise IK handshake

The handshake is a hand-rolled Noise-IK-style exchange built **only** on
CryptoKit primitives (`Curve25519`, `HKDF<SHA256>`, `ChaChaPoly`, `SHA256`). It
is not a full Noise Protocol Framework implementation; it borrows IK's message
pattern and key-mixing structure. The protocol label that seeds every transcript
and chaining key is:

```
Noise_IK_25519_ChaChaPoly_SHA256/blau-p2p-v1
```

**"IK"** means: the **I**nitiator already **K**nows the responder's static
public key (`s_R`) before it starts — the user enters it once, out of band,
during pairing — and the initiator transmits its own static public key (`s_I`)
*encrypted* inside the first handshake message. By the end both sides hold the
same pair of directional transport keys.

Every device's static key is a long-term `Curve25519.KeyAgreement` key pair held
in the Keychain (`DeviceIdentity`). Ephemeral keys (`e_I`, `e_R`) are fresh per
handshake, providing forward secrecy.

### Two building blocks

**Transcript hash** (`CryptoCore.Transcript`). A running SHA-256 over everything
both sides observe, seeded with the protocol label:

```
h₀ = SHA256(protocolLabel)
mix(data): h = SHA256(h ‖ data)
```

Public ephemerals and every AEAD ciphertext are `mix`-ed in. Because the
transcript is folded into the HKDF `info` at every step, any divergence
(tampering, a wrong key) makes the derived AEAD keys differ and the next
`open` fails.

**MixKey** (`CryptoCore.mixKey`). The Noise `MixKey` step — fold a DH output into
the running chaining key and split off a one-time AEAD message key:

```
okm        = HKDF-SHA256(IKM = dh, salt = ck, info = "blau-p2p mixkey" ‖ h, len = 64)
ck'        = okm[0..32]      // next chaining key
messageKey = okm[32..64]     // one-time ChaChaPoly key for this step
```

Handshake AEAD seals use a fixed all-zero 12-byte nonce. This is safe precisely
because each `messageKey` is unique per step (HKDF output is unique per
handshake), so a (key, nonce) pair never repeats. The handshake AEAD helpers
(`NoiseIK.sealRaw`/`openRaw`) produce/consume `ciphertext ‖ tag(16)` with an
empty AAD.

### Message-by-message

```
msg1  I → R:   e_I (clear, 32B)  ‖  AEAD(s_I) (32+16B)  ‖  AEAD(payload)
msg2  R → I:   e_R (clear, 32B)  ‖  AEAD(payload)
```

**msg1 — `NoiseIK.Initiator.start`:**

1. `h.mix(s_R)` — the pre-known responder static key is mixed into the
   transcript *first*, so the transcript commits to the responder's identity
   from the very start (channel binding to "who I think I'm talking to").
2. Generate `e_I`; append `e_I.pub` in the clear; `h.mix(e_I.pub)`.
3. `es = DH(e_I, s_R)` → `mixKey` → message key k1. `sealedStatic = AEAD_k1(s_I.pub)`.
   Append it; `h.mix(sealedStatic)`.
4. `ss = DH(s_I, s_R)` → `mixKey` → message key k2. `sealedPayload = AEAD_k2(payload)`.
   Append it; `h.mix(sealedPayload)`.

**msg1 receive — `NoiseIK.Responder.receive`:**

1. `h.mix(s_R)` (its own static), then read `e_I` and `h.mix(e_I)`.
2. `es = DH(s_R, e_I)` (equals the initiator's `DH(e_I, s_R)`) → k1 → open the
   sealed static → recovers `s_I`.
3. **Authorization gate** (see §1.1) runs here, before any further work.
4. `ss = DH(s_R, s_I)` → k2 → open the sealed payload.

**msg2 — `NoiseIK.Responder.respond`:**

1. Generate `e_R`; append `e_R.pub` clear; `h.mix(e_R.pub)`.
2. `ee = DH(e_R, e_I)` → `mixKey`.
3. `se = DH(e_R, s_I)` → `mixKey` → message key → `AEAD(payload)`; `h.mix(sealed)`.
4. Split transport keys (below).

**msg2 receive — `NoiseIK.Initiator.receive`:**

1. Read `e_R`, `h.mix(e_R)`.
2. `ee = DH(e_I, e_R)`, then `se = DH(s_I, e_R)` — the mirror of the responder's
   `ee`/`se` — then open the sealed payload.
3. Split transport keys identically.

### Key derivation — the final split

`CryptoCore.splitTransport` turns the finished chaining key into two directional
transport keys and two 96-bit base nonces:

```
info = "blau-p2p split v1" ‖ h ‖ s_I.pub ‖ s_R.pub
okm  = HKDF-SHA256(IKM = ck, salt = "", info, len = 88)

kI2R = okm[0..32]     // initiator → responder key
kR2I = okm[32..64]    // responder → initiator key
nI2R = okm[64..76]    // initiator → responder base nonce (12B)
nR2I = okm[76..88]    // responder → initiator base nonce (12B)
```

Both directions get an independent key, so traffic each way is cryptographically
separated. Both static public keys **and** the full transcript are bound into
`info`.

### What authenticates what

- **The responder is authenticated to the initiator.** Only the holder of `s_R`
  can complete `es = DH(·, s_R)` and `ss = DH(·, s_R)`; a wrong `s_R` (an
  attacker who is not the device the user paired with) yields different keys and
  the initiator's msg2 `open` fails (`HandshakeError.decryptFailed`). The
  transcript is also pre-committed to `s_R`.
- **The initiator's possession of `s_I` is proven to the responder.** `s_I` is
  delivered sealed under a key derived from `es` and recovered only if the DH
  matches.
- **But raw IK cannot tell the responder *which* initiator it is talking to.**
  Raw IK proves "some party holding *a* static key" — an unknown-key-share /
  spoofed-initiator gap. So `Responder.receive` requires the expected initiator
  public key and the production responder (`SecureChannelResponder`) passes its
  persisted pin:

  ```swift
  expectedInitiator: peerStatic
  ```

  If the recovered `s_I` is not the pinned peer key, it throws
  `HandshakeError.unauthorizedPeer` **before** any transport key is released.
  There is no accept-all production overload, so a missing trusted-peer
  configuration is a compile-time error rather than a silent authentication
  bypass.

### Hardening notes

- `CryptoCore.dh` rejects an all-zero X25519 shared secret in constant time
  (`InvalidPublicKeyError`), defeating low-order-point / contributory-behaviour
  attacks where a peer-chosen ephemeral cancels that DH's contribution.
- Malformed messages (too short, bad key length) throw
  `HandshakeError.malformedMessage` rather than crashing.

---

## 2. The wire packet format

Defined in `PacketCodec`. After the handshake, every transport packet on the
wire is:

```
┌─────────┬──────┬───────────────────┬────────────┬─────────┐
│ version │ type │ counter (UInt64 BE)│ ciphertext │ tag(16) │
│  1 B    │ 1 B  │       8 B          │   N B      │  16 B   │
└─────────┴──────┴───────────────────┴────────────┴─────────┘
└──────────── 10-byte header (AAD) ──┘
```

All multi-byte integers are big-endian. `version` is currently `0x01`; a packet
with any other version is rejected with `CodecError.badVersion`.

### Packet types (`PacketCodec.PacketType`)

| Value | Name | Meaning | Reliable? |
| --- | --- | --- | --- |
| `0x01` | `handshake` | Noise IK handshake message (msg1 / msg2). Carried with a header for framing consistency but **not** ChaChaPoly-sealed — it is the Noise-internal AEAD instead. `counter` is `0`. | n/a |
| `0x02` | `reliableControl` | JSON UTF-8 control message, ACK-tracked + retransmitted. | yes |
| `0x03` | `ack` | Acknowledges a reliable message; body is the 8-byte big-endian `msgID`. | n/a |
| `0x04` | `bestEffortBlob` | Fire-and-forget blob / media chunk. Never tracked. | no |

An unknown type byte is rejected with `CodecError.unknownType`.

### Nonce derivation

The per-packet ChaChaPoly nonce is the direction's 12-byte base nonce XORed with
the packet counter in its low 8 bytes (`PacketCodec.nonce`):

```
nonce[0..4]  = baseNonce[0..4]
nonce[4..12] = baseNonce[4..12] XOR  bigEndian(counter)
```

`counter` is a per-direction monotonic sequence number starting at `0`
(`sendCounter` in each transport). Because each direction has its own key *and*
its own base nonce, and the counter is unique per direction, the (key, nonce)
pair is unique for the lifetime of the session — the AEAD safety requirement.

### AAD (authenticated, not encrypted)

The full 10-byte header (`version ‖ type ‖ counter`) is passed to ChaChaPoly as
`authenticating:` data. It travels in the clear but is covered by the tag, so a
receiver detects any tampering with the version, type, or counter
(`CodecError.openFailed`). `PacketCodec.open` re-derives the header from the
parsed fields and feeds it back as AAD, so a flipped type or counter changes the
AAD and the open fails.

### Seal / open

- `seal(type, counter, plaintext, key, baseNonce)` → `header ‖ ciphertext ‖ tag`.
- `parse(packet)` reads the clear header without decrypting (`SealedPacket`).
- `open(packet, key, baseNonce)` re-derives the header + nonce, verifies the tag
  against the header-as-AAD, and returns `(type, counter, plaintext)` or throws
  `CodecError.openFailed`.

---

## 3. Reliability vs best-effort

Two delivery classes share the channel.

### Reliable (`reliableControl` 0x02, ACK'd via `ack` 0x03)

`ReliableMessenger` is the pure, socket-free bookkeeping layer; the transports
plug it into a real `NWConnection` + timer.

- `enqueue(payload, now)` assigns a monotonically increasing `msgID` (starting at
  1) and returns it. The first send is due immediately.
- The transports embed the `msgID` inside the JSON envelope
  (`{ "msgID": …, "text": … }`). Because the ID must live *inside* the payload,
  the sender reserves the ID via `enqueue` and then calls `replacePayload(id:,
  payload:)` with the finished JSON, preserving the ID and retransmit schedule.
- `due(now)` returns a `SendDecision`:
  - `.send([Message])` for messages whose timer fired — they are rescheduled
    with **exponential backoff** (`baseBackoff = 0.25s`, doubling, capped at
    `maxBackoff = 8s`);
  - `.waitUntil(t)` when nothing is due yet;
  - `.idle` when nothing is outstanding (the retransmit loop then stops).
- After `maxAttempts = 8` attempts without an ACK, the message is **abandoned**
  (moved to `abandoned`) so a dead peer can't keep it queued forever.
- `acknowledge(id)` clears an in-flight message when its ACK arrives.

The receiver side acknowledges **every** reliable message it sees (so the sender
stops retransmitting) but only delivers each `msgID` once. `AckTracker.receive(id)`
returns `true` the first time (deliver to the app) and `false` for duplicates
from retransmits (still re-ACK, but don't re-deliver). See `dispatch(...)` in
both transports: duplicate texts are logged as "duplicate … (re-ACK'd)".

### Best-effort (`bestEffortBlob` 0x04)

Fire-and-forget. Sent once via `transmit(type: .bestEffortBlob, …)`, never
enqueued, never ACK'd, never retransmitted. Intended for media chunks / test
blobs where a dropped packet is cheaper than a stall.

---

## 4. Replay protection

`ReplayWindow` is a per-direction sliding window over the monotonic packet
counter, modelled on RFC 1982 serial arithmetic and the RFC 6479 / IPsec-ESP
scheme. Default window size is **1024** counters and remains correct across a
`UInt64.max → 0` wrap.

It tracks the highest counter accepted and the set of accepted counters inside
`[highest − size + 1, highest]`. `accept(counter)` returns:

- `true` and advances the window for a fresh counter **above** the window;
- `false` (and changes nothing) if the counter is **at or below the window
  bottom** (too old) or its slot is **already set** (a replay).

Each transport holds one `ReplayWindow` for its *receive* direction and only
runs `replay.accept(opened.counter)` **after** a successful `PacketCodec.open`,
so the counter is authenticated before it is trusted. Rejected packets are
logged ("Dropped replayed packet (counter N)") and dropped. Note that the
handshake packets (type 0x01, counter 0) are handled before the transport-key
path and are not subject to the replay window.

---

## 5. Connection lifecycle

`ConnectionState` / `ConnectionStateMachine` enforce the legal walk:

```
signaling ─▶ holePunching ─▶ handshake ─▶ connected
     │             │             │            │
     └──────── any stage may ────┴────────────┴──▶ failed (absorbing)
```

`transition(to:)` rejects illegal edges (e.g. signaling → connected without a
handshake) and `failed` is absorbing — the first failure reason is preserved.
One `SecureChannelCore` drives both roles through signaling, hole-punching,
handshake, receive, ACK/replay, diagnostics, and cleanup. The compatibility
names `SecureChannelTransport` and `SecureChannelResponder` are type aliases;
only handshake direction and send/receive key selection vary by role.

Socket readiness and the handshake each have an 8-second monotonic deadline.
Cancellation cancels the underlying `NWConnection` and resolves the waiting
continuation exactly once. The initiator retransmits the exact same msg1 every
500 ms until msg2 arrives or the deadline expires. The responder caches msg2
only for the exact authenticated msg1 that established the session, allowing a
lost msg2 to recover without accepting a different or unauthenticated msg1.
Timeout errors are surfaced as retryable failures.

---

## 6. Deploying the Cloudflare rendezvous Worker

The Worker (`workers/rendezvous`) provides two unrelated services on one
deployment:

- **`ROOMS`** Durable Object — the existing Plotter WebSocket relay
  (`/room/<code>`).
- **`SIGNALS`** Durable Object — the issue-#51 signaling server: one instance
  per pairing **token**, recording up to two peers' `{ publicKey, ip, port }` so
  the devices can learn each other's UDP endpoint and hole-punch.
  - `POST /register` `{ token, publicKey, port }` → records the peer (IP is
    taken from `CF-Connecting-IP`, never trusted from the body) and returns the
    *other* peer if present, else `204`. `409` if the token already has two
    other distinct keys.
  - `POST /get-peer` `{ token, publicKey }` → the *other* peer's endpoint, or
    `204` if it hasn't registered yet. Pairing material never appears in a URL.
  - Registrations carry a 5-minute TTL and are swept by a Durable Object alarm.
  - `GET /healthz` → `ok`.

Both Durable Object classes are SQLite-backed (declared in the `migrations`
block of `wrangler.jsonc`) so the Worker runs on the Workers free plan.

Binding types are generated, not handwritten: `worker-configuration.d.ts` is
produced from `wrangler.jsonc` by the lockfile-pinned Wrangler and is the only
`Env` declaration used by the Worker and its tests (the Worker narrows only
`ENVIRONMENT`). After adding, renaming, or removing a binding, run
`bun run --cwd workers/rendezvous types` and commit the result. The package's
`check` script regenerates into a scratch file and fails on any difference
without rewriting the committed file. Generation also reads a local
`.dev.vars`; the Worker needs no secrets, so keep that file absent.

### Steps (uses [wrangler](https://developers.cloudflare.com/workers/wrangler/))

```bash
# 1. Install the frozen root workspace (from the repository root).
bun install --frozen-lockfile

# 2. Authenticate wrangler with your Cloudflare account (one-time).
bun run --cwd workers/rendezvous wrangler login

# 3. Sanity-check the build + bindings without uploading.
bun run --cwd workers/rendezvous deploy --dry-run

# 4. (Optional) Run locally against Miniflare.
bun run --cwd workers/rendezvous dev

# 5. Deploy to production.
bun run --cwd workers/rendezvous deploy
```

`wrangler.jsonc` pins the production route to the custom domain
`rendezvous.blau.app`, which is the default `baseURL` the apps' `SignalingClient`
uses. Production disables `workers.dev` and preview URLs. A custom endpoint
must be HTTPS; plain HTTP is accepted only for `localhost`/loopback after the
explicit development toggle is enabled. An invalid value never silently falls
back to production.

> The Worker is deployed via wrangler, **not** the repo's GitHub Pages workflow
> (which only publishes the `web/` Astro landing page).

---

## 7. Pairing: the one-time public-key + token exchange

The handshake authenticates against a **manually pinned** static key, so pairing
is a one-time, out-of-band exchange of two things:

1. **Each device's long-term public key** — base64 of a 32-byte X25519 key.
2. **A shared pairing token** — at least 192 random bits, encoded as base64url,
   that routes both devices to the same `SIGNALS` Durable Object instance. It
   is *routing only*; it is never mixed into the handshake and grants no
   cryptographic authority.

### Where the keys come from

Each device generates its identity key on first launch and stores the private
key in the Keychain (`DeviceIdentity.loadOrCreate`, accessible
`AfterFirstUnlockThisDeviceOnly`, this-device-only). The base64 public key is
surfaced in **Settings → Identity & Keys** (`SettingsView.swift`):

- on iOS (Copilot), a `ShareLink` ("Share device key…");
- on macOS (Pilot), a "Copy device key" button (copies to `NSPasteboard`).

### Exchange procedure

1. **On each device**, open Settings → Identity & Keys and copy/share its
   "Public key" string.
2. **Hand each device the *other* device's key** through any trusted channel you
   already control (AirDrop, a Signal message, reading it aloud, a QR code —
   anything where you can be sure it wasn't substituted). This out-of-band step
   is what makes the whole channel trustworthy: it pins identity.
3. **Generate a secure pairing token** in either app and transfer the same
   token to the other device through the trusted channel. Human-chosen and
   low-entropy tokens are rejected.
4. Enter the peer's pasted public key into the secure-messaging screen
   (`SecureMessagingView`). It is parsed by
   `DeviceIdentity.parsePeerPublicKey` — base64, exactly 32 bytes, valid X25519,
   or it is rejected.
5. Connect. Copilot (initiator) opens msg1 against the entered peer key; Pilot
   (responder) authorizes the recovered initiator key against the peer key you
   entered there. If either side pasted the wrong key, the handshake aborts
   (`decryptFailed` on the initiator, `unauthorizedPeer` on the responder) and
   **no session keys are established**.

Because identity is pinned out of band, the rendezvous Worker is fully
untrusted: even a malicious or compromised Worker can only mis-route or deny —
it can never impersonate a peer or read traffic, since it never holds a private
key or the session keys.

The pairing token and peer public key are stored in the Keychain with
`AfterFirstUnlockThisDeviceOnly` accessibility. On first load, the app migrates
the old `p2p.token` and `p2p.peerPublicKey` UserDefaults values and deletes the
plaintext copies.

---

## 8. Tests

The value layer is exercised by `apple/Tests/SharedTests/SecureChannelTests.swift`
(run via the `SharedTests` scheme): full handshake derives identical directional
keys; a wrong responder static key or mismatched static key fails; tampered
header / ciphertext fail to open; nonce XOR uniqueness; replay window accept /
reject, wraparound, and 10,000-message memory bounds; reliable messenger ack /
backoff / bounded abandonment history; ack-tracker dedup; retransmit deadlines;
duplicate-msg1 response caching; and shared-core directional-key parity. The
suite also checks Keychain migration behavior, token generation/validation,
HTTPS enforcement, and POST-only signaling request construction.

Local control-sync and FrameLink pairing are covered separately by
`PeerSyncAuthenticationTests` and `FrameLinkSecurityTests`; see
`device-pairing-and-framelink.md` for those protocols and their revocation flow.

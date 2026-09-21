# Local device pairing and FrameLink security

Pilot accepts remote-control commands and mirrored-screen clients only after an
explicit device pairing. A nearby service name is never an authorization
credential.

## iPhone/iPad → made Device pane

In a Device pane, choose **Share Wirelessly…**. On the same Wi-Fi network, open
**Control Center → Screen Mirroring** on the iPhone or iPad, select the
**made XXXX** name shown in the pane, then enter its four-digit pairing code.
No companion app or Bluetooth pairing is required. USB capture remains available
through **Use USB**. Wireless sharing currently displays video only; the existing
USB recording and screenshot controls are disabled for wireless sessions.

This path uses a separately packaged AirPlay receiver, independent of FrameLink
and control sync. It advertises `_airplay._tcp` and `_raop._tcp` only after the
user starts sharing. Each start creates a new identity and a private temporary
pairing key. The on-screen PIN authorizes access; peer registrations live only
for that receiver process. **Stop**, hiding/closing the pane, or quitting made
ends the receiver. Starting again requires pairing again. Temporary keys are
deleted when the worker finishes; a process crash can leave a private temporary
directory for the OS to clean up.

The receiver runs outside the UI process. Its pipe and H.264 parser have size
limits, and video decoding runs on a dedicated queue. Startup, incomplete
messages, pairing, helper heartbeat and device feedback have separate deadlines.
If a deadline expires, the pane shows a retry action; stopping never waits on
the UI thread for the helper to exit. An idle listener can wait for a device,
and feedback keeps a static mirrored screen connected.

Registration and local-network permission failures show distinct recovery
messages. Build/install steps refresh bundle directory dates so macOS discards
obsolete Bonjour declarations after an update. Alongside unit tests, run
`python3 apple/bin/check-airplay-receiver.py /Applications/made.app` against
the signed installation to check real discovery, pairing startup and shutdown.
This smoke check does not replace physical-device screen-mirroring validation.
It authenticates the displayed PIN with an independent SRP client; the additional
`uv run apple/Tests/AirPlay/pairing_test.py --helper /Applications/made.app/Contents/MacOS/CockpitAirPlayReceiver`
suite checks encrypted key exchange, signature verification, retries and reconnects.

The receiver build pins UxPlay, libplist and OpenSSL by SHA-256, builds both Mac
architectures, and bundles licenses and complete corresponding source. See
[AirPlay receiver build and protocol notes](../apple/Packages/AirPlayReceiver/README.md).

## Copilot ↔ Pilot control sync

`PeerSyncService` advertises a public Curve25519 identity and includes the same
identity in its invitation context. On first contact, both apps show the same
SHA-256 verification code derived from the ordered pair of public keys and
require the user to approve it. Users should compare the codes displayed on
both devices before selecting **Pair**.

The approved peer key is stored in the Keychain. Every Multipeer connection
then performs a fresh, nonce-bound X25519/HMAC possession proof. `isConnected`
remains false and application messages are ignored until both proofs succeed.
Each command is carried in a session-bound authenticated envelope with a
monotonic replay window. Multipeer transport encryption remains required, but
it is not treated as peer authentication.

Only one peer is authorized at a time. A changed public key produces a separate
**Trust New Key** confirmation; a `.deviceKey` message cannot create or replace
the stored pin.

## Pilot ↔ Plotter FrameLink

FrameLink has one supported production transport: the `_blau-frames._tcp`
Bonjour service. The retired UDP and standalone annotation services have been
removed. Annotation commands and screen frames share the same authenticated
TCP connection.

Bonjour metadata contains no identity or other sensitive identifier. Once the
direct TCP connection is open, Pilot and Plotter exchange a public key and a
fresh 32-byte nonce. Unknown or changed keys require the same verification-code
approval described above. The peers then prove possession of their pinned
X25519 keys with a transcript-bound HMAC.

After authentication, every protocol packet is protected with
ChaCha20-Poly1305. Direction-specific keys, nonces, and authenticated associated
data bind the ciphertext to the current handshake transcript, sender identity,
and sequence number. Tampered, replayed, wrong-key, prior-session, plaintext,
and surplus-client traffic is rejected before Pilot sends a frame or accepts an
annotation.

The TCP decoder rejects zero, overflowing, or over-budget length prefixes
immediately. Packet kinds also enforce video-dimension, parameter-set, sample,
JPEG, and annotation ceilings. Diagnostics expose only aggregate invalid/drop
counters, never payload contents.

## Revocation and key rotation

- Plotter can revoke its Pilot pin by long-pressing the connection badge and
  choosing **Forget Paired Pilot**. The active connection is closed immediately
  and the next connection requires approval.
- The transport objects also expose `revokePairing()` for Pilot-side settings
  and administrative flows; it removes the Keychain pin and disconnects the
  authenticated client.
- Regenerating a device identity is a rotation, not an automatic replacement.
  The other device sees a key-change warning and must explicitly approve the
  new verification code. Rejecting it preserves the old pin.
- Uninstalling an app or clearing its Keychain removes its local identity and
  therefore requires a new pairing ceremony.

Pairing state is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
and is never synchronized to another device or written to `UserDefaults`.

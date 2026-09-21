# made AirPlay receiver

This standalone executable adapts UxPlay's libairplay to made's bounded pipe
protocol. It supports native iPhone/iPad Control Center screen mirroring over
the same Wi-Fi network. It currently discards audio and does not implement HLS
or protected video playback. Bluetooth pairing alone does not carry the stream.

The adapter is GPL-3.0-or-later. UxPlay (including libairplay and its bundled
Playfair/llhttp sources), libplist and OpenSSL retain their own notices and
licenses; see each source archive. The executable runs as a separate process
and is not linked into made. No GStreamer runtime is used.

`apple/bin/build-airplay-receiver.sh` pins and verifies every download and builds
both arm64 and x86_64 with Xcode's compiler. It needs macOS, Xcode 26, make,
Perl, curl and tar. Build artifacts are cached under `.build` and excluded from
version control. Xcode's Embed AirPlay Receiver phase signs the result and ships
the complete corresponding source archives, adapter and build recipe in
`made.app/Contents/Resources/AirPlay/Sources`.

To rebuild from the bundled sources, create `apple/Packages/AirPlayReceiver`
and `apple/bin` in a working directory. Put `main.cpp`, `bounds.patch` and
`tests.cpp` in the package, the build
script in `apple/bin`, and the three dependency archives in the package's
`.build/downloads` directory. Run `bash apple/bin/build-airplay-receiver.sh`.
The result is `.build/CockpitAirPlayReceiver`; it can be substituted into a
locally signed copy of made or used with another pipe consumer.

Starting a receiver generates an ephemeral device identity and a private
Ed25519 key in a mode-0700 temporary directory, then requires an on-screen PIN.
Registered peers live only in process memory. Stopping/restarting sharing
forgets trust and deletes the temporary key. The receiver advertises only
while explicitly started in a visible Device pane. Parent death, closed/full
output pipes and cancellation terminate the helper; UI operations never join
its protocol threads.

The local `bounds.patch` limits HTTP headers/URLs to 64 KiB and HTTP bodies and
encrypted video payloads to 8 MiB before allocation. `tests.cpp` exercises the
patched parser during the build. The UI additionally limits pipe messages,
NAL counts, decoder dimensions and pending frames. Device feedback has a
separate deadline from the helper heartbeat, so a stuck device connection
cannot keep the pane showing a frozen frame forever.

Bonjour registration failures are sent as a bounded numeric error message to
the parent before exiting. The UI distinguishes local-network permission denial
from service-registration rejection instead of treating both as an unexplained
closed pipe.

The embedding and local-install scripts refresh the app and Contents directory
dates. Preserving old dates across an update can leave macOS using cached
NSBonjourServices from the previous installation; re-registering the app alone
does not necessarily clear that cache. Packaging tests require the directory
dates to be at least as recent as Info.plist and the receiver executable.

After installing a signed build, run:

```sh
python3 apple/bin/check-airplay-receiver.py /Applications/made.app
```

This checks actual Bonjour discovery for both services, a local pairing request
and successful 20-byte SHA-1 SRP proof using the displayed PIN, private key
permissions, and bounded shutdown. Run it against
the installed app: unsigned development hosts can pass while an installed app
is denied. Full validation also requires mirroring a physical iPhone/iPad into
the Device pane, including disconnect/reconnect and rotation.

The local patch also corrects legacy PIN authentication in the pinned library:
the wire proof is 20 bytes, although the upstream handler expected a 64-byte
buffer. The displayed PIN survives failed-entry retries and is consumed after
authenticated key exchange. Trust is registered at that exchange, before media
SETUP, so a client may reconnect for pair verification. Malformed or out-of-order
authentication fails without dereferencing discarded session state, and PIN
authentication cannot be skipped using transient pairing or an early SETUP.

Run the independent client handshake regression suite with:

```sh
uv run apple/Tests/AirPlay/pairing_test.py --helper /Applications/made.app/Contents/MacOS/CockpitAirPlayReceiver
```

Its pinned test-only cryptography dependency verifies the encrypted key exchange
and both pairing signatures, including reconnect, typo recovery, wrong codes,
and malformed requests. It does not link the receiver's SRP implementation into
the client or log authentication material.

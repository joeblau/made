# iPhone control from the Device pane

The wired Device pane can drive the iPhone it mirrors: clicks become taps,
drags and two-finger trackpad scrolls become swipes, and typing goes to the
phone. It needs no Developer Mode and installs nothing on the phone.

## How it works

Cockpit publishes a Bluetooth HID device (an absolute pointer plus a
keyboard). With AssistiveTouch on, iOS treats that pointer as a finger.

1. **USB setup.** Over the trusted USB connection, Cockpit reads the phone's
   Bluetooth address and turns AssistiveTouch on by writing
   `com.apple.Accessibility / AssistiveTouchEnabledByiTunes` through
   MobileDevice.framework.
2. **Bluetooth service.** Cockpit publishes the HID SDP record and accepts the
   HID control (PSM 0x11) and interrupt (PSM 0x13) L2CAP channels. If the phone
   is already paired with this Mac, Cockpit asks it to reconnect.
3. **First pairing.** Otherwise the pane shows the one-time step: on the phone,
   open Settings › Accessibility › Touch › AssistiveTouch › Devices ›
   Bluetooth Devices and choose this Mac. Later sessions reconnect without it.
4. **Input.** The pane maps the pointer to the video's on-screen rect and
   sends absolute pointer reports (0...32767 on each axis). A serial queue
   inserts the small gaps AssistiveTouch needs between hover, press, and
   release, and coalesces drag moves.

The toolbar adds Home, App Switcher, and the AssistiveTouch menu (also
right-click). ⌘-drag still drags the screen image out of the pane.

The implementation lives in `apple/Sources/PhoneHIDKit` (Objective-C bridge)
and `apple/Sources/Pilot/Device/PhoneControl` (reports, SDP record, session).
It is ported from ShortReel's Bluetooth HID host.

## Private interfaces

| Interface | Used for |
| --- | --- |
| `CBClassicManager`, `CBClassicPeer` (CoreBluetooth) | Publishing the SDP record, discoverability, peer reconnect, L2CAP channels |
| `CBClassicPeer handleMsg:args:` (method hook) | Routing HID channel open/close messages to the bridge |
| MobileDevice.framework (`dlopen`) | Reading `BluetoothAddress`, enabling AssistiveTouch |

Every private symbol is looked up at runtime. A missing class, selector, or
function fails setup with a message in the pane instead of crashing, so an
OS update degrades the feature to unavailable.

## Threat model

Whoever holds the HID channels can tap and type on the phone, so the session
is scoped tightly:

- **Off by default, per pane.** Control starts only when someone chooses
  Control iPhone, and one pane owns it at a time. Turning it off, choosing
  another device, switching to wireless sharing, or closing the pane
  disconnects the phone, removes the SDP record, and stops discoverability.
- **One allowed phone.** The only accepted peer is the Bluetooth address the
  phone reported over its trusted USB session. Any other peer that opens the
  HID channels is disconnected.
- **Physical trust first.** USB setup requires the phone to have trusted this
  Mac (the iOS Trust prompt). The first Bluetooth pairing is confirmed on the
  phone itself.
- **Bounded input.** Reports are fixed-size and built from clamped
  coordinates. The input queue drops events past 256 pending, and writes give
  up after 100 ms, so a stalled channel cannot grow memory or block the UI.
  Incoming control-channel packets are answered by a fixed responder and never
  allocate beyond one packet.
- **Permissions.** macOS Bluetooth permission (`NSBluetoothAlwaysUsageDescription`,
  `com.apple.security.device.bluetooth`) is requested the first time control
  starts.

AssistiveTouch stays enabled on the phone after a session; turn it off in
Settings › Accessibility › Touch if you no longer want it. Pairing persists in
Bluetooth settings on both devices until removed.

## Known limits

- Portrait-first: pointer coordinates follow the mirrored frame, which matches
  the phone's portrait screen. Landscape apps may need calibration.
- Multi-touch (pinch, rotate) is not available through a single pointer.
- Typing uses US key codes; ⌘ shortcuts that Cockpit's menus claim stay on
  the Mac.

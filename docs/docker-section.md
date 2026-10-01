# Docker section

Pilot's Docker section is a control surface for a container engine the user
already runs. It is not a runtime: Pilot never installs, supervises, or bundles
a daemon, and it never builds images.

## What it talks to

The Docker Engine API is plain HTTP/1.1 on a Unix domain socket. `URLSession`
has no AF_UNIX transport, so `DockerSocketTransport` drives `NWConnection` over
an `.unix(path:)` endpoint and frames responses itself
(`DockerHTTPResponseParser`).

Socket discovery is an ordered search, so the section works with whichever
engine is installed:

1. `DOCKER_HOST`, when it names a `unix://` socket
2. `~/.docker/run/docker.sock` — Docker Desktop
3. `/var/run/docker.sock` — system default
4. `~/.colima/default/docker.sock` — Colima
5. `~/.rd/docker.sock` — Rancher Desktop
6. `~/.local/share/containers/podman/machine/podman.sock` — Podman compat

`DOCKER_HOST` values naming `tcp://` or `ssh://` daemons are ignored. The
section is local-only by design: reaching a remote daemon would move container
control onto the network, which is a different threat model and a different
feature.

The API version in request paths is pinned to `v1.43` (Docker Engine 24, 2023)
so the response shapes the decoders rely on stay fixed. Newer daemons
down-negotiate. The `/version` handshake is deliberately unversioned so a daemon
older than the pin reports a readable version error instead of a 400 on the
first list.

## Trust boundary

Everything past the socket is untrusted input. The socket is a local endpoint
that any process on the machine could be standing in for, and container names,
image tags, status strings, and error messages are written by image authors and
compose files, not by Pilot.

- The response parser enforces a header ceiling (64 KiB) and a body ceiling
  (8 MiB) *before* allocating, including on a declared `Content-Length` and on
  each chunk size.
- Malformed framing — a bad status line, an unparseable chunk size, a missing
  chunk terminator, EOF mid-body on a counted response — is a reported error,
  never a guess.
- The `/events` reader bounds the bytes it will buffer while waiting for a
  newline, so a daemon that streams without ever ending a line cannot grow the
  buffer without limit.
- All daemon-authored text passes through `DockerText.sanitized(_:limit:)`,
  which strips control characters and bounds length before it reaches a `Text`.
- Container identifiers are percent-encoded before they enter a request path.
- Socket paths are validated before they reach Network. `NWEndpoint.unix(path:)`
  accepts a path longer than `sockaddr_un.sun_path` (104 bytes) without
  complaint, but the resulting connection reports no state at all — it never
  succeeds and never fails — and the async read path traps on it. A malformed
  `DOCKER_HOST` would otherwise take the app down, so over-long, relative, and
  empty paths are rejected up front.
- Requests carry a timeout (15s for reads, 45s for stop/restart, which wait on
  the container's own grace period); `NWConnection` would otherwise wait
  indefinitely on a daemon that accepts a connection and then goes quiet.

## Scope of what it can change

The section exposes four lifecycle actions: start, stop, restart, and remove.

Remove is the only irreversible one. It is always confirmed first, uses
`force=1` so a running container can be removed in a single step (which is what
the confirmation promises), and passes `v=0` — named volumes are kept. Deleting
a database's data is never implied by "remove container".

Anything beyond the local lifecycle — building images, managing volumes and
networks, pulling — belongs in a terminal pane, not here.

## Liveness

`GET /events` filtered to `type=container` drives refreshes, coalesced at 250ms
so a compose stack coming up produces one list call rather than one per
container. A 15-second poll backs it up: it covers status strings that age with
no event to announce them ("Up 3 minutes"), and it re-runs the handshake when no
engine is connected, so an engine started after Pilot launched is picked up
without the user pressing Retry.

Every list read — handshake, poll, debounced event, the Refresh button, and an
action completing — goes through one gate: at most one `containers/json`
request is in flight, and triggers that arrive meanwhile collapse into a single
follow-up read. A poll tick is answered by the read already in flight and queues
nothing; the other triggers report a change that read may have missed, so they
queue the follow-up. The progress indicator stays up across the read and its
follow-up rather than blinking between them.

Each client is tagged with a connection generation. Reconnecting or leaving the
section retires it, and any reply, error, or handshake that the old client
returns afterwards is dropped instead of overwriting the current list or engine
state.

`DockerStore.stop()` tears down every socket task when the section is left — the
mode takes over the whole detail area, so nothing runs behind it. The exception
is a lifecycle request already sent: cancelling it would close the socket while
the daemon may be partway through a stop or remove, so it runs to completion,
its row stays guarded against a second click until then, and its result is
discarded. A success still prompts a list read through the current connection
when the section is showing.

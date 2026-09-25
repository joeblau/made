#!/usr/bin/env python3
"""Exercise the receiver in a built/installed app, including real Bonjour discovery.

This catches signed installation/metadata failures that an unsigned test host
can miss. It does not replace mirroring a real iPhone/iPad into the Device pane.
All subprocess, pipe and socket waits are bounded. No pairing codes are logged.
"""
import contextlib
import hashlib
import os
from pathlib import Path
import plistlib
import pty
import re
import secrets
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


# RFC 5054 2048-bit group, with Apple's SHA-1/40-byte session-key variant.
# Independent client implementation: it must not reuse the receiver's SRP code.
SRP_N = int(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4"
    "A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60"
    "95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF"
    "747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907"
    "8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
    "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB"
    "FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73", 16)


def number(value, size=None):
    return value.to_bytes(size or max(1, (value.bit_length() + 7) // 8), "big")


def sha1(*parts):
    return hashlib.sha1(b"".join(parts)).digest()


def srp_client(username, pin, salt, server_key):
    server = int.from_bytes(server_key, "big")
    if not 0 < server < SRP_N:
        raise RuntimeError("Invalid SRP server public key")
    secret = secrets.randbits(256)
    public = pow(2, secret, SRP_N)
    multiplier = int.from_bytes(sha1(number(SRP_N), number(2, 256)), "big")
    scrambling = int.from_bytes(sha1(number(public, 256), number(server, 256)), "big")
    exponent = int.from_bytes(sha1(salt, sha1(username.encode(), b":", pin)), "big")
    shared = pow((server - multiplier * pow(2, exponent, SRP_N)) % SRP_N,
                 secret + scrambling * exponent, SRP_N)
    session = sha1(number(shared), b"\0\0\0\0") + sha1(number(shared), b"\0\0\0\1")
    group_hash = bytes(a ^ b for a, b in zip(sha1(number(SRP_N)), sha1(b"\2")))
    proof = sha1(group_hash, sha1(username.encode()), salt, number(public), number(server), session)
    server_proof = sha1(number(public), proof, session)
    return number(public), proof, server_proof, session


def request(connection, path, body=b"", content_type="application/x-apple-binary-plist", method="POST"):
    if isinstance(body, dict):
        body = plistlib.dumps(body, fmt=plistlib.FMT_BINARY)
    header = (f"{method} {path} RTSP/1.0\r\nCSeq: 1\r\nContent-Type: {content_type}\r\n"
              f"Content-Length: {len(body)}\r\n\r\n").encode()
    connection.sendall(header + body)
    deadline = time.monotonic() + 3
    response = bytearray()
    while b"\r\n\r\n" not in response:
        connection.settimeout(max(0.001, deadline - time.monotonic()))
        chunk = connection.recv(1)
        if not chunk or len(response) > 8192 or time.monotonic() >= deadline:
            raise RuntimeError("Invalid or stalled pairing response")
        response.extend(chunk)
    status = int(response.split(b" ", 2)[1])
    match = re.search(rb"(?im)^Content-Length:\s*(\d+)", response)
    length = int(match.group(1)) if match else 0
    if length > 8192:
        raise RuntimeError("Pairing response exceeds limit")
    payload = bytearray()
    while len(payload) < length:
        connection.settimeout(max(0.001, deadline - time.monotonic()))
        chunk = connection.recv(length - len(payload))
        if not chunk or time.monotonic() >= deadline:
            raise RuntimeError("Truncated or stalled pairing payload")
        payload.extend(chunk)
    return status, bytes(payload)


def prove_pin(port, pin):
    username = "02:00:00:00:00:01"
    connection = socket.create_connection(("127.0.0.1", port), timeout=2)
    try:
        status, body = request(connection, "/pair-setup-pin", {"method": "pin", "user": username})
        if status != 200:
            raise RuntimeError(f"SRP challenge rejected ({status})")
        challenge = plistlib.loads(body)
        public, proof, expected, session = srp_client(username, pin, challenge["salt"], challenge["pk"])
        status, body = request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})
        if status != 200:
            raise RuntimeError(f"Correct PIN rejected during SRP proof ({status})")
        if plistlib.loads(body).get("proof") != expected:
            raise RuntimeError("SRP server proof did not authenticate the receiver")
        return connection, session
    except BaseException:
        connection.close()
        raise


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def exact(pipe, size, deadline):
    data = bytearray()
    while len(data) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([pipe], [], [], remaining)[0]:
            raise RuntimeError("Receiver pipe timed out")
        chunk = os.read(pipe.fileno(), size - len(data))
        if not chunk:
            raise RuntimeError("Receiver closed its pipe")
        data.extend(chunk)
    return bytes(data)


def packet(pipe, deadline):
    length = struct.unpack("!I", exact(pipe, 4, deadline))[0]
    if not 1 <= length <= 8 * 1024 * 1024:
        raise RuntimeError("Invalid receiver message length")
    data = exact(pipe, length, deadline)
    if data[0] == 7:
        code = struct.unpack("!i", data[1:])[0]
        raise RuntimeError(f"macOS rejected Bonjour registration ({code})")
    return data[0], data[1:]


def discovery(arguments, pattern):
    # dns-sd fully buffers output to a pipe. A PTY makes discovery observable
    # immediately, without treating a buffering timeout as missing advertising.
    master, slave = pty.openpty()
    process = None
    try:
        process = subprocess.Popen(["/usr/bin/dns-sd", *arguments], stdout=slave, stderr=slave,
                                   env={**os.environ, "LC_ALL": "C"})
        os.close(slave)
        slave = None
        # Hosted macOS runners can take several seconds to publish a new
        # multicast service while the test host and other suites start up.
        deadline = time.monotonic() + 15
        output = b""
        while time.monotonic() < deadline:
            if select.select([master], [], [], min(0.1, max(0, deadline - time.monotonic())))[0]:
                output += os.read(master, 4096)
                match = re.search(pattern, output.decode(errors="replace"))
                if match:
                    return match
                if len(output) > 65_536:
                    break
        raise RuntimeError("Receiver was not discoverable through Bonjour within fifteen seconds")
    finally:
        if process is not None:
            stop(process)
        os.close(master)
        if slave is not None:
            os.close(slave)


def check(app):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if not {"_airplay._tcp", "_raop._tcp"} <= set(info.get("NSBonjourServices", [])):
        raise RuntimeError("App is missing its AirPlay Bonjour declarations")
    helper = contents / "MacOS/CockpitAirPlayReceiver"
    for directory in (app, contents):
        if directory.stat().st_mtime_ns < max(helper.stat().st_mtime_ns,
                                            (contents / "Info.plist").stat().st_mtime_ns):
            raise RuntimeError("Bundle dates are stale; macOS may cache obsolete Bonjour declarations")
    name = "made-Check-" + uuid.uuid4().hex[:8]
    with tempfile.TemporaryDirectory(prefix="cockpit-airplay-check-") as directory, contextlib.ExitStack() as stack:
        key = Path(directory) / "pairing.pem"
        process = subprocess.Popen([str(helper), "--receive", name, str(key)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        stack.callback(process.stdout.close)
        stack.callback(stop, process)
        kind, payload = packet(process.stdout, time.monotonic() + 5)
        if (kind, payload) != (1, b""):
            raise RuntimeError("Receiver did not become ready")
        port = int(discovery(["-L", name, "_airplay._tcp", "local."],
                             r"can be reached at [^\r\n]+:(\d+) \(interface").group(1))
        discovery(["-B", "_raop._tcp", "local."], r"Add[^\r\n]+@" + re.escape(name))
        with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
            connection.sendall(b"POST /pair-pin-start RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
            response = b""
            response_deadline = time.monotonic() + 3
            while b"\r\n\r\n" not in response and len(response) < 8192:
                remaining = response_deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("Pairing response timed out")
                connection.settimeout(remaining)
                chunk = connection.recv(1024)
                if not chunk:
                    break
                response += chunk
            if not response.startswith(b"RTSP/1.0 200"):
                raise RuntimeError("Receiver rejected the pairing request")
            deadline = time.monotonic() + 3
            while True:
                kind, payload = packet(process.stdout, deadline)
                if kind == 2:
                    if len(payload) != 4 or not payload.isdigit():
                        raise RuntimeError("Receiver returned an invalid pairing code")
                    pin = payload
                    break
        paired, _ = prove_pin(port, pin)
        paired.close()
        if key.stat().st_mode & 0o777 != 0o600:
            raise RuntimeError("Pairing key permissions are not private")
        process.terminate()
        if process.wait(timeout=2) != 0:
            raise RuntimeError("Receiver did not stop cleanly")
    print("PASS: installed receiver startup, both Bonjour services, PIN/SRP authentication, private key, bounded shutdown")


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1] if len(sys.argv) > 1 else "/Applications/made.app").resolve())
    except (OSError, RuntimeError, subprocess.TimeoutExpired, struct.error) as error:
        sys.exit(f"FAIL: {error}")

# /// script
# requires-python = ">=3.10"
# dependencies = ["cryptography==50.0.1"]
# ///
"""Independent AirPlay client regression tests against the real receiver process.

Run with: uv run apple/Tests/AirPlay/pairing_test.py --helper /path/to/CockpitAirPlayReceiver
No PINs, session keys, or authentication payloads are printed.
"""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

APPLE = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("receiver_check", APPLE / "bin/check-airplay-receiver.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
parser = argparse.ArgumentParser()
parser.add_argument("--helper", type=Path, default=APPLE / "Packages/AirPlayReceiver/.build/CockpitAirPlayReceiver")
options, remaining = parser.parse_known_args()


def complete_setup(connection, session):
    client = ed25519.Ed25519PrivateKey.generate()
    key = hashlib.sha512(b"Pair-Setup-AES-Key" + session).digest()[:16]
    iv = bytearray(hashlib.sha512(b"Pair-Setup-AES-IV" + session).digest()[:16])
    iv[-1] = (iv[-1] + 1) % 256
    encrypted = AESGCM(key).encrypt(bytes(iv), client.public_key().public_bytes_raw(), None)
    status, body = check.request(connection, "/pair-setup-pin", {"epk": encrypted[:-16], "authTag": encrypted[-16:]})
    if status != 200:
        raise AssertionError(f"Authenticated key exchange rejected ({status})")
    response = plistlib.loads(body)
    iv[-1] = (iv[-1] + 1) % 256
    server = AESGCM(key).decrypt(bytes(iv), response["epk"] + response["authTag"], None)
    return client, ed25519.Ed25519PublicKey.from_public_bytes(server)


def verify_pair(connection, client, server):
    ephemeral = x25519.X25519PrivateKey.generate()
    public = ephemeral.public_key().public_bytes_raw()
    status, body = check.request(connection, "/pair-verify",
                                 b"\1\0\0\0" + public + client.public_key().public_bytes_raw(),
                                 "application/octet-stream")
    if status != 200 or len(body) != 96:
        raise AssertionError(f"Pair verification rejected ({status}, {len(body)} bytes)")
    server_public = body[:32]
    shared = ephemeral.exchange(x25519.X25519PublicKey.from_public_bytes(server_public))
    key = hashlib.sha512(b"Pair-Verify-AES-Key" + shared).digest()[:16]
    iv = hashlib.sha512(b"Pair-Verify-AES-IV" + shared).digest()[:16]
    cipher = Cipher(algorithms.AES(key), modes.CTR(iv))
    server.verify(cipher.decryptor().update(body[32:]), server_public + public)
    encryptor = cipher.encryptor()
    encryptor.update(bytes(64))  # Client's signature follows the server's CTR block.
    signature = encryptor.update(client.sign(public + server_public))
    status, _ = check.request(connection, "/pair-verify", b"\0\0\0\0" + signature, "application/octet-stream")
    if status != 200:
        raise AssertionError(f"Client signature rejected ({status})")


class PairingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="cockpit-pairing-tests-")
        cls.addClassCleanup(cls.directory.cleanup)
        name = "made-Pairing-Test-" + uuid.uuid4().hex[:8]
        cls.receiver = subprocess.Popen([str(options.helper.resolve()), "--receive", name,
                                         str(Path(cls.directory.name) / "pairing.pem")],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        cls.addClassCleanup(cls.receiver.stdout.close)
        cls.addClassCleanup(check.stop, cls.receiver)
        if check.packet(cls.receiver.stdout, time.monotonic() + 5) != (1, b""):
            raise AssertionError("Receiver did not start")
        cls.port = int(check.discovery(["-L", name, "_airplay._tcp", "local."],
                                       r"can be reached at [^\r\n]+:(\d+) \(interface").group(1))

    def connect(self):
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        self.addCleanup(connection.close)
        return connection

    def setUp(self):
        with self.connect() as connection:
            self.assertEqual(check.request(connection, "/pair-pin-start")[0], 200)
        deadline = time.monotonic() + 3
        while True:
            kind, payload = check.packet(self.receiver.stdout, deadline)
            if kind == 2:
                self.pin = payload
                break

    def challenge(self, pin=None):
        connection = self.connect()
        username = "02:00:00:00:00:02"
        status, body = check.request(connection, "/pair-setup-pin", {"method": "pin", "user": username})
        self.assertEqual(status, 200)
        challenge = plistlib.loads(body)
        public, proof, expected, session = check.srp_client(username, pin or self.pin, challenge["salt"], challenge["pk"])
        return connection, public, proof, expected, session

    def authenticate(self):
        connection, public, proof, expected, session = self.challenge()
        self.assertEqual(len(proof), 20)
        status, body = check.request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})
        self.assertEqual(status, 200, "The displayed PIN must be accepted")
        self.assertTrue(plistlib.loads(body)["proof"] == expected, "Server proof did not match")
        return connection, session

    def test_correct_pin_completes_encrypted_pairing_and_verification(self):
        connection, session = self.authenticate()
        client, server = complete_setup(connection, session)
        verify_pair(connection, client, server)

    def test_paired_client_can_verify_on_a_new_connection(self):
        connection, session = self.authenticate()
        client, server = complete_setup(connection, session)
        connection.close()
        verify_pair(self.connect(), client, server)

    def test_wrong_pin_and_repeated_proof_are_rejected_without_crashing(self):
        wrong = f"{(int(self.pin) + 1) % 10000:04d}".encode()
        connection, public, proof, _, _ = self.challenge(wrong)
        for _ in range(2):
            self.assertEqual(check.request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})[0], 470)
        self.assertIsNone(self.receiver.poll())

    def test_correct_pin_can_be_retried_after_a_typo(self):
        wrong = f"{(int(self.pin) + 1) % 10000:04d}".encode()
        connection, public, proof, _, _ = self.challenge(wrong)
        self.assertEqual(check.request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})[0], 470)
        connection.close()
        connection, session = self.authenticate()
        client, server = complete_setup(connection, session)
        verify_pair(connection, client, server)

    def test_completed_pin_is_not_available_for_new_pairing(self):
        connection, session = self.authenticate()
        complete_setup(connection, session)
        connection.close()
        self.assertEqual(check.request(self.connect(), "/pair-setup-pin",
                                       {"method": "pin", "user": "02:00:00:00:00:03"})[0], 470)

    def test_unknown_client_cannot_verify_without_pin_pairing(self):
        key = x25519.X25519PrivateKey.generate().public_key().public_bytes_raw()
        identity = ed25519.Ed25519PrivateKey.generate().public_key().public_bytes_raw()
        self.assertEqual(check.request(self.connect(), "/pair-verify", b"\1\0\0\0" + key + identity,
                                       "application/octet-stream")[0], 470)

    def test_invalid_pair_verification_signature_is_rejected(self):
        connection, session = self.authenticate()
        client, _ = complete_setup(connection, session)
        ephemeral = x25519.X25519PrivateKey.generate().public_key().public_bytes_raw()
        self.assertEqual(check.request(connection, "/pair-verify",
                                       b"\1\0\0\0" + ephemeral + client.public_key().public_bytes_raw(),
                                       "application/octet-stream")[0], 200)
        self.assertEqual(check.request(connection, "/pair-verify", bytes(68), "application/octet-stream")[0], 470)

    def test_invalid_srp_public_keys_are_rejected_without_crashing(self):
        connection, public, proof, expected, _ = self.challenge()
        for invalid in (b"", bytes(256), bytes(257)):
            self.assertEqual(check.request(connection, "/pair-setup-pin", {"pk": invalid, "proof": proof})[0], 470)
        status, body = check.request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})
        self.assertEqual(status, 200)
        self.assertTrue(plistlib.loads(body)["proof"] == expected, "Server proof did not match")

    def test_media_setup_requires_verified_pairing(self):
        self.assertEqual(check.request(self.connect(), "rtsp://127.0.0.1/stream", {}, method="SETUP")[0], 470)

    def test_invalid_proof_lengths_do_not_consume_valid_challenge(self):
        connection, public, proof, expected, _ = self.challenge()
        for invalid in (b"", proof[:-1], proof + b"\0", proof + bytes(44), bytes(65)):
            self.assertEqual(check.request(connection, "/pair-setup-pin", {"pk": public, "proof": invalid})[0], 470)
        status, body = check.request(connection, "/pair-setup-pin", {"pk": public, "proof": proof})
        self.assertEqual(status, 200)
        self.assertTrue(plistlib.loads(body)["proof"] == expected, "Server proof did not match")

    def test_proof_without_challenge_is_rejected(self):
        self.assertEqual(check.request(self.connect(), "/pair-setup-pin", {"pk": bytes(256), "proof": bytes(20)})[0], 470)

    def test_key_exchange_requires_a_verified_pin(self):
        connection, _, _, _, _ = self.challenge()
        self.assertEqual(check.request(connection, "/pair-setup-pin", {"epk": bytes(32), "authTag": bytes(16)})[0], 470)

    def test_key_exchange_without_challenge_is_rejected(self):
        self.assertEqual(check.request(self.connect(), "/pair-setup-pin", {"epk": bytes(32), "authTag": bytes(16)})[0], 470)

    def test_invalid_key_exchange_lengths_do_not_crash(self):
        connection, session = self.authenticate()
        for key, tag in ((bytes(31), bytes(16)), (bytes(33), bytes(16)), (bytes(32), bytes(15)), (bytes(32), bytes(17))):
            self.assertEqual(check.request(connection, "/pair-setup-pin", {"epk": key, "authTag": tag})[0], 470)
        complete_setup(connection, session)

    def test_pin_cannot_be_bypassed_with_transient_pair_setup(self):
        self.assertEqual(check.request(self.connect(), "/pair-setup", bytes(32), "application/octet-stream")[0], 470)


if __name__ == "__main__":
    unittest.main(argv=[__file__, *remaining], verbosity=2)

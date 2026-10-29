"""Exercise the real CLI against an isolated Unix socket, never an installed Eclipse."""

import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest


CLI = str(Path(sys.argv.pop(1)).resolve())


class NoticeCLIChecks(unittest.TestCase):
    def run_cli(self, payload, *arguments):
        return subprocess.run(
            [CLI, "--stdin", *arguments],
            input=payload,
            capture_output=True,
            timeout=5,
            check=False,
        )

    def test_notify_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="notch-cli-", dir="/tmp") as folder:
            path = str(Path(folder) / "test.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(2)
                result = self.run_cli(
                    b'{"type":"notify","title":"Backup\\nfailed","id":"pi.backup","extra":"ignored"}\n',
                    "--socket", path,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                with server.accept()[0] as peer:
                    peer.settimeout(2)
                    data = b""
                    while chunk := peer.recv(4096):
                        data += chunk
                self.assertTrue(data.endswith(b"\n"))
                self.assertEqual(
                    json.loads(data),
                    {"type": "notify", "title": "Backup failed", "id": "pi.backup", "tint": "white"},
                )

    def test_rejects_non_notices_and_extra_input(self):
        for payload in (
            b'{"type":"dictation","state":"recording"}\n',
            b'{"type":"notify","title":"Done"}\n{"type":"notify","title":"Again"}\n',
            b'{"type":"notify","title":"Done"}\n\n',
            b"\xff\n",
            b"",
            b" " * 4097,
        ):
            with self.subTest(payload=payload[:80]):
                self.assertEqual(self.run_cli(payload).returncode, 2)

    def test_rejects_lines_the_app_would_refuse(self):
        # One character with thousands of combining marks passes the 40-character title limit, but its line does not
        # fit in 4096 bytes. The stdin payload fits, and grows past the limit once the default tint is added.
        heavy = "a" + "\u0301" * 2033
        payload = json.dumps({"type": "notify", "title": heavy}, ensure_ascii=False, separators=(",", ":"))
        payload = (payload + "\n").encode()
        self.assertEqual(len(payload), 4096)
        with tempfile.TemporaryDirectory(prefix="notch-cli-", dir="/tmp") as folder:
            path = str(Path(folder) / "test.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(0.2)
                for result in (
                    subprocess.run([CLI, "--socket", path, "a" + "\u0301" * 3000],
                                   capture_output=True, timeout=5, check=False),
                    self.run_cli(payload, "--socket", path),
                ):
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(b"longer than 4096", result.stderr)
                with self.assertRaises(socket.timeout):
                    server.accept()

    def test_rejects_mixed_modes(self):
        for arguments in (("Title",), ("--tint", "red"), ("--stdin",)):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_cli(b"{}", *arguments).returncode, 2)

    def test_missing_socket_is_delivery_failure(self):
        with tempfile.TemporaryDirectory(prefix="notch-cli-", dir="/tmp") as folder:
            result = self.run_cli(
                b'{"type":"notify","title":"Done"}\n',
                "--socket", str(Path(folder) / "absent.sock"),
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"not listening", result.stderr)


if __name__ == "__main__":
    unittest.main()

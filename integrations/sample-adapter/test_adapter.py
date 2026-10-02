import json
import pathlib
import socket
import subprocess
import threading
import unittest
import uuid

SCRIPT = pathlib.Path(__file__).with_name("studio_status_adapter.py")
TOKEN = "a" * 64

class AdapterTests(unittest.TestCase):
    def run_host(self, answer):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0)); listener.listen(1)
        calls = []
        def host():
            with listener, listener.accept()[0] as connection:
                reader = connection.makefile("rb")
                request = json.loads(reader.readline()); calls.append(request)
                answer(connection, reader, request, calls)
        worker = threading.Thread(target=host, daemon=True); worker.start()
        credential = dict(version=1, clientID=str(uuid.uuid4()), token=TOKEN, host="127.0.0.1", port=listener.getsockname()[1])
        result = subprocess.run(["python3", str(SCRIPT)], input=json.dumps(credential)+"\n", text=True, capture_output=True, timeout=5)
        worker.join(timeout=1)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result, calls

    def test_external_sample_authenticates_subscribes_and_stops_without_replay(self):
        session = str(uuid.uuid4())
        def answer(connection, reader, request, calls):
            self.assertEqual(request["type"], "authenticate")
            connection.sendall((json.dumps(dict(version=1, type="authenticated", id=request["id"].upper(), sessionID=session)) + "\n").encode())
            subscription = json.loads(reader.readline()); calls.append(subscription)
            self.assertEqual(subscription["type"], "subscribe"); self.assertNotIn("token", subscription)
            state = dict(projectID="profile-a", recording="paused", stream="connecting")
            connection.sendall((json.dumps(dict(version=1, type="snapshot", id=subscription["id"], sessionID=session, snapshot=state)) + "\n").encode())
        result, calls = self.run_host(answer)
        self.assertEqual(len(calls), 2)
        self.assertIn('"recording": "paused"', result.stdout)
        self.assertIn("Studio disconnected", result.stderr)
        self.assertEqual(result.returncode, 1)

    def test_disabled_or_incompatible_host_does_not_retry(self):
        for frame in [dict(version=1, type="error", error=dict(code="adapterDisabled")), dict(version=99, type="authenticated"),
                      dict(version=1, type="error", error=dict(code=[])), dict(version=1, type="error", error=dict(code=TOKEN))]:
            result, calls = self.run_host(lambda connection, reader, request, calls: connection.sendall((json.dumps(frame)+"\n").encode()))
            self.assertEqual(len(calls), 1); self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")

    def test_invalid_pairing_never_connects_or_echoes_input(self):
        for credential in [dict(version=1, clientID=str(uuid.uuid4()), token=TOKEN, host="0.0.0.0"), {"token":"invalid"}, []]:
            result = subprocess.run(["python3", str(SCRIPT)], input=json.dumps(credential)+"\n", text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1); self.assertNotIn(TOKEN, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()

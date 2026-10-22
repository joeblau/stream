import base64
import importlib.util
import time
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
    def run_host(self, answer, cli=False):
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
        command = ["python3", str(SCRIPT)] if not cli else ["python3", str(SCRIPT.parents[1].parent / "apple/scripts/studio_local_control.py"), "--credentials-stdin", "--snapshot"]
        result = subprocess.run(command, input=json.dumps(credential)+"\n", text=True, capture_output=True, timeout=9)
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

    @staticmethod
    def chunks(response):
        data = json.dumps(response, separators=(",", ":"), ensure_ascii=False).encode()
        size = 24 * 1024
        transfer = str(uuid.uuid4())
        return [dict(version=1, type="responseChunk", id=response.get("id"), sessionID=response["sessionID"],
                     responseChunk=dict(transferID=transfer, index=index, count=(len(data)+size-1)//size, totalBytes=len(data),
                                        responseType=response["type"], snapshotRevision=response["snapshot"]["revision"],
                                        body=base64.b64encode(data[index*size:(index+1)*size]).decode()))
                for index in range((len(data)+size-1)//size)]

    @staticmethod
    def large_state(revision):
        return dict(projectID="large-project", revision=revision, recording="paused", stream="live",
                    destinations=[dict(id=str(uuid.uuid4()), name="日"*128) for _ in range(512)])

    def test_complete_chunked_auth_and_subscription_are_readonly_and_atomic(self):
        session = str(uuid.uuid4())
        def send(connection, frame):
            connection.sendall((json.dumps(frame, separators=(",", ":"))+"\n").encode())
        def answer(connection, reader, request, calls):
            self.assertIs(request.get("responseChunks"), True)
            for frame in self.chunks(dict(version=1, type="authenticated", id=request["id"], sessionID=session, snapshot=self.large_state(1))):
                send(connection, frame)
            subscription = json.loads(reader.readline()); calls.append(subscription)
            small = dict(projectID="large-project", revision=1, stream="idle", recording="paused")
            send(connection, dict(version=1, type="snapshot", id=subscription["id"], sessionID=session, snapshot=small))
            old = self.chunks(dict(version=1, type="event", sessionID=session, snapshot=self.large_state(2)))
            fresh = self.chunks(dict(version=1, type="event", sessionID=session, snapshot=self.large_state(3)))
            for frames in ([old[0]], fresh, old[1:]):
                for frame in frames:
                    # Optional UUID fields are omitted in native Codable output.
                    frame = {key:value for key,value in frame.items() if value is not None}
                    send(connection, frame)
        result, calls = self.run_host(answer)
        states = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([state["revision"] for state in states], [1, 3])
        self.assertEqual(len(states[-1]["destinations"]), 512)
        self.assertEqual([call["type"] for call in calls], ["authenticate", "subscribe"])
        self.assertIn("Studio disconnected", result.stderr)

    def test_cli_receives_complete_chunked_response_with_native_uppercase_session(self):
        session = str(uuid.uuid4()).upper()
        def send(connection, response):
            for frame in self.chunks(response):
                connection.sendall((json.dumps(frame)+"\n").encode())
        def answer(connection, reader, request, calls):
            self.assertIs(request.get("responseChunks"), True)
            send(connection, dict(version=1, type="authenticated", id=request["id"].upper(), sessionID=session, snapshot=self.large_state(1)))
            request = json.loads(reader.readline()); calls.append(request)
            self.assertEqual(request["type"], "snapshot")
            self.assertEqual(uuid.UUID(request["sessionID"]), uuid.UUID(session))
            send(connection, dict(version=1, type="snapshot", id=request["id"].upper(), sessionID=session, snapshot=self.large_state(2)))
        result, calls = self.run_host(answer, cli=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["snapshot"]["revision"], 2)
        self.assertEqual(len(response["snapshot"]["destinations"]), 512)
        self.assertEqual([call["type"] for call in calls], ["authenticate", "snapshot"])

    def test_python_chunk_contract_rejects_mixed_session_duplicate_and_oversize(self):
        for script in [SCRIPT, SCRIPT.parents[1].parent / "apple/scripts/studio_local_control.py"]:
            spec = importlib.util.spec_from_file_location("chunk_client", script)
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            assembler = module.ResponseChunks()
            session = str(uuid.uuid4()); assembler.session = session
            frames = self.chunks(dict(version=1, type="event", id=str(uuid.uuid4()), sessionID=session, snapshot=self.large_state(2)))
            self.assertIsNone(assembler.feed(frames[0]))
            with self.assertRaises(ValueError): assembler.feed(frames[0])
            with self.assertRaises(ValueError): assembler.feed(dict(frames[1], sessionID=str(uuid.uuid4())))
            invalid = dict(frames[1], responseChunk=dict(frames[1]["responseChunk"], totalBytes=16*1024*1024+1))
            with self.assertRaises(ValueError): assembler.feed(invalid)
            newer = dict(version=1, type="event", sessionID=session, snapshot=dict(revision=3))
            self.assertEqual(assembler.feed(newer), newer)
            self.assertIsNone(assembler.deadline(), "Retired event retained an idle read timeout")

    def test_invalid_pairing_never_connects_or_echoes_input(self):
        for credential in [dict(version=1, clientID=str(uuid.uuid4()), token=TOKEN, host="0.0.0.0"), {"token":"invalid"}, []]:
            result = subprocess.run(["python3", str(SCRIPT)], input=json.dumps(credential)+"\n", text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1); self.assertNotIn(TOKEN, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()

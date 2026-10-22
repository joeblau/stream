#!/usr/bin/env python3
"""External-process sample. Credentials come only from stdin, never argv/logs.

Uses the existing bounded authenticated control contract. It displays state,
never sends a production command, and stops on disconnect without replay.
"""
import json
import base64
import binascii
import time
import socket
import sys
import uuid

MAX_FRAME = 65536

# Negotiated local-control wire framing; complete responses only, never commands.
class ResponseChunks:
    CHUNK_BYTES = 24 * 1024
    MAX_BYTES = 16 * 1024 * 1024
    TYPES = {"authenticated", "capabilities", "snapshot", "event", "result", "error", "pong"}

    def __init__(self):
        self.transfers = {}
        self.session = None
        self.revision = 0

    @staticmethod
    def integer(value):
        return isinstance(value, int) and not isinstance(value, bool)

    def retire(self, revision):
        self.revision = max(self.revision, revision)
        self.transfers = {key: item for key, item in self.transfers.items()
                          if item["type"] != "event" or item["revision"] is None or item["revision"] >= revision}

    def deadline(self):
        return min((item["started"] + 5 for item in self.transfers.values()), default=None)

    def feed(self, response):
        if not isinstance(response, dict) or response.get("version") != 1:
            raise ValueError("Unsupported local control response")
        if self.session is not None:
            try:
                same_session = uuid.UUID(response.get("sessionID")) == uuid.UUID(self.session)
            except (ValueError, TypeError, AttributeError):
                same_session = False
            if not same_session:
                raise ValueError("The host session changed; authenticate again without replay")
        if response.get("type") != "responseChunk":
            state = response.get("snapshot")
            if isinstance(state, dict) and self.integer(state.get("revision")):
                if state["revision"] < self.revision:
                    if response.get("type") == "event":
                        return None
                else:
                    self.retire(state["revision"])
            return response
        part = response.get("responseChunk")
        if not isinstance(part, dict):
            raise ValueError("Invalid response chunk")
        try:
            key = str(uuid.UUID(part["transferID"]))
            index, count, size = part["index"], part["count"], part["totalBytes"]
            kind, revision = part["responseType"], part.get("snapshotRevision")
            if (not all(self.integer(value) for value in (index, count, size)) or not 65536 < size <= self.MAX_BYTES
                    or count != (size + self.CHUNK_BYTES - 1) // self.CHUNK_BYTES or not 0 <= index < count
                    or kind not in self.TYPES or (revision is not None and (not self.integer(revision) or revision < 0))
                    or not isinstance(part["body"], str)):
                raise ValueError()
            for name in ("id", "sessionID"):
                if name in response:
                    uuid.UUID(response[name])
            body = base64.b64decode(part["body"], validate=True)
            expected = size - index * self.CHUNK_BYTES if index == count - 1 else self.CHUNK_BYTES
            if len(body) != expected or base64.b64encode(body).decode("ascii") != part["body"]:
                raise ValueError()
        except (KeyError, ValueError, TypeError, AttributeError, binascii.Error):
            raise ValueError("Invalid bounded response chunk") from None
        if revision is not None:
            if kind == "event" and revision < self.revision:
                return None
            self.retire(revision)
        identity = (response.get("id"), response.get("sessionID"), kind, revision, count, size)
        item = self.transfers.get(key)
        if item is None:
            if len(self.transfers) >= 8:
                raise ValueError("Too many incomplete native responses")
            item = dict(identity=identity, type=kind, revision=revision, started=time.monotonic(), chunks={})
            self.transfers[key] = item
        if item["identity"] != identity or index in item["chunks"]:
            raise ValueError("Mixed or duplicate response chunks")
        item["chunks"][index] = body
        if len(item["chunks"]) != count:
            return None
        del self.transfers[key]
        try:
            complete = json.loads(b"".join(item["chunks"][index] for index in range(count)))
            if (not isinstance(complete, dict) or complete.get("version") != 1 or complete.get("type") != kind
                    or complete.get("id") != identity[0] or complete.get("sessionID") != identity[1]
                    or (revision is not None and complete.get("snapshot", {}).get("revision") != revision)):
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise ValueError("Invalid assembled native response") from None
        return complete


def receive_complete(reader, connection, chunks):
    original_timeout = connection.gettimeout()
    try:
        while True:
            deadline = chunks.deadline()
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("Incomplete native response timed out; no request was replayed")
                connection.settimeout(min(original_timeout or remaining, remaining))
            else:
                connection.settimeout(original_timeout)
            line = reader.readline(MAX_FRAME + 2)
            if not line:
                raise ValueError("Studio disconnected. Authenticate for a fresh session without replay.")
            if not line.endswith(b"\n") or len(line) > MAX_FRAME + 1:
                raise ValueError("The host exceeded the local IPC frame limit")
            response = chunks.feed(json.loads(line))
            if response is not None:
                return response
    finally:
        connection.settimeout(original_timeout)


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def receive(reader, connection, chunks):
    try:
        response = receive_complete(reader, connection, chunks)
    except ValueError as error:
        if str(error).startswith("Studio disconnected."):
            fail("Studio disconnected. Restart and authenticate for a fresh session.")
        fail("The host sent an invalid or incomplete bounded response.")
    if response.get("error"):
        error = response["error"]
        if not isinstance(error, dict):
            fail("The host sent a malformed error.")
        known = {"unauthorized", "versionMismatch", "adapterDisabled", "adapterIncompatible", "adapterCapabilityDenied", "adapterRegistryUnavailable", "sessionLimit", "rateLimit", "responseLimit", "responseChunksRequired"}
        received_code = error.get("code")
        code = received_code if isinstance(received_code, str) and received_code in known else "unknown"
        fail("The studio rejected this adapter: " + code)
    return response

def main():
    try:
        credential = json.loads(sys.stdin.buffer.readline(4097))
        uuid.UUID(credential["clientID"])
        token = credential["token"]
        port = credential.get("port", 32145)
        if credential.get("version") != 1 or credential.get("host", "127.0.0.1") != "127.0.0.1":
            fail("Paste version 1 loopback credentials through stdin.")
        if not isinstance(token, str) or len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
            fail("The pairing credential is invalid.")
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            fail("The loopback port is invalid.")
    except (ValueError, KeyError, TypeError):
        fail("Paste valid pairing JSON through stdin.")
    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
        reader = connection.makefile("rb")
        chunks = ResponseChunks()
        def send(kind, **fields):
            identifier = str(uuid.uuid4())
            connection.sendall((json.dumps(dict(version=1, type=kind, id=identifier, **fields)) + "\n").encode())
            return identifier
        identifier = send("authenticate", clientID=credential["clientID"], token=token, responseChunks=True)
        credential.clear(); token = None
        response = receive(reader, connection, chunks)
        session = response.get("sessionID")
        if response.get("type") != "authenticated" or str(response.get("id", "")).lower() != identifier or not session:
            fail("The host did not acknowledge pairing.")
        uuid.UUID(session)
        chunks.session = session
        subscription = send("subscribe", sessionID=session)
        awaiting_subscription = True
        connection.settimeout(None)
        while True:
            response = receive(reader, connection, chunks)
            if response.get("sessionID") != session:
                fail("The host session changed. Authenticate again without replay.")
            if awaiting_subscription:
                if response.get("type") != "snapshot" or str(response.get("id", "")).lower() != subscription:
                    fail("The host did not acknowledge the subscription.")
                awaiting_subscription = False
            if response.get("type") not in ("snapshot", "event") or not isinstance(response.get("snapshot"), dict):
                fail("The host sent an unexpected adapter response.")
            print(json.dumps(response["snapshot"], sort_keys=True), flush=True)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        fail("The adapter could not reach the enabled local studio. Check pairing and adapter status.")

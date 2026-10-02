#!/usr/bin/env python3
"""External-process sample. Credentials come only from stdin, never argv/logs.

Uses the existing bounded authenticated control contract. It displays state,
never sends a production command, and stops on disconnect without replay.
"""
import json
import socket
import sys
import uuid

MAX_FRAME = 65536

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def receive(reader):
    line = reader.readline(MAX_FRAME + 2)
    if not line:
        fail("Studio disconnected. Restart and authenticate for a fresh session.")
    if len(line) > MAX_FRAME + 1 or not line.endswith(b"\n"):
        fail("The host sent an invalid or oversized frame.")
    try:
        response = json.loads(line)
    except (ValueError, UnicodeError):
        fail("The host sent malformed JSON.")
    if not isinstance(response, dict) or response.get("version") != 1:
        fail("The adapter needs local control protocol version 1.")
    if response.get("error"):
        error = response["error"]
        if not isinstance(error, dict):
            fail("The host sent a malformed error.")
        known = {"unauthorized", "versionMismatch", "adapterDisabled", "adapterIncompatible", "adapterCapabilityDenied", "adapterRegistryUnavailable", "sessionLimit", "rateLimit"}
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
        def send(kind, **fields):
            identifier = str(uuid.uuid4())
            connection.sendall((json.dumps(dict(version=1, type=kind, id=identifier, **fields)) + "\n").encode())
            return identifier
        identifier = send("authenticate", clientID=credential["clientID"], token=token)
        credential.clear(); token = None
        response = receive(reader)
        session = response.get("sessionID")
        if response.get("type") != "authenticated" or str(response.get("id", "")).lower() != identifier or not session:
            fail("The host did not acknowledge pairing.")
        uuid.UUID(session)
        send("subscribe", sessionID=session)
        connection.settimeout(None)
        while True:
            response = receive(reader)
            if response.get("sessionID") != session:
                fail("The host session changed. Authenticate again without replay.")
            if response.get("type") not in ("snapshot", "event") or not isinstance(response.get("snapshot"), dict):
                fail("The host sent an unexpected adapter response.")
            print(json.dumps(response["snapshot"], sort_keys=True), flush=True)

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError):
        fail("The adapter could not reach the enabled local studio. Check pairing and adapter status.")

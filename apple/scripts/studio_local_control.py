#!/usr/bin/env python3
"""Example native Stream local IPC client; commands are sent once, never replayed."""
import argparse
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



class StudioClient:
    def __init__(self, credentials):
        if credentials.get("version", 1) != 1:
            raise ValueError("Pairing credentials require protocol version 1")
        if credentials.get("host", "127.0.0.1") != "127.0.0.1":
            raise ValueError("Stream local control only connects to 127.0.0.1")
        self.client_id = str(uuid.UUID(credentials["clientID"]))
        self.token = credentials["token"]
        if len(self.token) != 64 or any(c not in "0123456789abcdef" for c in self.token):
            raise ValueError("Pairing token must contain 64 hexadecimal characters")
        port = int(credentials.get("port", 32145))
        if not 1 <= port <= 65535:
            raise ValueError("Invalid local controller port")
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.reader = self.socket.makefile("rb")
        self.chunks = ResponseChunks()
        self.session = None
        reply = self.request("authenticate", clientID=self.client_id, token=self.token, responseChunks=True)
        self.token = None
        if reply.get("error"):
            raise ValueError(reply["error"]["message"])
        self.session = str(uuid.UUID(reply["sessionID"]))
        self.chunks.session = self.session

    def read(self):
        return receive_complete(self.reader, self.socket, self.chunks)

    def request(self, operation, **payload):
        request_id = str(uuid.uuid4())
        request = {"version": 1, "type": operation, "id": request_id, **payload}
        if self.session is not None:
            request["sessionID"] = self.session
        encoded = json.dumps(request, separators=(",", ":")).encode()
        if len(encoded) > MAX_FRAME:
            raise ValueError("Request exceeded the local IPC size limit")
        self.socket.sendall(encoded + b"\n")
        while True:
            reply = self.read()
            if str(reply.get("id", "")).lower() == request_id:
                expected = {"authenticate": "authenticated", "capabilities": "capabilities", "snapshot": "snapshot", "subscribe": "snapshot", "command": "result", "ping": "pong"}[operation]
                if reply.get("type") not in (expected, "error"):
                    raise ValueError("The host did not acknowledge the expected operation")
                return reply

    def close(self):
        self.reader.close()
        self.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--credentials-file", help="Pairing JSON stored outside the project/repository")
    source.add_argument("--credentials-stdin", action="store_true", help="Read pairing JSON from stdin")
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--capabilities", action="store_true", help="Discover stable command/resource IDs")
    actions.add_argument("--snapshot", action="store_true", help="Read authoritative studio state")
    actions.add_argument("--subscribe", action="store_true", help="Read a snapshot, then full-state events")
    actions.add_argument("--command", metavar="STABLE_COMMAND_ID", help="Send one command once")
    parser.add_argument("--search", default="", help="Filter discovered capability titles/categories/IDs")
    args = parser.parse_args()
    client = None
    try:
        if args.credentials_stdin:
            credentials = json.load(sys.stdin)
        else:
            with open(args.credentials_file, encoding="utf-8") as handle:
                credentials = json.load(handle)
        client = StudioClient(credentials)
        if args.capabilities:
            cursor = 0
            while True:
                reply = client.request("capabilities", cursor=cursor)
                if reply.get("error"):
                    print(json.dumps(reply)); return 2
                for command in reply.get("commands", []):
                    if args.search.casefold() in " ".join(str(command.get(key, "")) for key in ("id", "title", "category")).casefold():
                        print(json.dumps(command))
                if reply.get("nextCursor") is None:
                    break
                cursor = reply["nextCursor"]
        else:
            operation = "command" if args.command else "subscribe" if args.subscribe else "snapshot"
            payload = {"commandID": args.command} if args.command else {}
            reply = client.request(operation, **payload)
            print(json.dumps(reply), flush=True)
            if reply.get("error") or reply.get("result", {}).get("succeeded") is False:
                return 2
            if args.subscribe:
                client.socket.settimeout(None)
                while True:
                    print(json.dumps(client.read()), flush=True)
        return 0
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(f"Local controller: {error}", file=sys.stderr)
        return 2
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    sys.exit(main())

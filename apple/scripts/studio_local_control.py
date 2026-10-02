#!/usr/bin/env python3
"""Example native Stream local IPC client; commands are sent once, never replayed."""
import argparse
import json
import socket
import sys
import uuid

MAX_FRAME = 65536


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
        self.session = None
        reply = self.request("authenticate", clientID=self.client_id, token=self.token)
        self.token = None
        if reply.get("error"):
            raise ValueError(reply["error"]["message"])
        self.session = str(uuid.UUID(reply["sessionID"]))

    def read(self):
        line = self.reader.readline(MAX_FRAME + 2)
        if not line or not line.endswith(b"\n") or len(line) > MAX_FRAME + 1:
            raise ValueError("Connection closed or response exceeded the local IPC limit")
        reply = json.loads(line)
        if reply.get("version") != 1:
            raise ValueError("Unsupported local IPC response version")
        return reply

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
            if reply.get("id", "").lower() == request_id:
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

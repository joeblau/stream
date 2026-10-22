#!/usr/bin/env python3
"""Link and exercise one owned optional SDK slice with real TCP-only Coturn."""
import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import socket
import subprocess
import tempfile
import time

from build_owned_nice_transport import archive_floor, digest, run


def terminate(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-build-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--turnserver", type=Path, required=True)
    args = parser.parse_args()
    root = args.backend_build_dir.resolve()
    receipt = json.loads((root / "nice-transport-build.json").read_text())
    archive = root / "libdatachannel-nice-complete.a"
    if digest(archive) != receipt["archiveSHA256"]:
        raise RuntimeError("Backend artifact differs from recorded source build")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    binary = output / "owned-nice-tcp-smoke"
    sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True).strip()
    command = ["xcrun", "clang++", "-std=c++17", "-arch", receipt["architecture"], "-mmacosx-version-min=" + receipt["requestedDeploymentTarget"],
               "-isysroot", sdk, "-I" + str(root / "libdatachannel-source/include"), str(Path(__file__).with_name("owned_nice_tcp_smoke.cpp")), str(archive),
               "-framework", "Security", "-framework", "CoreFoundation", *receipt["additionalSystemLinkFlags"], "-o", str(binary)]
    run(*command)
    floor = archive_floor(binary, receipt["architecture"])
    with tempfile.TemporaryDirectory(prefix="stream-owned-nice-tcp-") as temporary:
        owned = Path(temporary)
        os.chmod(owned, 0o700)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        username, credential = secrets.token_hex(16), secrets.token_hex(32)
        config = owned / "turn.conf"
        config.write_text("\n".join([f"listening-port={port}", "listening-ip=127.0.0.1", "relay-ip=127.0.0.1", "min-port=50040", "max-port=50055",
            "realm=owned-fixture.invalid", "lt-cred-mech", f"user={username}:{credential}", "fingerprint", "allow-loopback-peers",
            "allowed-peer-ip=127.0.0.1", "denied-peer-ip=0.0.0.0-255.255.255.255", "no-multicast-peers", "no-udp", "no-tls", "no-tcp-relay",
            "no-stdout-log", "log-file=/dev/null", f"pidfile={owned / 'turn.pid'}", f"userdb={owned / 'turn.db'}", "relay-threads=1", "cpus=2",
            "user-quota=4", "total-quota=4", "max-allocate-lifetime=120"]) + "\n")
        os.chmod(config, 0o600)
        server = peer = None
        try:
            server = subprocess.Popen([str(args.turnserver.resolve()), "-c", str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        break
                except OSError:
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Owned TCP-only Coturn startup failed")
                    time.sleep(0.05)
            peer = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
            peer.stdin.write(f"{port}\n{username}\n{credential}\n".encode())
            peer.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(peer.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=15):
                raise RuntimeError("Owned SDK TCP exchange timed out")
            text = peer.stdout.readline(512).decode()
            selector.close()
            if not text.startswith("PASS owned optional SDK"):
                raise RuntimeError("Owned SDK TCP exchange failed")
            sockets = run("/usr/sbin/lsof", "-nP", "-a", "-p", str(peer.pid), "-iTCP", "-sTCP:ESTABLISHED", "-Fn", capture=True)
            connections = sum(line.startswith("n") and line.endswith(f"->127.0.0.1:{port}") for line in sockets.splitlines())
            udp = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(server.pid), "-iUDP", "-Fn"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if udp.returncode not in (0, 1) or connections < 2 or f"n127.0.0.1:{port}" in udp.stdout.splitlines():
                raise RuntimeError("Selected relay socket restriction receipt failed")
            if peer.wait(timeout=5) != 0:
                raise RuntimeError("Owned SDK TCP cleanup failed")
            proof = {"architecture": receipt["architecture"], "binarySHA256": digest(binary), "backendSHA256": digest(archive), "binaryMinOS": floor,
                     "nativeTCPConnections": connections, "serverUDPListener": False, "result": text.strip(),
                     "scope": "public SDK relay-only bidirectional control; Intel translation is not Intel hardware or full media qualification"}
            (output / "tcp-smoke-result.json").write_text(json.dumps(proof, indent=2) + "\n")
            print(json.dumps(proof))
        finally:
            terminate(peer)
            terminate(server)


if __name__ == "__main__":
    main()

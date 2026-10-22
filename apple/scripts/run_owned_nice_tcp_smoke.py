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
import ssl
import subprocess
import tempfile
import time

from build_owned_nice_transport import archive_floor, digest, run
from owned_turn_tls_fixture import create_fixture


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
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--openssl", type=Path)
    parser.add_argument("--reject", choices=["untrusted", "identity"])
    args = parser.parse_args()
    if args.tls and args.openssl is None or args.reject and not args.tls:
        parser.error("TLS needs an owned OpenSSL executable; rejection applies only to TLS")
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
        tls = create_fixture(owned / "tls", args.openssl, args.reject == "identity") if args.tls else None
        config = owned / "turn.conf"
        listeners = [f"listening-port={port}", "no-tls"]
        if tls:
            with socket.socket() as other:
                other.bind(("127.0.0.1", 0))
                plain_port = other.getsockname()[1]
            listeners = [f"listening-port={plain_port}", f"tls-listening-port={port}", "no-tcp", "no-dtls", "no-tlsv1", "no-tlsv1_1",
                         "cert=" + tls["certificate"], "pkey=" + tls["privateKey"]]
        config.write_text("\n".join([*listeners, "listening-ip=127.0.0.1", "relay-ip=127.0.0.1", "min-port=50040", "max-port=50055",
            "realm=owned-fixture.invalid", "lt-cred-mech", f"user={username}:{credential}", "fingerprint", "allow-loopback-peers",
            "allowed-peer-ip=127.0.0.1", "denied-peer-ip=0.0.0.0-255.255.255.255", "no-multicast-peers", "no-udp", "no-tcp-relay",
            "no-stdout-log", "log-file=/dev/null", f"pidfile={owned / 'turn.pid'}", f"userdb={owned / 'turn.db'}", "relay-threads=1", "cpus=2",
            "user-quota=4", "total-quota=4", "max-allocate-lifetime=120"]) + "\n")
        os.chmod(config, 0o600)
        server = peer = None
        try:
            server = subprocess.Popen([str(args.turnserver.resolve()), "-c", str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2) as probe:
                        if tls:
                            trust = ssl.create_default_context(cafile=tls["caFile"])
                            with trust.wrap_socket(probe, server_hostname=tls["controlIdentity"]) as verified:
                                tls_version = verified.version()
                        break
                except OSError:
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Owned TCP-only Coturn startup failed")
                    time.sleep(0.05)
            env = os.environ.copy()
            if tls:
                env["STREAM_OWNED_TURN_TLS_CA_FILE"] = tls["wrongCAFile"] if args.reject == "untrusted" else tls["caFile"]
            peer = subprocess.Popen([str(binary), *(["--tls"] if tls else []), *(["--expect-reject"] if args.reject else [])],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, env=env)
            peer.stdin.write(f"{port}\n{username}\n{credential}\n".encode())
            peer.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(peer.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=15):
                raise RuntimeError("Owned SDK TCP exchange timed out")
            text = peer.stdout.readline(512).decode()
            selector.close()
            if not text.startswith("PASS owned optional SDK"):
                raise RuntimeError(text.strip() if text.startswith("FAIL owned qualification:") else "Owned SDK TCP exchange failed")
            sockets_result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(peer.pid), "-iTCP", "-sTCP:ESTABLISHED", "-Fn"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if sockets_result.returncode not in (0, 1): raise RuntimeError("Cannot establish owned peer socket receipt")
            sockets = sockets_result.stdout
            connections = sum(line.startswith("n") and line.endswith(f"->127.0.0.1:{port}") for line in sockets.splitlines())
            udp = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(server.pid), "-iUDP", "-Fn"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            listeners = run("/usr/sbin/lsof", "-nP", "-a", "-p", str(server.pid), "-iTCP", "-sTCP:LISTEN", "-Fn", capture=True)
            if {line for line in listeners.splitlines() if line.startswith('n')} != {f"n127.0.0.1:{port}"}:
                raise RuntimeError("Owned TURN server exposed an unexpected plaintext listener")
            if udp.returncode not in (0, 1) or (connections < 2 and not args.reject) or f"n127.0.0.1:{port}" in udp.stdout.splitlines():
                raise RuntimeError("Selected relay socket restriction receipt failed")
            if peer.wait(timeout=5) != 0:
                raise RuntimeError("Owned SDK TCP cleanup failed")
            proof = {"architecture": receipt["architecture"], "binarySHA256": digest(binary), "backendSHA256": digest(archive), "binaryMinOS": floor,
                     "tls": bool(tls), "serverTLSVersion": tls_version if tls else None, "expectedRejection": args.reject,
                     "nativeTCPConnections": connections, "serverUDPListener": False, "result": text.strip(),
                     "scope": "public SDK relay-only bidirectional control; Intel translation is not Intel hardware or full media qualification"}
            (output / "tcp-smoke-result.json").write_text(json.dumps(proof, indent=2) + "\n")
            print(json.dumps(proof))
        finally:
            terminate(peer)
            terminate(server)


if __name__ == "__main__":
    main()

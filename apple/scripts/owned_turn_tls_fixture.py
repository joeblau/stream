#!/usr/bin/env python3
"""Create one disposable TURN server identity and explicit process-local trust.

No trust store, Keychain, DNS or network settings are changed. Private material
remains inside the caller's mode-0700 owned fixture directory.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess


def create_fixture(directory, openssl, bad_identity=False):
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    def command(*args, input=None):
        return subprocess.run([str(openssl), *map(str, args)], input=input, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, check=True).stdout
    ca, ca_key = directory / "ca.pem", directory / "ca.key"
    configuration = directory / "openssl.cnf"
    configuration.write_text("[req]\ndistinguished_name=owned_dn\n[owned_dn]\n")
    wrong_ca, wrong_key = directory / "untrusted-ca.pem", directory / "untrusted-ca.key"
    for cert, key, name in [(ca, ca_key, "Owned TURN fixture CA"), (wrong_ca, wrong_key, "Unrelated owned fixture CA")]:
        command("req", "-config", configuration, "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "2", "-sha256",
                "-subj", "/CN=" + name, "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout", key, "-out", cert)
    key, csr, cert = directory / "server.key", directory / "server.csr", directory / "server.pem"
    command("req", "-config", configuration, "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=Owned TURN fixture", "-keyout", key, "-out", csr)
    extensions = directory / "server.ext"
    extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=" +
                          ("DNS:wrong.fixture.invalid" if bad_identity else "IP:127.0.0.1,DNS:localhost") + "\n")
    command("x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-sha256", "-extfile", extensions, "-out", cert)
    public = command("x509", "-in", cert, "-pubkey", "-noout")
    spki = command("pkey", "-pubin", "-outform", "DER", input=public)
    for path in directory.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)
    return {"caFile": str(ca), "wrongCAFile": str(wrong_ca), "certificate": str(cert), "privateKey": str(key),
            "spkiSHA256": base64.b64encode(hashlib.sha256(spki).digest()).decode(), "badIdentity": bad_identity,
            "controlIdentity": "wrong.fixture.invalid" if bad_identity else "127.0.0.1"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--openssl", required=True, type=Path)
    parser.add_argument("--bad-identity", action="store_true")
    args = parser.parse_args()
    value = create_fixture(args.directory.resolve(), args.openssl.resolve(), args.bad_identity)
    path = args.directory.resolve() / "tls-fixture.json"
    path.write_text(json.dumps(value))
    os.chmod(path, 0o600)
    print(json.dumps({"fixtureCreated": True, "spkiSHA256": value["spkiSHA256"], "badIdentity": args.bad_identity}))

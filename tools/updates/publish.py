#!/usr/bin/env python3
"""Prepare a signed update feed and atomically publish it to the existing site.

The Ed25519 private key stays on the release Mac; only artifacts and a signed
public manifest are uploaded. SSH uses normal user credentials/agent, never a
password in a config file. Requires Python's cryptography package.
"""
import argparse
import base64
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import tempfile
from datetime import date
from pathlib import Path
from urllib.parse import quote, urlparse
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def prepare(package, dmg, version, build, base_url, key_path, output, notes):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or build <= 0:
        raise ValueError("Invalid release version/build")
    endpoint = urlparse(base_url)
    if endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.password:
        raise ValueError("A public HTTPS base URL is required")
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("Signing key must be Ed25519")
    output.mkdir(parents=True, exist_ok=True)
    downloads = output / "downloads"
    downloads.mkdir(exist_ok=True)
    with package.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    name = f"HomePodFlow-{version}-{build}-arm64-{digest[:12]}.pkg"
    published_package = downloads / name
    shutil.copyfile(package, published_package)
    with published_package.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError("Package changed during preparation")
    payload = {
        "schemaVersion": 1, "version": version, "build": build,
        "minimumSystemVersion": "15.0", "architecture": "arm64",
        "packageURL": base_url.rstrip("/") + "/downloads/" + quote(name),
        "sha256": digest, "bytes": published_package.stat().st_size, "notes": notes,
    }
    raw = canonical(payload)
    envelope = {"payload": base64.b64encode(raw).decode(),
                "signature": base64.b64encode(key.sign(raw)).decode()}
    (output / "updates").mkdir(exist_ok=True)
    (output / "updates/latest.json").write_bytes(canonical(envelope))
    website_file = name
    if dmg:
        with dmg.open("rb") as stream:
            dmg_digest = hashlib.file_digest(stream, "sha256").hexdigest()
        website_file = f"HomePodFlow-{version}-{build}-{dmg_digest[:12]}.dmg"
        shutil.copyfile(dmg, downloads / website_file)
    website_path = downloads / website_file
    with website_path.open("rb") as stream:
        website_digest = hashlib.file_digest(stream, "sha256").hexdigest()
    (output / "release.json").write_bytes(canonical({
        "name": "HomePod Flow", "version": version, "build": str(build),
        "date": date.today().isoformat(), "file": website_file,
        "bytes": website_path.stat().st_size, "sha256": website_digest,
        "min_macos": "15.0", "arch": "arm64", "preview": True, "available": True,
    }))
    return payload


def publish(output, host, root, control_path=None):
    if host.startswith("-") or not re.fullmatch(r"[a-zA-Z0-9_.@:-]+", host):
        raise ValueError("Invalid SSH destination")
    if not root.startswith("/") or ".." in Path(root).parts:
        raise ValueError("Remote site root must be absolute")
    options = ["-o", f"ControlPath={control_path}"] if control_path else []
    ssh = ["ssh", *options, host]
    subprocess.run([*ssh, "mkdir -p " + shlex.quote(root + "/downloads") + " " + shlex.quote(root + "/updates")], check=True)
    # Versioned artifacts first; publish pointers last using same-filesystem rename.
    for artifact in sorted((output / "downloads").iterdir()):
        destination = root + "/downloads/" + artifact.name
        subprocess.run(["scp", *options, str(artifact), host + ":" + destination + ".upload"], check=True)
        subprocess.run([*ssh, "mv -- " + shlex.quote(destination + ".upload") + " " + shlex.quote(destination)], check=True)
    for path in ("release.json", "updates/latest.json"):
        destination = root + "/" + path
        subprocess.run(["scp", *options, str(output / path), host + ":" + destination + ".upload"], check=True)
        subprocess.run([*ssh, "mv -- " + shlex.quote(destination + ".upload") + " " + shlex.quote(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--base-url", default="https://homepodflow.mddxz.top")
    parser.add_argument("--key", type=Path, default=Path.home()/".config/homepodflow/update-signing-key.pem")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--notes", default="修复与体验改进；安装后请重新启动 Mac。")
    parser.add_argument("--ssh-host")
    parser.add_argument("--remote-root", default="/opt/sites/homepodflow")
    parser.add_argument("--ssh-control")
    args = parser.parse_args()
    payload = prepare(args.package, args.dmg, args.version, args.build, args.base_url,
                      args.key, args.output, args.notes)
    if args.ssh_host:
        publish(args.output, args.ssh_host, args.remote_root, args.ssh_control)
    print(json.dumps(payload, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()

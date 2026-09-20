#!/usr/bin/env python3
"""Install the exact Zig release from the official HTTPS manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / ".zigversion").read_text().strip()
CHECKSUMS = ROOT / "tools/zig-checksums.json"


def fetch(url: str, destination: Path) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "ziglang.org":
        raise ValueError("The Zig download must use the official HTTPS host")
    request = urllib.request.Request(url, headers={"User-Agent": "Seggs-scaffold/0.1"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def pinned_entry(key: str, version: str) -> dict:
    """Resolve a development build, which the release manifest does not list.

    Zig publishes development builds under /builds/ with no manifest, so the
    expected digest is committed in tools/zig-checksums.json instead of being
    skipped: an unverified download is not an option.
    """
    digests = json.loads(CHECKSUMS.read_text()).get(version, {})
    digest = digests.get(key)
    if digest is None:
        raise ValueError(
            f"No pinned checksum for Zig {version} on {key}. Download the archive from "
            f"https://ziglang.org/builds/, verify it, and add the sha256 to tools/zig-checksums.json."
        )
    # Windows builds are published as ZIP archives; every other host as tar.xz.
    extension = "zip" if key.endswith("-windows") else "tar.xz"
    return {"tarball": f"https://ziglang.org/builds/zig-{key}-{version}.{extension}", "shasum": digest}


def install(destination: Path, version: str) -> None:
    destination = destination.resolve()
    if destination.exists():
        raise FileExistsError(f"Destination exists: {destination}. Remove it explicitly before replacement.")
    systems = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}
    arches = {"x86_64": "x86_64", "AMD64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
    key = f"{arches[platform.machine()]}-{systems[platform.system()]}"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="seggs-zig-", dir=destination.parent) as temp:
        directory = Path(temp)
        if "-dev." in version:
            entry = pinned_entry(key, version)
        else:
            # Released versions carry their digests in Zig's own manifest.
            manifest = directory / "index.json"
            fetch("https://ziglang.org/download/index.json", manifest)
            entry = json.loads(manifest.read_text())[version][key]
        archive = directory / Path(urllib.parse.urlparse(entry["tarball"]).path).name
        fetch(entry["tarball"], archive)
        with archive.open("rb") as file:
            digest = hashlib.file_digest(file, "sha256").hexdigest()
        if digest.lower() != entry["shasum"].lower():
            raise ValueError("Zig archive checksum mismatch")
        extracted = directory / "extract"
        extracted.mkdir()
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as file:
                for member in file.infolist():
                    path = (extracted / member.filename).resolve()
                    if not path.is_relative_to(extracted.resolve()):
                        raise ValueError("Unsafe archive path")
                    if (member.external_attr >> 16) & 0o170000 == 0o120000:
                        raise ValueError("Unexpected symbolic link in ZIP")
                file.extractall(extracted)
        else:
            with tarfile.open(archive, "r:*") as file:
                file.extractall(extracted, filter="data")
        roots = list(extracted.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise ValueError("Unexpected Zig archive layout")
        shutil.move(str(roots[0]), destination)
        (destination / "SEGGS-MANIFEST.json").write_text(json.dumps({"version": VERSION, "target": key, **entry}, indent=2) + "\n")
    print(f"Installed Zig {version}: {destination}")
    if os.name == "nt":
        print(f'$env:Path = "{destination};$env:Path"')
    else:
        print(f'export PATH="{destination}:$PATH"')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / ".deps/zig")
    parser.add_argument("--version", default=VERSION, help="Zig release or development build to install")
    args = parser.parse_args()
    install(args.destination, args.version)


if __name__ == "__main__":
    main()

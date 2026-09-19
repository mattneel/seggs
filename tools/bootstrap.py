#!/usr/bin/env python3
"""Build pinned SDL source releases into a local prefix. No sudo command runs."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "dependencies.json").read_text())


def run(argv: list[str], cwd: Path | None = None) -> None:
    print("+ " + " ".join(argv), flush=True)
    subprocess.run(argv, cwd=cwd, check=True)


def checkout(name: str, url: str, tag: str) -> tuple[Path, str]:
    path = ROOT / ".deps/src" / name
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", "--branch", tag, url, str(path)])
    head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    tagged = subprocess.check_output(["git", "-C", str(path), "rev-parse", f"{tag}^{{commit}}"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"], text=True).strip()
    if head != tagged or dirty:
        raise RuntimeError(f"Unexpected or modified source checkout: {path}")
    return path, head


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / ".deps/install")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument("--install-zig", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if platform.system() not in ("Linux", "Darwin"):
        parser.error("This bootstrap supports Linux and macOS. See docs/BUILD.md for Windows SDK setup.")
    for command in ("git", "cmake", "pkg-config"):
        if shutil.which(command) is None:
            parser.error(f"Missing {command}. See docs/BUILD.md.")
    if args.install_zig:
        run([sys.executable, str(ROOT / "tools/install_zig.py")])
    prefix = args.prefix.resolve()
    resolved = {}
    for name in ("SDL", "SDL_ttf"):
        pin = PINS[name]
        source, commit = checkout(name, pin["repository"], pin["tag"])
        resolved[name] = {**pin, "commit": commit}
        build = ROOT / ".deps/build" / name
        flags = [
            f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_PREFIX_PATH={prefix}",
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_LIBDIR=lib",
            f"-DCMAKE_INSTALL_RPATH={prefix / 'lib'}", "-DBUILD_SHARED_LIBS=ON",
        ]
        if name == "SDL":
            flags += ["-DSDL_SHARED=ON", "-DSDL_STATIC=OFF", "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF"]
            if platform.system() == "Linux":
                flags += ["-DSDL_X11=ON", "-DSDL_WAYLAND=OFF"]
        else:
            flags += ["-DSDLTTF_SAMPLES=OFF", "-DSDLTTF_VENDORED=OFF", "-DSDLTTF_HARFBUZZ=OFF", "-DSDLTTF_PLUTOSVG=OFF"]
        run(["cmake", "-S", str(source), "-B", str(build), *flags])
        run(["cmake", "--build", str(build), "--parallel", str(args.jobs)])
        run(["cmake", "--install", str(build)])
    (ROOT / ".deps/resolved.json").write_text(json.dumps(resolved, indent=2) + "\n")
    print(f"SDL SDK prefix: {prefix}")
    print("Zig toolchain, Vulkan driver, and system fonts remain external prerequisites.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build pinned libghostty-vt into a prefix. Runs on Linux, macOS, and Windows.

The library is built by the Zig release Ghostty's own manifest names, not by the
release in .zigversion, and reaches the editor through its C API. Keeping this
in its own script lets the platform jobs that do not use the SDL bootstrap build
it the same way.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "dependencies.json").read_text())


def run(argv: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    print("+ " + " ".join(argv), flush=True)
    subprocess.run(argv, cwd=cwd, check=True, env=env)


def checkout(name: str, url: str, commit: str) -> Path:
    """Fetch one commit: no branch carries a pinned commit."""
    path = ROOT / ".deps/src" / name
    if not path.exists():
        path.mkdir(parents=True)
        run(["git", "init", "--quiet", str(path)])
        run(["git", "-C", str(path), "fetch", "--depth", "1", url, commit])
        run(["git", "-C", str(path), "checkout", "--quiet", "FETCH_HEAD"])
    head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if head != commit:
        raise RuntimeError(f"Unexpected source checkout: {path} at {head}, expected {commit}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / ".deps/install")
    args = parser.parse_args()
    pin = PINS["ghostty"]
    prefix = args.prefix.resolve()
    stamp = prefix / "lib" / "libghostty-vt.commit"
    if stamp.exists() and stamp.read_text().strip() == pin["commit"]:
        print(f"libghostty-vt {pin['commit'][:12]} is already built in {prefix}")
        return 0
    toolchain = ROOT / ".deps/zig-ghostty"
    if not (toolchain / ("zig.exe" if os.name == "nt" else "zig")).exists():
        run([sys.executable, str(ROOT / "tools/install_zig.py"),
             "--destination", str(toolchain), "--version", pin["zig"]])
    source = checkout("ghostty", pin["repository"], pin["commit"])
    environment = {**os.environ, "PATH": f"{toolchain}{os.pathsep}{os.environ['PATH']}"}
    run([str(toolchain / "zig"), "build", "-Demit-lib-vt", "-Doptimize=ReleaseFast"],
        cwd=source, env=environment)
    (prefix / "lib").mkdir(parents=True, exist_ok=True)
    if (prefix / "include/ghostty").exists():
        shutil.rmtree(prefix / "include/ghostty")
    (prefix / "include").mkdir(parents=True, exist_ok=True)
    # Every artifact the build produced, not just the first: a platform that
    # emits a shared library also emits the import library next to it, and a
    # binary that finds one without the other fails at startup rather than at
    # link time.
    # The archive is what the editor links; a Windows build also emits the DLL
    # that the linked binary loads at startup, and that one has to be installed
    # next to it or the process dies before it prints anything. The Unix shared
    # library is for embedding, which this repository does not do.
    # A shared library is emitted into bin, not lib, and a binary that links
    # the import library beside it fails at startup unless the DLL travels too.
    source_lib = source / "zig-out/lib"
    source_bin = source / "zig-out/bin"
    built = [
        p for p in sorted(source_lib.glob("*"))
        if p.name.startswith(("libghostty-vt", "ghostty-vt")) and p.suffix in (".a", ".lib", ".dll")
    ]
    built += [
        p for p in sorted(source_bin.glob("*"))
        if p.name.startswith(("libghostty-vt", "ghostty-vt")) and p.suffix in (".dll", ".so", ".dylib")
    ]
    if not built:
        listing = ", ".join(sorted(p.name for p in source_lib.glob("*"))) or "nothing"
        raise RuntimeError(f"libghostty-vt was not produced; zig-out/lib holds {listing}")
    # The headers travel with the library: the editor translates its own
    # bindings from them.
    for artifact in built:
        # A shared library goes where the loader looks for it, which on Windows
        # is beside the executable or on the path, not in lib.
        if artifact.suffix == ".dll":
            (prefix / "bin").mkdir(parents=True, exist_ok=True)
            shutil.copy2(artifact, prefix / "bin" / artifact.name)
        shutil.copy2(artifact, prefix / "lib" / artifact.name)
    installed = ", ".join(a.name for a in built)
    shutil.copytree(source / "zig-out/include/ghostty", prefix / "include/ghostty")
    stamp.write_text(pin["commit"] + "\n")
    print(f"libghostty-vt {pin['commit'][:12]} built with Zig {pin['zig']} into {prefix}: {installed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

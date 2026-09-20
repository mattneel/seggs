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


def run(argv: list[str], cwd: Path | None = None, env: dict | None = None) -> None:
    print("+ " + " ".join(argv), flush=True)
    subprocess.run(argv, cwd=cwd, check=True, env=env)


def checkout(name: str, url: str, tag: str) -> tuple[Path, str]:
    path = ROOT / ".deps/src" / name
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        if len(tag) == 40 and all(c in "0123456789abcdef" for c in tag):
            # A commit pin: no branch carries it, so fetch that one and stop.
            path.mkdir(parents=True)
            run(["git", "init", "--quiet", str(path)])
            run(["git", "-C", str(path), "fetch", "--depth", "1", url, tag])
            run(["git", "-C", str(path), "checkout", "--quiet", "FETCH_HEAD"])
        else:
            run(["git", "clone", "--depth", "1", "--branch", tag, url, str(path)])
    head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    tagged = subprocess.check_output(["git", "-C", str(path), "rev-parse", f"{tag}^{{commit}}"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"], text=True).strip()
    if head != tagged or dirty:
        raise RuntimeError(f"Unexpected or modified source checkout: {path}")
    return path, head


def build_ghostty(prefix: Path) -> dict:
    """Build libghostty-vt with the Zig release its own pin names.

    The library is C-ABI, so the editor links it with the project toolchain
    while the library itself is built by the release Ghostty requires. The
    alternative -- building it from this project's build -- would need the
    dependency ported to a Zig the dependency does not support yet.
    """
    pin = PINS["ghostty"]
    toolchain = ROOT / ".deps/zig-ghostty"
    if not (toolchain / "zig").exists():
        run([sys.executable, str(ROOT / "tools/install_zig.py"),
             "--destination", str(toolchain), "--version", pin["zig"]])
    source, commit = checkout("ghostty", pin["repository"], pin["commit"])
    environment = {**os.environ, "PATH": f"{toolchain}{os.pathsep}{os.environ['PATH']}"}
    run([str(toolchain / "zig"), "build", "-Demit-lib-vt", "-Doptimize=ReleaseFast"],
        cwd=source, env=environment)
    (prefix / "lib").mkdir(parents=True, exist_ok=True)
    (prefix / "include").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "zig-out/lib/libghostty-vt.a", prefix / "lib/libghostty-vt.a")
    if (prefix / "include/ghostty").exists():
        shutil.rmtree(prefix / "include/ghostty")
    shutil.copytree(source / "zig-out/include/ghostty", prefix / "include/ghostty")
    return {"repository": pin["repository"], "commit": commit, "zig": pin["zig"]}


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
    resolved["ghostty"] = build_ghostty(prefix)
    (ROOT / ".deps/resolved.json").write_text(json.dumps(resolved, indent=2) + "\n")
    print(f"SDL SDK prefix: {prefix}")
    print("Zig toolchain, Vulkan driver, and system fonts remain external prerequisites.")


if __name__ == "__main__":
    main()

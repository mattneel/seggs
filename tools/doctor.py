#!/usr/bin/env python3
"""Report local prerequisites without installation or agent execution."""
from __future__ import annotations

import argparse
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / ".deps/install")
    args = parser.parse_args()
    failures = 0
    expected = (ROOT / ".zigversion").read_text().strip()
    zig = shutil.which("zig")
    version = subprocess.check_output([zig, "version"], text=True).strip() if zig else "absent"
    print(f"Zig: {version} (required: {expected})")
    failures += version != expected
    for header in ("SDL3/SDL.h", "SDL3_ttf/SDL_ttf.h"):
        path = args.prefix / "include" / header
        print(f"Header: {path} [{'OK' if path.exists() else 'absent'}]")
        failures += not path.exists()
    if platform.system() != "Darwin":
        compiler = shutil.which("glslangValidator")
        print(f"glslangValidator: {compiler or 'absent'}")
        failures += compiler is None
    for command in ("omp", "codex-acp", "claude-agent-acp", "python3"):
        print(f"Optional agent command: {command}: {shutil.which(command) or 'absent'}")
    print("This report does not test the GPU, shared-library ABI, fonts, or agent authentication.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

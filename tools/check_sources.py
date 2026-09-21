#!/usr/bin/env python3
"""Check the sources the build compiles itself are present.

The engine behind display math, and the XML parser it reads its resource
mappings with, are fetched rather than built: `build.zig` compiles them, so a
tree that has not run the bootstrap cannot build the editor.

This runs as a step of that library rather than as part of the configure, which
is what keeps `zig build test` working on a machine that has only the Zig
toolchain - the core tests need none of these. It exists because the compiler's
own error names the first missing file and not what to do about it.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEEDED = {".deps/src/MicroTex": "the engine behind display math", ".deps/src/tinyxml2": "the XML parser it reads with"}

missing = [f"{path} ({what})" for path, what in NEEDED.items() if not (ROOT / path).is_dir()]
if missing:
    print("missing: " + ", ".join(missing), file=sys.stderr)
    print("fetch them with `python3 tools/bootstrap.py --sources-only`.", file=sys.stderr)
    sys.exit(1)

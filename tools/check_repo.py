#!/usr/bin/env python3
"""Static repository checks. These checks do not compile or parse Zig semantically."""
from __future__ import annotations

import ast
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FONT_EXTENSIONS = {".ttf", ".otf", ".ttc", ".woff", ".woff2"}
# Build output and vendored caches, which are not part of the repository's own
# sources. The built book carries the theme fonts mdBook bundles.
IGNORED = {".git", ".deps", ".zig-cache", "zig-out", "__pycache__", "zig-pkg", "node_modules", "dist", "book"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def zig_delimiters(path: Path) -> None:
    """Check delimiters after comments and strings. This is not a Zig parser."""
    source = path.read_text()
    stack: list[tuple[str, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    offset = 0
    line = 1
    while offset < len(source):
        char = source[offset]
        if char == "\n":
            line += 1
            offset += 1
        elif source.startswith("//", offset) or source.startswith("\\\\", offset):
            end = source.find("\n", offset)
            offset = len(source) if end < 0 else end
        elif char in ('"', "'"):
            quote = char
            offset += 1
            closed = False
            while offset < len(source):
                if source[offset] == "\\":
                    offset += 2
                elif source[offset] == quote:
                    offset += 1
                    closed = True
                    break
                else:
                    require(source[offset] != "\n", f"{path}:{line}: newline inside literal")
                    offset += 1
            require(closed, f"{path}:{line}: unclosed literal")
        elif char in "([{":
            stack.append((char, line))
            offset += 1
        elif char in ")]}":
            require(bool(stack) and stack[-1][0] == pairs[char], f"{path}:{line}: delimiter mismatch")
            stack.pop()
            offset += 1
        else:
            offset += 1
    require(not stack, f"{path}: unclosed delimiters: {stack}")


def config_check(path: Path) -> None:
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f"{path}: config is not an object")
    require(set(value) <= {"fullscreen", "agents", "persist_transcripts", "lsp"}, f"{path}: unknown config field")
    require(isinstance(value.get("fullscreen", True), bool), f"{path}: invalid fullscreen")
    agents = value.get("agents", [])
    require(isinstance(agents, list) and 1 <= len(agents) <= 8, f"{path}: invalid agent count")
    ids = set()
    for agent in agents:
        require(set(agent) <= {"id", "name", "argv", "cwd"}, f"{path}: unknown agent field")
        for key, minimum in (("id", 33), ("name", 32)):
            text = agent.get(key)
            require(isinstance(text, str) and 1 <= len(text) <= 64, f"{path}: invalid {key}")
            require(all(minimum <= ord(char) <= 126 for char in text), f"{path}: non-ASCII {key}")
        require(agent["id"] not in ids, f"{path}: duplicate ID")
        ids.add(agent["id"])
        argv = agent.get("argv")
        require(isinstance(argv, list) and 1 <= len(argv) <= 64, f"{path}: invalid argv")
        require(all(isinstance(arg, str) and len(arg.encode()) <= 16384 and "\0" not in arg for arg in argv), f"{path}: invalid argument")
        require(bool(argv[0]), f"{path}: empty executable")
        cwd = agent.get("cwd")
        if cwd is not None:
            require(isinstance(cwd, str) and "\0" not in cwd, f"{path}: invalid cwd")
            require(cwd.startswith(("/", "\\\\")) or bool(re.match(r"^[A-Za-z]:[/\\]", cwd)), f"{path}: relative cwd")


def main() -> int:
    files = [p for p in ROOT.rglob("*") if p.is_file() and not any(part in IGNORED for part in p.relative_to(ROOT).parts)]
    for required in ("build.zig", "src/main.zig", "src/smoke.zig", "src/tests.zig", "README.md", "LICENSE", "SECURITY.md", "docs/VALIDATION.md", ".github/workflows/ci.yml"):
        require((ROOT / required).is_file(), f"Missing {required}")
    # The pinned toolchain lives in .zigversion; the manifest must agree with it
    # rather than hardcoding a version that rots on every toolchain bump.
    zig_version = (ROOT / ".zigversion").read_text().strip()
    require(zig_version != "", "Missing Zig version pin")
    manifest = json.loads((ROOT / "dependencies.json").read_text())
    require(manifest["zig"] == zig_version, f"Dependency version mismatch: {manifest['zig']} != {zig_version}")
    zig_count = 0
    test_count = 0
    for path in files:
        require(path.suffix.lower() not in FONT_EXTENSIONS, f"Font redistribution: {path}")
        if path.suffix in (".zig", ".py", ".md", ".json", ".h", ".glsl", ".metal", ".yml"):
            text = path.read_text(encoding="utf-8")
            require("\0" not in text, f"NUL in source: {path}")
        if path.suffix == ".py":
            ast.parse(path.read_text(), filename=str(path))
        if path.suffix == ".json":
            json.loads(path.read_text())
        if path.suffix == ".zig":
            zig_count += 1
            text = path.read_text()
            test_count += len(re.findall(r'^test "', text, re.MULTILINE))
            zig_delimiters(path)
            for imported in re.findall(r'@import\("([^\"]+)"\)', text):
                if imported.endswith(".zig"):
                    require((path.parent / imported).resolve().is_file(), f"Missing Zig import in {path}: {imported}")
            for obsolete in ("@cImport(", "std.process.Child", "std.process.argsAlloc", "std.io.getStd"):
                require(obsolete not in text, f"Obsolete API in {path}: {obsolete}")
        if path.suffix == ".md":
            for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
                if "://" in target or target.startswith("#"):
                    continue
                target = target.split("#", 1)[0]
                require((path.parent / target).is_file(), f"Broken local link in {path}: {target}")
    for path in (ROOT / "config").glob("*.json"):
        if not path.name.endswith(".schema.json"):
            config_check(path)
    renderer = (ROOT / "src/gpu/renderer.zig").read_text()
    for call in ("SDL_CreateGPUDevice", "SDL_CreateGPUGraphicsPipeline", "SDL_UploadToGPUBuffer", "SDL_BeginGPURenderPass", "SDL_DrawGPUPrimitives", "SDL_SubmitGPUCommandBuffer"):
        require(call in renderer, f"Missing GPU path: {call}")
    require("SDL_CreateRenderer" not in renderer, "Unexpected SDL_Renderer path")
    require("set = 2, binding = 0" in (ROOT / "shaders/ui.frag.glsl").read_text(), "Shader binding mismatch")
    client = (ROOT / "src/acp/client.zig").read_text()
    require(".mcpServers = [0]struct {}{}" in client, "mcpServers must encode as an array")
    require('.readTextFile = true' in client and '.writeTextFile = true' in client, "Filesystem capability not advertised")
    require('"fs/read_text_file"' in client and '"fs/write_text_file"' in client, "Filesystem capability advertised but not implemented")
    require('.terminal = true' in client, "Terminal capability not advertised")
    terminal_methods = ('"terminal/create"', '"terminal/output"', '"terminal/wait_for_exit"', '"terminal/kill"', '"terminal/release"')
    require(all(method in client for method in terminal_methods), "Terminal capability advertised but not implemented")
    require('"allow_once"' in client and '"reject_once"' in client, "Permission choices absent")
    # The book is built from docs/, so a chapter nobody listed would exist in the
    # repository and be missing from the book.
    summary = ROOT / "docs/SUMMARY.md"
    require(summary.is_file(), "Missing docs/SUMMARY.md")
    summary_text = summary.read_text()
    for chapter in sorted((ROOT / "docs").glob("*.md")):
        if chapter.name == "SUMMARY.md":
            continue
        require(
            f"({chapter.name})" in summary_text,
            f"docs/{chapter.name} is not listed in docs/SUMMARY.md",
        )
    # Yoga is C++ behind a C API. One header names it, and everything else goes
    # through the translate-c module so the boundary stays enforceable.
    for path in (ROOT / "src").rglob("*.zig"):
        text = path.read_text()
        require('@include("yoga/' not in text, f"Direct Yoga include in {path}")
        require("@cImport(" not in text, f"Direct C import in {path}")
    yoga_header = ROOT / "src/ui/yoga.h"
    require(yoga_header.is_file(), "Missing Yoga boundary header")
    require("yoga/Yoga.h" in yoga_header.read_text(), "Yoga boundary header does not include Yoga")
    build = (ROOT / "build.zig").read_text()
    require("addTranslateC" in build and "addOutputFileArg" in build, "Native or shader build step absent")
    require("yoga/Yoga.h" in (ROOT / "src/ui/yoga.h").read_text(), "Yoga boundary absent")
    require('b.dependency("yoga"' in build, "Yoga dependency absent from the build")
    # A workflow naming a build step or script that no longer exists would only
    # fail on a runner, so the definition is checked here instead.
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    steps = set(re.findall(r'b\.step\("([a-z0-9-]+)"', build))
    for target in sorted(set(re.findall(r"zig build ([a-z0-9-]+)", workflow))):
        require(target in steps, f"CI runs a build step that does not exist: {target}")
    for script in sorted(set(re.findall(r"python3? ([a-zA-Z0-9_./-]+\.py)", workflow))):
        require((ROOT / script).is_file(), f"CI runs a script that does not exist: {script}")
    print(f"PASS: {len(files)} repository files, {zig_count} Zig sources, {test_count} declared Zig tests")
    print("PASS: relative imports, JSON configs, Python syntax, local links, GPU/ACP source contracts, CI definition targets, and font exclusion")
    print("Zig checks cover delimiters and source contracts only. Native compilation remains a separate gate.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, SyntaxError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Screenshot gate for the GPU path.

Renders the UI twice offscreen through `--screenshot`, then checks that the two
independent readbacks agree and that the frame holds real content rather than an
empty clear color. A blank frame, a lost glyph atlas, or a nondeterministic
renderer all fail this gate.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
import subprocess
import sys
from pathlib import Path

TOLERANCE = 8  # per-channel difference at or below which pixels still match
MAX_DIFF_FRACTION = 0.01  # share of pixels allowed to exceed TOLERANCE
MIN_DISTINCT_COLORS = 16  # a flat clear color yields far fewer
BG = bytes((0x10, 0x12, 0x16))  # theme background
PANEL = bytes((0x16, 0x19, 0x1f))  # theme panel, drawn by solid quads
ASCII_FIXTURE = "ascii only sample\n"
# Fixtures whose codepoints the monospace primary face lacks, so only a
# fallback face can draw them. One script family per case: a chain that covers
# CJK through a CJK face says nothing about Greek or Cyrillic.
SCRIPT_FIXTURES = (
    ("Cyrillic and Greek", "\u041f\u0440\u0438\u0432\u0435\u0442 \u03ba\u03cc\u03c3\u03bc\u03b5\n"),
    ("CJK", "\u65e5\u672c\u8a9e\n\u4e2d\u6587\u6d4b\u8bd5\n"),
)
RUN_TIMEOUT = 120
# Frames for the records fixture. Its turn is streamed with pauses - so a frame
# can be drawn while a run is still arriving - and the click happens after the
# turn, so the run has to outlast both.
RECORDS_FRAMES = 200
ATLAS_LINE = re.compile(r"atlas: (\d+) glyphs packed, (\d+) placeholder hits")
WINDOW_LINE = re.compile(r"window after step (\d+): logical (\d+)x(\d+), pixels (\d+)x(\d+)")
SCALE_LINE = re.compile(r"logical (\d+)x(\d+), pixels (\d+)x(\d+), scale (\d+\.\d+)")
METRICS_LINE = re.compile(r"atlas: advance ([0-9.]+), line height ([0-9.]+)")
EXTENSION_LINE = re.compile(r"extensions: (\d+) loaded")
PANEL_CLICK = re.compile(r"click: status is now panel (\S+): clicked (.+)")
RUN_LINE = re.compile(r"run (\S+): (\d+) steps, (\d+) artifacts, current=(\S+)")
TABS_COPY = re.compile(r"tabs: copy reported Copied (\d+) byte")

EXIT_LINE = re.compile(r"after exit (\d+) shell\(s\) remain, dock is (\w+)")
TABS_LINE = re.compile(r"tabs: (\d+) open, showing (\d+) of (\d+)")

COMPOSE_LINE = re.compile(r"compose (\S+): (\d+) steps, (.+)")

COMMAND_LINE = re.compile(r"terminal: (the shell marked its command: (.+)|this shell reports no command boundaries)")

REVIEW_LINE = re.compile(r"review: (\d+) change\(s\) waiting, accepted=(true|false)")
ANSWER_LINE = re.compile(r"run (\S+): (\d+) steps, (\d+) artifacts, (\S+) from (.+?), (\d+) bytes")

AGENT_TAB_LINE = re.compile(r"agent tab: clicked (.+), now on (.+)")
# A step the click fixture could not take, in the fixture's own words. The run
# that checks the dock has a window wide enough for it and a lane to put in it,
# so there is nothing it is allowed to leave undone: a step quietly dropped is
# worse than one that fails, and this line is how a dropped one is caught.
CLICK_PROBLEM = re.compile(r"click: (?:skipped|FAIL) - (.+)")
AGENT_JUMP_LINE = re.compile(r"agents: jump list: (.+)")
AGENT_KEY_LINE = re.compile(r"agents: jump key: (.+)")
AGENT_SEND_LINE = re.compile(r"agents: send to: (.+)")
AGENT_CLOSE_LINE = re.compile(r"agents: close: (.+)")
BUFFER_CLOSE_LINE = re.compile(r"agents: close buffer: (.+)")

HOVER_LINE = re.compile(r"hover (\S+) (\S+)")
APP_ACTION = re.compile(r"app action: (\S+)")
EDITOR_OPEN = re.compile(r"open: status is now Opened (.+)")
IME_COMPOSITION = re.compile(r"ime: composition (\d+) cell\(s\), selection (\d+)\.\.(\d+)")
IME_COMMIT = re.compile(r"ime: committed, document (\d+) -> (\d+) byte\(s\)")
# The tool call chips the transcript drew, and what the click on one did. The
# words are the chip's own, so a chip that stopped naming its kind or its state
# fails here rather than only looking different.
CALLS_LINE = re.compile(r"calls: (\d+) drawn, (.+)")
# The turn the records fixture answers with: the runs a reader meets (what each
# line says and whether it is still arriving), the plans, the usage row, the
# mode, the session's name, the commands it accepts and the compaction.
RECORDS_LINE = re.compile(r"records: (\d+) runs drawn, (.+)")
# The picture the records turn carries, as the census names it: what it is, the
# size it decoded to, and the size it was drawn at. A picture that stopped being
# drawn - or one that was counted as a part nobody could read - fails here.
RECORDS_IMAGE = re.compile(r"images: image/png \u00b7 (\d+)\u00d7(\d+) \u00b7 (\d+) B \u00b7 shown (\d+)\u00d7(\d+) ")
# The fixture's four quadrant colours. The picture is small enough to be drawn at
# its own size, so each 8x8 quadrant is the colour that was sent, less the pixels
# the diagonal crosses.
QUADRANTS = ((220, 60, 60), (60, 200, 90), (60, 120, 240), (240, 200, 60))
QUADRANT_PIXELS = 32
RECORDS_PULSE = re.compile(r"records: mid-turn (.+)")
RECORDS_CLICK_LINE = re.compile(r"records: the click on the reasoning changed open (true|false) -> (true|false)")
RECORDS_OPEN_LINE = re.compile(r"records: open (.+)")
CALL_CLICK_LINE = re.compile(r"calls: the click on the (\S+) changed open (true|false) -> (true|false)")
# What the transcript panel says it drew, by block kind, from its own count of
# the rows it put on the screen.
MARKDOWN_BLOCKS = re.compile(r"transcript: blocks drawn: (.+)")
LINK_CLICK = re.compile(r"transcript: a click on a link says: Opened (\S+)")
MARKDOWN_FRAMES = 40
# A tool call that embeds a terminal: the agent creates one through the client,
# names it in a call, waits for it, and releases it. What the gate reads is the
# count the *drawing* takes, which is above zero only where a screen was drawn.
EMBEDDED_LINE = re.compile(r"embedded: (\d+) terminal\(s\) drawn after the agent released it; calls: (.+)")
EMBEDDED_FRAMES = 200
CALL_CHIP_WORDS = ("read \u2713", "edit \u2713", "run \u2717", "run \u25cf")
CALL_FRAMES = 130
# The composition is drawn in the theme's amber; nothing else in a session
# without a pending agent request uses that color.
AMBER = (200, 170, 225, 160)
RESIZE_TARGET = (900, 640)
# Five long runs of one wide glyph: the densest rows in the frame are the
# fixture's own, so measuring them does not depend on the panel layout.
GLYPH_RUN = 60
# Ink-to-ink spacing inside one run of a glyph, in device pixels.
GLYPH_GAP = 4
SCALE_FIXTURE = ("H" * GLYPH_RUN + "\n") * 5
# Alternating capitals and periods: both sit on the baseline, but a period's ink
# stops just above it while a capital reaches the cap height. A renderer that
# places each glyph's ink box at the top of the line gets these the wrong way
# round, which is what a period drawn as an apostrophe looks like.
# One line of capitals, one of periods. The periods sit on the same baseline as
# the capitals one line below them, so a renderer that puts each ink box at the
# top of its line lifts every period clear of that baseline.
# The leading empty line keeps the fixture off the caret row: the caret is drawn
# as a rect spanning the whole line height, which would read as glyph ink.
BASELINE_FIXTURE = "\n" + "H" * GLYPH_RUN + "\n" + "." * GLYPH_RUN + "\n"
DOT_HEIGHT = 4  # device pixels a period may cover


# The dock's frame region at the default window size: the terminal occupies the
# editor's column below the text, and a shell's prompt is the first thing in it.
DOCK_REGION = (250, 636, 740, 240)


def count_ink(pixels: bytes, width: int, height: int, x0: int, y0: int, w: int, h: int) -> int:
    """Pixels in a region that are brighter than the panel behind them."""
    lit = 0
    for y in range(y0, min(y0 + h, height)):
        row = y * width * 3
        for x in range(x0, min(x0 + w, width)):
            i = row + x * 3
            if pixels[i] > 100 and pixels[i + 1] > 100:
                lit += 1
    return lit


def parse_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    parts = data.split(b"\n", 3)
    if len(parts) != 4 or parts[0] != b"P6":
        raise ValueError(f"{path}: not a binary PPM")
    width, height = (int(value) for value in parts[1].split())
    if parts[2] != b"255":
        raise ValueError(f"{path}: unexpected maxval {parts[2]!r}")
    pixels = parts[3]
    expected = width * height * 3
    if len(pixels) != expected:
        raise ValueError(f"{path}: expected {expected} bytes, found {len(pixels)}")
    return width, height, pixels


def describe(path: Path, image: tuple[int, int, bytes]) -> None:
    width, height, pixels = image
    colors = {pixels[i : i + 3] for i in range(0, len(pixels), 3)}
    background = sum(1 for i in range(0, len(pixels), 3) if pixels[i : i + 3] == BG)
    print(f"{path}: {width}x{height}, {len(colors)} distinct colors, {background} background pixels")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check_content(path: Path, image: tuple[int, int, bytes]) -> None:
    width, height, pixels = image
    require(width > 0 and height > 0, f"{path}: empty frame")
    colors = {pixels[i : i + 3] for i in range(0, len(pixels), 3)}
    require(len(colors) >= MIN_DISTINCT_COLORS, f"{path}: only {len(colors)} distinct colors; the frame looks blank")
    # The window is drawn over the clear color, so the theme background must
    # appear but must not cover the whole frame.
    background = sum(1 for i in range(0, len(pixels), 3) if pixels[i : i + 3] == BG)
    total = width * height
    require(background < total, f"{path}: no drawn content over the clear color")


def check_solid_quads(path: Path, image: tuple[int, int, bytes]) -> None:
    """Panels are solid quads sampling one reserved white texel of the atlas.

    That makes every rectangle depend on a single pixel, so it is checked
    directly: the frame must still contain the panel color the quad passes in.
    """
    width, height, pixels = image
    found = 0
    for index in range(0, width * height * 3, 3):
        if pixels[index : index + 3] == PANEL:
            found += 1
    require(found > 0, f"{path}: no solid quad drew the panel color, so rectangles are not rendering")
    return


def compare(a: tuple[int, int, bytes], b: tuple[int, int, bytes]) -> None:
    (aw, ah, ap), (bw, bh, bp) = a, b
    require((aw, ah) == (bw, bh), f"size mismatch: {aw}x{ah} vs {bw}x{bh}")
    differing = 0
    worst = 0
    total = aw * ah
    left, top, right, bottom = aw, ah, -1, -1
    eighths = [0] * 8
    for i in range(0, len(ap), 3):
        delta = max(abs(ap[i] - bp[i]), abs(ap[i + 1] - bp[i + 1]), abs(ap[i + 2] - bp[i + 2]))
        if delta > TOLERANCE:
            differing += 1
            pixel = i // 3
            x, y = pixel % aw, pixel // aw
            left, top = min(left, x), min(top, y)
            right, bottom = max(right, x), max(bottom, y)
            eighths[min(7, x * 8 // aw)] += 1
        if delta > worst:
            worst = delta
    fraction = differing / total if total else 0.0
    print(f"compare: max channel delta {worst}, {differing}/{total} pixels differ ({fraction:.4%})")
    if differing:
        # Where they differ says which panel changed, which a count cannot.
        print(f"compare: differences span ({left},{top}) to ({right},{bottom}); by eighth across: {eighths}")
    require(
        fraction <= MAX_DIFF_FRACTION,
        f"captures disagree: {fraction:.4%} of pixels differ, limit {MAX_DIFF_FRACTION:.2%}",
    )


def app_output(result: subprocess.CompletedProcess) -> str:
    """The app's log, in whichever stream the display wrapper used.

    Without a display the gate runs the app through `xvfb-run`, which merges the
    command's stderr into stdout, so the same lines arrive on the other stream.
    """
    return (result.stdout or "") + (result.stderr or "")


VALIDATION_LAYER = "VK_LAYER_KHRONOS_validation"
LAYER_DIRS = (
    Path("/usr/share/vulkan/explicit_layer.d"),
    Path("/usr/local/share/vulkan/explicit_layer.d"),
    Path("/etc/vulkan/explicit_layer.d"),
    Path("/opt/homebrew/share/vulkan/explicit_layer.d"),
)
_reported_missing_layer = False


def find_validation_layer() -> Path | None:
    """The Khronos validation layer, wherever this host keeps its manifests."""
    for directory in LAYER_DIRS:
        for name in ("VkLayer_khronos_validation.json", "VK_LAYER_KHRONOS_validation.json"):
            candidate = directory / name
            if candidate.exists():
                return candidate
    return None


def app_env() -> dict:
    """What an app run needs, on each platform the gate runs on."""
    global _reported_missing_layer
    env = dict(os.environ)
    if sys.platform != "darwin":
        # The workflows have no display of their own, and macOS draws through
        # Cocoa rather than a driver the gate could name.
        env.setdefault("SDL_VIDEODRIVER", "x11")
    # A software ICD keeps the two captures comparable where no GPU is present;
    # on macOS Vulkan is MoltenVK sitting on Metal.
    for icd in (
        Path("/usr/share/vulkan/icd.d/lvp_icd.json"),
        Path("/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json"),
        Path("/usr/local/share/vulkan/icd.d/MoltenVK_icd.json"),
    ):
        if icd.exists():
            env.setdefault("VK_ICD_FILENAMES", str(icd))
            break
    # A run is only checked against validation if the layer is in it. The
    # workflows install the layers, so a gate there that finds none would be
    # reporting on a check it never made.
    if find_validation_layer() is not None:
        env.setdefault("VK_INSTANCE_LAYERS", VALIDATION_LAYER)
    elif os.environ.get("CI"):
        require(False, f"{VALIDATION_LAYER} is not installed")
    elif not _reported_missing_layer:
        _reported_missing_layer = True
        print("validation: the Khronos layer is not installed; renders are unchecked")
    # The binary's rpath is relative to the repository, so a run with another
    # working directory needs the libraries named outright.
    libs = Path(__file__).resolve().parent.parent / ".deps" / "install" / "lib"
    if libs.is_dir():
        existing = env.get("LD_LIBRARY_PATH")
        env["LD_LIBRARY_PATH"] = str(libs) if not existing else f"{libs}:{existing}"
    return env


def display_command(command: list[str], env: dict) -> list[str]:
    """Run the app under a virtual X server when this host has no display."""
    if env.get("DISPLAY") or not shutil.which("xvfb-run"):
        return command
    return ["xvfb-run", "-a", *command]


def capture(binary: str, out: Path) -> None:
    env = app_env()
    command = display_command([binary, "--windowed", "--frames", "4", "--screenshot", str(out)], env)
    out.unlink(missing_ok=True)
    subprocess.run(command, check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=RUN_TIMEOUT)
    require(out.exists(), f"{out}: the app did not write a screenshot")


def atlas_coverage(binary: str, fixture: str) -> tuple[int, int]:
    """Render `fixture` and read back the atlas counters the app logs."""
    path = Path("/tmp/seggs-coverage.txt")
    path.write_text(fixture, encoding="utf-8")
    command = display_command([binary, "--file", str(path), "--windowed", "--frames", "2"], app_env())
    result = subprocess.run(command, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    if result.returncode != 0 or ATLAS_LINE.search(app_output(result)) is None:
        # The run's own output is the only thing that explains a missing line.
        print(f"coverage run exit {result.returncode}, stdout {len(result.stdout)} bytes, stderr {len(app_output(result))} bytes")
        for name, stream in (("stdout", result.stdout), ("stderr", app_output(result))):
            for line in stream.splitlines()[-8:]:
                print(f"  {name}: {line}")
    require(result.returncode == 0, f"the app exited {result.returncode} for {path.name}")
    match = ATLAS_LINE.search(app_output(result))
    require(match is not None, "the app did not report atlas coverage")
    return int(match.group(1)), int(match.group(2))


def check_fallback(binary: str) -> None:
    """Text outside the primary face must draw real glyphs, not the placeholder.

    This is the end-to-end proof that the fallback chain is wired: rendering a
    file of a script the primary face lacks must pack a further glyph for each
    uncovered codepoint, and must not fall back to the placeholder even once.
    """
    base_glyphs, base_missing = atlas_coverage(binary, ASCII_FIXTURE)
    require(base_missing == 0, f"the ASCII baseline already used the placeholder {base_missing} time(s)")
    for name, fixture in SCRIPT_FIXTURES:
        # Only codepoints the printable-ASCII preload cannot cover: a space in
        # the fixture is already in the atlas and would inflate the expectation.
        expected = len({char for char in fixture if ord(char) >= 0x80})
        glyphs, missing = atlas_coverage(binary, fixture)
        print(f"fallback: {name} packed {glyphs - base_glyphs} further glyph(s) for {expected} uncovered codepoint(s), {missing} placeholder hits")
        require(missing == 0, f"{name}: {missing} codepoint(s) fell back to the placeholder instead of a fallback face")
        require(
            glyphs >= base_glyphs + expected,
            f"{name}: only {glyphs - base_glyphs} further glyphs packed for {expected} uncovered codepoints",
        )


def check_text_scale(binary: str) -> None:
    """Drawn glyphs must be laid out at the scale the atlas reports.

    A frame captured at the wrong size, or glyph quads built from the wrong
    metrics, still looks like a plausible frame, so this measures the width of a
    known run of glyphs against the advance the app logs for its own atlas.
    """
    fixture = Path("/tmp/seggs-scale.txt")
    fixture.write_text(SCALE_FIXTURE, encoding="utf-8")
    out = Path("/tmp/seggs-scale.ppm")
    out.unlink(missing_ok=True)
    command = display_command([binary, "--file", str(fixture), "--windowed", "--frames", "4", "--screenshot", str(out)], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    diagnostics = [line for line in app_output(result).splitlines() if "Validation Error" in line or "VUID" in line]
    require(not diagnostics, f"the run reported {len(diagnostics)} Vulkan validation error(s): {diagnostics[0] if diagnostics else ''}")
    require("leaked" not in app_output(result), "the run leaked memory at shutdown")
    metrics = METRICS_LINE.search(app_output(result))
    require(metrics is not None, "the app did not report its atlas metrics")
    advance = float(metrics.group(1))
    width, height, pixels = parse_ppm(out)
    def ink_columns(y: int) -> list[int]:
        return [x for x in range(width) if pixels[(y * width + x) * 3] > 60]
    # The fixture's rows carry the most ink in the frame. Within such a row, the
    # run is the longest cluster of ink: the panel and gutter are separated from
    # it by wider gaps than the spacing inside a run of one glyph.
    band = max(range(height), key=lambda y: len(ink_columns(y)))
    columns = ink_columns(band)
    require(columns, "the scale fixture drew nothing")
    clusters: list[tuple[int, int]] = []
    start = previous = columns[0]
    for x in columns[1:]:
        if x - previous > GLYPH_GAP:
            clusters.append((start, previous))
            start = x
        previous = x
    clusters.append((start, previous))
    first, last = max(clusters, key=lambda pair: pair[1] - pair[0])
    drawn = last - first + 1
    expected = GLYPH_RUN * advance
    require(
        abs(drawn - expected) <= expected * 0.06,
        f"{GLYPH_RUN} glyphs drew {drawn}px wide, expected about {expected:.0f}px for advance {advance}",
    )
    print(f"text: {GLYPH_RUN} glyphs drew {drawn}px, expected about {expected:.0f}px at advance {advance}")


def amber_rows(image: tuple[int, int, bytes]) -> set[int]:
    """Rows holding a pixel close to the theme's amber.

    Only composition text and the underline under it use that color, and the
    underline is two pixels tall. Counting rows rather than pixels therefore
    tells the drawn composition apart from the underline alone.
    """
    width, height, pixels = image
    red_min, green_min, green_max, blue_max = AMBER
    rows: set[int] = set()
    for y in range(height):
        for x in range(width):
            index = (y * width + x) * 3
            red, green, blue = pixels[index], pixels[index + 1], pixels[index + 2]
            if red > red_min and green_min < green < green_max and blue < blue_max:
                rows.add(y)
    return rows


def check_baseline(binary: str) -> None:
    """Every glyph's ink must bottom out on the line's baseline.

    A packed glyph is cropped to its ink, so a renderer that draws it at the pen
    alone aligns the tops of the boxes instead: a period then sits as high as a
    capital, which reads as an apostrophe. A pixel-difference comparison cannot
    see that, so the ink is measured against the line pitch the app reports.
    """
    fixture = Path("/tmp/seggs-baseline.txt")
    fixture.write_text(BASELINE_FIXTURE, encoding="utf-8")
    out = Path("/tmp/seggs-baseline.ppm")
    out.unlink(missing_ok=True)
    command = display_command([binary, "--file", str(fixture), "--windowed", "--frames", "4", "--screenshot", str(out)], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    metrics = METRICS_LINE.search(app_output(result))
    require(metrics is not None, "the app did not report its atlas metrics")
    advance = float(metrics.group(1))
    pitch = float(metrics.group(2))
    width, height, pixels = parse_ppm(out)
    def ink_columns(y: int) -> list[int]:
        return [x for x in range(width) if pixels[(y * width + x) * 3] > 60]
    # The capital line is the longest contiguous run of ink in the frame; its row
    # is the crossbar, not the row with the most ink, which panel text can win.
    def longest_cluster(y: int) -> tuple[tuple[int, int], int]:
        columns = ink_columns(y)
        if not columns:
            return (0, 0), 0
        best = (columns[0], columns[0])
        start = previous = columns[0]
        for x in columns[1:]:
            if x - previous > GLYPH_GAP:
                if previous - start > best[1] - best[0]:
                    best = (start, previous)
                start = x
            previous = x
        if previous - start > best[1] - best[0]:
            best = (start, previous)
        return best, best[1] - best[0]
    # Only rows carrying a run at least this wide can be the fixture: the tab
    # strip and the panels hold shorter runs than a line of glyphs.
    MIN_CELLS = 40
    candidates = [y for y in range(height) if longest_cluster(y)[1] >= MIN_CELLS * advance]
    require(candidates, f"no row holds a run of {MIN_CELLS} glyph cells")
    band = max(candidates, key=lambda y: longest_cluster(y)[1])
    (left, right), _ = longest_cluster(band)
    cells = round((right - left + 1) / advance)
    require(cells >= MIN_CELLS, f"found only {cells} cells in the baseline fixture")

    def cell_rows(index: int, first: int, last_px: int) -> list[int]:
        x0 = left + round(index * advance)
        x1 = x0 + max(1, round(advance) - 1)
        return [
            y
            for y in range(first, last_px)
            if any(pixels[(y * width + x) * 3] > 60 for x in range(x0, min(x1, width)))
        ]

    span = min(height, band + round(pitch) + 10)
    capitals = [cell_rows(index, max(0, band - 24), min(height, band + 24)) for index in range(cells)]
    capitals = [(rows[0], rows[-1]) for rows in capitals if rows]
    require(len(capitals) >= 10, f"measured only {len(capitals)} capitals")
    baseline = max(bottom for _, bottom in capitals)
    for top, bottom in capitals:
        require(abs(bottom - baseline) <= 1, f"a capital bottoms out at row {bottom}, {abs(bottom - baseline)} row(s) off the baseline at {baseline}")

    # The gutter draws its line numbers through the same helper that adds the
    # ascent, so if the code line is placed at the top of its line instead of on
    # the baseline, the two disagree. Comparing the fixture with itself cannot
    # see that: every line moves together.
    # Only the fixture line's own rows: the next line's number is one line
    # pitch below and would otherwise be measured as part of this one.
    first_row = min(top for top, _ in capitals)
    last_row = max(bottom for _, bottom in capitals)
    gutter = [
        y
        for y in range(max(0, first_row - 2), min(height, last_row + 3))
        if any(pixels[(y * width + x) * 3] > 60 for x in range(max(0, left - 24), max(1, left - 12)))
    ]
    require(gutter, "no line number was found beside the fixture line")
    digits_bottom = gutter[-1]
    require(
        abs(digits_bottom - baseline) <= 1,
        f"the line number sits on row {digits_bottom} while the code on the same line bottoms out at {baseline}",
    )

    periods = [cell_rows(index, baseline + 1, span) for index in range(cells)]
    periods = [(rows[0], rows[-1]) for rows in periods if rows]
    require(len(periods) >= 10, f"measured only {len(periods)} periods")
    expected = baseline + round(pitch)
    for top, bottom in periods:
        require(
            abs(bottom - expected) <= 1,
            f"a period bottoms out at row {bottom}, expected the next baseline at {expected}",
        )
        require(bottom - top + 1 <= DOT_HEIGHT + 1, f"a period covers {bottom - top + 1} rows, which is a capital's height rather than a dot")
    print(f"baseline: {len(capitals)} capitals on row {baseline} beside their line number, {len(periods)} periods on row {expected} one line below")


def check_ime(binary: str) -> None:
    """Composition text must draw, then give way to committed text.

    Composition never enters the document, so a run that only tracks it looks
    identical to one that draws it. This drives real text editing and text input
    events through SDL and checks both halves: the composition is reported with
    the segment the input method selected, it reaches the frame, and the commit
    inserts exactly the committed bytes.
    """
    out = Path("/tmp/seggs-ime.ppm")
    out.unlink(missing_ok=True)
    command = display_command([binary, "--windowed", "--frames", "9", "--exercise-ime", "--screenshot", str(out)], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    compositions = IME_COMPOSITION.findall(app_output(result))
    require(len(compositions) >= 2, f"expected two compositions, saw {len(compositions)}")
    require(compositions[0] == ("7", "2", "5"), f"first composition reported {compositions[0]}, expected 7 cells with selection 2..5")
    require(compositions[1] == ("4", "1", "3"), f"second composition reported {compositions[1]}, expected 4 cells with selection 1..3")
    commit = IME_COMMIT.search(app_output(result))
    require(commit is not None, "the run did not report a commit")
    inserted = int(commit.group(2)) - int(commit.group(1))
    require(inserted == 7, f"the commit inserted {inserted} byte(s), expected 7")
    rows = amber_rows(parse_ppm(out))
    require(len(rows) >= 4, f"the composition covered {len(rows)} row(s), which is an underline without text")
    print(f"ime: composition text drawn across {len(rows)} rows, commit inserted {inserted} byte(s)")


def check_panel(binary: str) -> None:
    """An extension panel must lay out, draw, and receive events.

    The panel is described in TypeScript, laid out with Yoga, drawn through the
    quad path, and a click on it has to arrive back in the extension as a handler
    call. None of that shows up in a pixel comparison, so the round trip is
    driven and its result read from the log.
    """
    command = display_command([binary, "--windowed", "--frames", "40", "--exercise-click"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    out = app_output(result)
    loaded = EXTENSION_LINE.search(out)
    require(loaded is not None, "the extension host reported no extensions")
    require(int(loaded.group(1)) >= 2, f"only {loaded.group(1)} extension(s) loaded, expected the panel and status bundles")
    # Whatever the fixture could not do, it says so itself rather than leaving
    # the step out: the line is read here so a skipped step is a failure with a
    # reason, not a quietly shorter run.
    problem = CLICK_PROBLEM.search(out)
    require(problem is None, f"the click fixture could not take a step it is here to take: {problem.group(1) if problem else ''}")
    click = PANEL_CLICK.search(out)
    require(click is not None, "a click on an extension panel did not reach a handler")
    # The run then presses Tab and Enter, and clicks an explorer row and a lane.
    # Between them the two kinds of request an extension can make are covered:
    # one the editor applies to the document, one it applies to an agent.
    opened = EDITOR_OPEN.search(out)
    require(opened is not None, "an explorer row did not open a file")
    # The agent dock's strip is its navigation: a click on a lane's tab makes
    # that lane the one the interface works on. The fixture moves the interface
    # off that lane first, so the line it reads back names the lane the click
    # chose: a click that missed would leave the other name there.
    tab = AGENT_TAB_LINE.search(out)
    require(tab is not None, "a click on an agent tab was not reported")
    require(
        tab.group(2) == tab.group(1),
        f"the tab click moved the interface to {tab.group(2)!r} rather than to {tab.group(1)!r}, whose tab was clicked",
    )
    require(tab.group(1) == "Local mock", f"the tab click landed on {tab.group(1)!r}, not on the lane the fixture opened")
    # Both jump lists come off the same rows and the same keys. The template
    # list is opened with Ctrl+Shift+A, filtered by typing, and chosen with
    # Return; the destination list is opened with Ctrl+Shift+Enter and chosen
    # the same way, and the status line names what each one did.
    jump = AGENT_JUMP_LINE.search(out)
    require(jump is not None, "the template jump list reported nothing")
    require("Local mock" in jump.group(1), f"the jump list chose {jump.group(1)!r}, not the lane that was filtered for")
    key = AGENT_KEY_LINE.search(out)
    require(key is not None, "the same list opened by a key reported nothing")
    require("Local mock" in key.group(1), f"the key-opened list chose {key.group(1)!r}")
    sent = AGENT_SEND_LINE.search(out)
    require(sent is not None, "the destination list reported nothing")
    require("Prompt sent to Local mock" in sent.group(1), f"the destination list said {sent.group(1)!r}")
    # Ctrl+W closes what has focus. In the dock that is the lane, and in the
    # editor it is the file behind the one on screen.
    close = AGENT_CLOSE_LINE.search(out)
    require(close is not None, "the close key reported nothing for the dock")
    require("Closed Local mock" in close.group(1), f"the close key said {close.group(1)!r} with the dock focused")
    buffer = BUFFER_CLOSE_LINE.search(out)
    require(buffer is not None, "the close key reported nothing for the editor")
    require(buffer.group(1).startswith("Closed "), f"the close key said {buffer.group(1)!r} with the editor focused")
    # And a pointer moving over a row, which panels use to respond before a
    # click. It is dispatched only when the node under the pointer changes.
    hover = HOVER_LINE.search(out)
    require(hover is not None, "moving the pointer over a panel reached no handler")
    print(
        f"panel: {loaded.group(1)} extension(s) loaded, click reached panel {click.group(1)}, "
        f"explorer row opened {opened.group(1)}, agent tab clicked {tab.group(1)}, "
        f"jump lists chose and sent to {tab.group(1)}, "
        f"hover reported on {hover.group(1)}"
    )


def read_report(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def wait_for(predicate, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except (OSError, ValueError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    return False


def check_extensions(binary: str) -> None:
    """An extension an author or an agent writes has to load, and a broken one
    has to say why.

    A temporary workspace is used so the repository's own bundles are untouched.
    The run starts with one good bundle and one broken one, then fixes the broken
    one while the editor is still running: reloading is what makes the loop an
    agent works in possible at all.
    """
    binary = os.path.abspath(binary)  # the run uses the workspace as its cwd
    workspace = Path(tempfile.mkdtemp(prefix="seggs-ext-"))
    bundles = workspace / "extensions" / "dist"
    bundles.mkdir(parents=True)
    (bundles / "good.js").write_text('seggs.status("good loaded");\n', encoding="utf-8")
    (bundles / "broken.js").write_text("this is not javascript(\n", encoding="utf-8")
    report = workspace / ".seggs" / "extensions.json"
    command = display_command([binary, "--windowed", "--frames", "900"], app_env())
    process = subprocess.Popen(
        command, cwd=workspace, env=app_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    try:
        require(wait_for(report.exists, 20), "the editor wrote no extension report")
        state = read_report(report)
        require(state["loaded"] == 1, f"expected one loaded bundle, saw {state['loaded']}")
        broken = next((entry for entry in state["extensions"] if entry["name"] == "broken.js"), None)
        require(broken is not None, "the broken bundle was not reported at all")
        require(not broken["loaded"], "a bundle that cannot parse was reported as loaded")
        require(bool(broken["problem"]), "the broken bundle was reported without a reason")
        # Fix it while the editor runs, which is what an agent iterating does.
        (bundles / "broken.js").write_text('seggs.status("broken fixed");\n', encoding="utf-8")
        require(
            wait_for(lambda: read_report(report)["loaded"] == 2, 20),
            "a fixed bundle was not reloaded",
        )
        fixed = read_report(report)
        require(
            fixed["generation"] >= 2,
            f"the reload was not recorded, generation is {fixed['generation']}",
        )
        print(
            f"extensions: a broken bundle reported {broken['problem'][:40]!r}, "
            f"reloading picked up the fix at generation {fixed['generation']}"
        )
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        shutil.rmtree(workspace, ignore_errors=True)


def check_narrow(binary: str) -> None:
    """The shell has to keep working when the window is too narrow for columns.

    Below the breakpoints the agent column and the file list are dropped and the
    editor takes their space. The panels that remain still have to lay out and
    take events, which is checked by clicking the activity rail: it is the one
    region every width keeps.
    """
    command = display_command([binary, "--windowed", "--window-size", "860x600", "--frames", "22", "--exercise-click"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    loaded = EXTENSION_LINE.search(app_output(result))
    require(loaded is not None and int(loaded.group(1)) >= 5, "the extensions did not load at a narrow width")
    action = APP_ACTION.search(app_output(result))
    require(action is not None, "a panel stopped taking events at a narrow width")
    print(f"narrow: {loaded.group(1)} extension(s) at 860x600, rail handled {action.group(1)}")


def check_window_transitions(binary: str) -> None:
    """Resize, minimize, and fullscreen transitions must not break rendering.

    A window manager may refuse a transition, so this does not demand that every
    step succeeds. It demands that the app survives each step, that a resize
    request actually reaches the window, and that frames keep rendering after
    the transitions instead of the swapchain stalling.
    """
    command = display_command([binary, "--windowed", "--frames", "9", "--exercise-window"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    require(ATLAS_LINE.search(app_output(result)) is not None, "the frame loop did not finish after the transitions")
    steps = WINDOW_LINE.findall(app_output(result))
    require(len(steps) >= 3, f"expected three transitions, saw {len(steps)}")
    resized = [step for step in steps if (int(step[1]), int(step[2])) == RESIZE_TARGET]
    require(resized, f"the resize to {RESIZE_TARGET[0]}x{RESIZE_TARGET[1]} never reached the window")
    refused = re.findall(r"(\w+) refused:", app_output(result))
    print(
        f"window: {len(steps)} transitions exercised, resize reached "
        f"{RESIZE_TARGET[0]}x{RESIZE_TARGET[1]}, refusals: {refused or 'none'}"
    )


TERMINAL_LINE = re.compile(r"PASS: the shell answered on the terminal screen")

DENSITY_SCALE = "2"


def check_terminal(binary: str) -> None:
    """A real shell in the dock, end to end.

    The exercise opens the terminal, types a command through the same path the
    keyboard takes, and reads the emulator's screen back: the shell's answer
    must appear there, which no single component could fake.
    """
    out = Path("/tmp/seggs-terminal.ppm")
    # The shell is asked to mark its own commands, so the check names one the
    # integration knows when it is installed: the marked path is what gets
    # exercised, rather than whichever shell the runner happened to export.
    env = app_env()
    for candidate in ("/usr/bin/bash", "/bin/bash"):
        if os.path.exists(candidate):
            env["SHELL"] = candidate
            break
    command = display_command([binary, "--windowed", "--frames", "500", "--exercise-terminal", "--screenshot", str(out)], env)
    result = subprocess.run(command, check=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    if TERMINAL_LINE.search(output) is None:
        print("terminal run output:")
        for line in output.splitlines()[-10:]:
            print(f"  {line}")
    require(TERMINAL_LINE.search(output) is not None, "the terminal did not carry the shell's answer")
    require(ATLAS_LINE.search(output) is not None, "the frame loop did not finish with the terminal open")
    marked = COMMAND_LINE.search(output)
    if marked is None:
        for line in output.splitlines()[-8:]:
            print(f"  {line}")
    require(marked is not None, "the terminal fixture reported nothing about command boundaries")
    print(f"terminal: {marked.group(0)[:100]}")
    # The dock is drawn, not just emulated: a screen that reads text back while
    # the panel stays blank is the failure this check exists to catch.
    width, height, pixels = parse_ppm(out)
    dock = count_ink(pixels, width, height, *DOCK_REGION)
    require(dock > 500, f"the terminal dock drew {dock} lit pixels; a shell in it should draw text")
    print(f"terminal: a real shell ran in the dock, its answer reached the screen, and the dock drew {dock} lit pixels")


def check_run(binary: str) -> None:
    """A run exists without a panel being open, and a step actually runs.

    The engine's vocabulary - a workflow, a run, a step, an artifact - is the
    product model. The fixture describes the starter workflow, then sends one
    step to a harness that is really running and records what comes back, so
    the check covers both the shape of a workflow and the round trip.
    """
    # A change has to be accepted into a real file, so the fixture opens a
    # throwaway one: a gate that edited the repository would be a gate nobody
    # could run twice.
    workdir = Path(tempfile.mkdtemp(prefix="seggs-review-"))
    target = workdir / "reviewed.zig"
    target.write_text("const std = @import(\"std\");\n", encoding="utf-8")
    command = display_command([binary, "--windowed", "--frames", "420", "--file", str(target), "--exercise-run"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    started = RUN_LINE.search(output)
    answered = ANSWER_LINE.search(output)
    reviewed = REVIEW_LINE.search(output)
    if started is None or answered is None:
        print("run output:")
        for line in output.splitlines()[-10:]:
            print(f"  {line}")
    require(started is not None, "starting a run reported nothing")
    require(int(started.group(2)) == 3, f"the run holds {started.group(2)} steps, expected the three the starter workflow defines")
    require(int(started.group(3)) >= 1, "the run started without the artifact it is supposed to carry")
    require(started.group(4) == "plan", f"the run's current step is {started.group(4)}, expected the first one")
    require(answered is not None, "a step was sent and nothing was recorded")
    require(reviewed is not None, "a change was proposed and the review surface never reported it")
    require(reviewed.group(2) == "true", "a change was accepted and the file did not change")
    require(int(answered.group(2)) == 3, f"the run recorded {answered.group(2)} steps, expected the three it has")
    require(int(answered.group(3)) == 3, f"the run holds {answered.group(3)} artifact(s), expected one per step")
    # The last step is a person's decision, and it is recorded like any other
    # artifact: a run's progress is not its acceptance.
    require(answered.group(4) == "review", f"the last artifact is a {answered.group(4)}, expected the approval's review")
    require(answered.group(5) == "approve", f"the artifact came from {answered.group(5)}, expected the approval step")
    require(int(answered.group(6)) > 0, "the recorded artifact is empty: a step that says nothing did not run")
    print(
        f"run: {started.group(1)} started with {started.group(2)} steps and {started.group(3)} artifact(s) at {started.group(4)}, "
        f"then a harness answered and {answered.group(5)} recorded {answered.group(6)} bytes of {answered.group(4)}, "
        f"and a proposed change was accepted with {reviewed.group(1)} left waiting"
    )


def check_terminal_paints(binary: str) -> None:
    """A shell draws something, and what it draws is visible.

    The suite passed once while every coloured thing a shell prints - the
    prompt, an ls, a git status - was painted in the background colour, because
    a theme's placeholder palette was being handed to a live emulator. Nothing
    failed, because nothing asserted that a terminal draws at all.

    A lit-pixel census rather than a comparison against a reference: the claim
    is only that the shell's own screen holds pixels brighter than what is
    behind them, which is the weakest statement worth making and the one least
    likely to churn.

    **What this does not catch, and it was measured rather than assumed:** a
    palette that paints ANSI colours in the background colour. That was the bug
    this was written after, and restoring it still passes here, because the
    shell in this fixture is `sh` and its prompt is plain text - visible either
    way. Only output that is actually coloured tells the two apart, and nothing
    in this fixture prints any. Making it bite needs a fixture that emits a
    colour code, which is worth doing and has not been done.

    What it does catch is a terminal that draws nothing at all, which is a real
    regression class of its own.
    """
    screenshot = Path(tempfile.gettempdir()) / "seggs-terminal-paint.ppm"
    # Frame 66 is after a shell has printed its prompt (measured: nothing is lit
    # in the screen at frame 45, 83 pixels are by frame 66) and before the
    # fixture exits its shells at 70, after which there is no dock to measure.
    # The threshold is a quarter of what was measured, so a slower machine
    # arriving later in the same window still passes rather than flaking.
    command = display_command([binary, "--windowed", "--window-size", "1200x800", "--frames", "66", "--exercise-tabs", "--screenshot", str(screenshot)], app_env())
    subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    width, height, pixels = parse_ppm(screenshot)
    # The shell's screen, not the dock: the tab strip along the top of the dock
    # carries lit labels of its own, and measuring them would let this pass on a
    # terminal that draws nothing - which is exactly what it did before the
    # region was narrowed. At 1200x800 the dock is the bottom 220 rows of the
    # editor column and its strip is the first 26, so the screen is below that
    # and above the status bar.
    lit = count_ink(pixels, width, height, 270, height - 200, 620, 140)
    require(lit >= 20, f"a live shell drew {lit} lit pixel(s) in its own screen; its output is not reaching the screen")


def check_tabs(binary: str) -> None:
    """The terminal's tabs: adding, moving, and closing all agree on which is
    showing. The fixture does each in turn and reports where it ended up, which
    is the arithmetic a tab strip gets wrong."""
    command = display_command([binary, "--windowed", "--frames", "90", "--exercise-tabs"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    tabs = TABS_LINE.search(output)
    if tabs is None:
        for line in output.splitlines()[-8:]:
            print(f"  {line}")
    require(tabs is not None, "the terminal tab fixture reported nothing")
    # Three opened, one closed, so two remain, and the reader is on the first.
    require(int(tabs.group(1)) == 2, f"{tabs.group(1)} tabs remained, expected the two that were not closed")
    # Both shells then leave. A tab whose program is gone cannot run anything,
    # and the last one takes the dock with it.
    exit_line = EXIT_LINE.search(output)
    require(exit_line is not None, "the terminal fixture reported nothing after exit")
    require(int(exit_line.group(1)) == 0, f"{exit_line.group(1)} shells outlived their programs")
    require(exit_line.group(2) == "down", "the dock stayed up with nothing in it")
    require(int(tabs.group(2)) == 1, f"the reader ended on tab {tabs.group(2)}, expected the first")
    # The same fixture drags over the screen and copies: a selection that never
    # reaches the clipboard is a selection that does nothing.
    copied = TABS_COPY.search(output)
    require(copied is not None, "selecting in the terminal reported nothing")
    require(int(copied.group(1)) > 0, "a selection in the terminal copied nothing")
    print(
        f"tabs: {tabs.group(1)} open after adding three and closing one, showing {tabs.group(2)}, "
        f"and selecting copied {copied.group(1)} byte(s)"
    )


def check_compose(binary: str) -> None:
    """A workflow reads left to right, and says what travels along it.

    The Compose perspective is the same run seen as a sequence rather than as a
    list. The fixture reports the sequence it drew, so the check follows the
    workflow itself rather than the pixels of one layout.
    """
    command = display_command([binary, "--windowed", "--frames", "30", "--exercise-compose"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    composed = COMPOSE_LINE.search(output)
    if composed is None:
        for line in output.splitlines()[-8:]:
            print(f"  {line}")
    require(composed is not None, "composing a run reported nothing")
    steps = [word.strip() for word in composed.group(3).split("|")]
    require(steps == ["plan", "implement", "review"], f"the strip reads {steps}, expected the starter workflow in order")
    print(f"compose: {composed.group(1)} as {composed.group(3)}")


def check_density(binary: str) -> None:
    """A display reporting a scale other than one must still render.

    The editor asks for a high-density window and the platform decides the
    factor: the CI runners report one, so the flag alone would never be
    exercised. X11 accepts a named factor, so the transitions run again there
    and must finish, which is what a high-density display has to survive.
    """
    env = app_env()
    if env.get("SDL_VIDEODRIVER") != "x11":
        print("density: this video driver takes no scaling hint; the scaled run is not exercised here")
        return
    env["SDL_VIDEO_X11_SCALING_FACTOR"] = DENSITY_SCALE
    command = display_command([binary, "--windowed", "--frames", "9", "--exercise-window"], env)
    result = subprocess.run(command, check=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    require(ATLAS_LINE.search(app_output(result)) is not None, "the frame loop did not finish at a scaled display")
    scaled = [step for step in SCALE_LINE.findall(app_output(result)) if step[4] == DENSITY_SCALE + ".00"]
    require(scaled, f"no window report carried scale {DENSITY_SCALE}")
    step = scaled[0]
    print(f"density: scale {step[4]}, logical {step[0]}x{step[1]} with a {step[2]}x{step[3]} backbuffer, transitions survived")


def check_tool_calls(binary: str) -> None:
    """A tool call is an object in the transcript, not a paragraph of JSON.

    The fixture's turn carries the shapes a chip has to draw - a read that
    finished, an edit carrying a diff, a command that failed, and a command still
    running - and then clicks one. What the gate reads is what a reader would:
    the words the chips showed, and that the click changed whether the call is
    open. A chip that stopped naming its state, or one that no click can open,
    is what this fails on.
    """
    command = display_command([binary, "--windowed", "--frames", str(CALL_FRAMES), "--exercise-toolcalls"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    drawn = CALLS_LINE.search(output)
    require(drawn is not None, "no tool call chips were drawn")
    count = int(drawn.group(1))
    require(count >= len(CALL_CHIP_WORDS), f"expected every call shape, saw {count} chip(s)")
    shown = drawn.group(2)
    for word in CALL_CHIP_WORDS:
        require(word in shown, f"no chip showed {word!r}: {shown}")
    # Two clicks, because a card has two ends. The first lands on the card's last
    # row - the marker saying how many lines were withheld - and has to open it;
    # a marker that cannot be clicked is a number with no way to ask what it
    # counts. The second lands on the chip and has to close it again; a card that
    # opens and will not close is a card whose hit covers the wrong rows.
    clicks = CALL_CLICK_LINE.findall(output)
    require(len(clicks) >= 2, f"both clicks on a call were not reported: {clicks}")
    first, second = clicks[0], clicks[1]
    require(
        first[1] == "false" and first[2] == "true",
        f"the click on the withheld marker left {first[0]} open {first[1]} -> {first[2]}",
    )
    require(
        second[1] == "true" and second[2] == "false",
        f"the click on the chip left {second[0]} open {second[1]} -> {second[2]}",
    )
    print(f"tool calls: {count} chips drawn ({shown}); the withheld marker opened the {first[0]} and the chip closed it")


def check_records(binary: str) -> None:
    """A session's records are drawn as records, not as JSON and not dropped.

    The fixture's turn carries every kind the interface draws from something
    other than a tool call: a stream of reasoning (many chunks, one run), the
    user's own words, a compaction summary, a plan that replaces itself, the
    usage of the turn, the mode, what the session is called, and the commands it
    accepts. What the gate reads is what a reader would: the words on each line,
    that the reasoning is caught *while it is still arriving* and stops pulsing
    when it settles, and that a click opens it - the last of which is the one
    thing a run has no agent id for, so it is keyed by the handle the client
    gave it, and a wrong key would open a different thought.
    """
    shot = Path("/tmp/seggs-records.ppm")
    command = display_command([binary, "--windowed", "--frames", str(RECORDS_FRAMES), "--exercise-records", "--screenshot", str(shot)], app_env())
    shot.unlink(missing_ok=True)
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)

    # While it is arriving: the label says thinking, the mark is the running one,
    # and the card is set to pulse, which is what the drawer turns into a moving
    # glyph.
    pulse = RECORDS_PULSE.search(output)
    require(pulse is not None, "no run was reported while it was arriving")
    mid = pulse.group(1)
    require("thinking ●" in mid, f"a run that is still arriving is not labelled as thinking: {mid}")
    require("pulse" in mid, f"a run that is still arriving is not set to pulse: {mid}")

    drawn = RECORDS_LINE.search(output)
    require(drawn is not None, "no records were drawn")
    count = int(drawn.group(1))
    require(count >= 3, f"expected the turn's three runs, saw {count}")
    shown = drawn.group(2)
    # Settled: the pulse stopped and the count is final, which is the whole
    # difference between "the agent is working" and "the agent has stopped".
    runs_only = shown.split("plans:")[0]
    require("thought ✓" in shown, f"the settled reasoning is not labelled as finished: {shown}")
    require("pulse" not in runs_only, f"a settled run is still pulsing: {runs_only}")
    # A picture is drawn rather than counted. The run it arrived in must not
    # report a part nobody could read - that marker is for a content type this
    # client keeps nowhere, and a picture is kept - and the picture itself has to
    # be in the census with the size it decoded to and the size it was drawn at.
    require("part not text" not in shown, f"a picture was counted as an unreadable part: {shown}")
    picture = RECORDS_IMAGE.search(shown)
    require(picture is not None, f"the picture is not reported as drawn: {shown}")
    require((int(picture.group(1)), int(picture.group(2))) == (16, 16), f"the picture decoded to {picture.group(1)}x{picture.group(2)}")
    require("you" in shown, f"the user's own words were not drawn: {shown}")
    # A plan is a checklist with a mark per task, the working one standing out,
    # and the priority shown only where it says something.
    require("1/3 done" in shown, f"the plan's progress is not on its line: {shown}")
    require("✓   capture the reasoning" in shown, f"the finished task has no mark: {shown}")
    require("●   draw it where it happened" in shown, f"the task in hand has no mark: {shown}")
    require("○   show what a turn cost" in shown, f"a waiting task has no mark: {shown}")
    require("· high" in shown and "· low" in shown, f"priority is missing where it matters: {shown}")
    # Usage, mode, name, commands, compaction. The two usage placements are read
    # at the widths they are really drawn in, so the cost has to survive the
    # narrow one: a bar is a picture of the counts beside it and a share is
    # arithmetic on them, which is why both are given up before the cost is.
    require("42k/200k" in shown, f"the usage row lost its counts: {shown}")
    require("21%" in shown, f"the usage footer lost its share: {shown}")
    require("$1.25" in shown, f"the usage row lost its cost: {shown}")
    gauge = shown.split("usage gauge:")[1].split(" footer:")[0].strip() if "usage gauge:" in shown else ""
    require(gauge.startswith("42k/200k"), f"the standing gauge does not lead with the counts: {gauge}")
    require("$1.25" in gauge, f"the standing gauge dropped the cost at the width it is drawn in: {gauge}")
    require("mode: plan" in shown, f"the mode was not drawn: {shown}")
    require("title: Records fixture" in shown, f"the session's name was not drawn: {shown}")
    require("commands: compact research" in shown, f"the agent's commands were not drawn: {shown}")
    require("mock-compaction/completed" in shown, f"the compaction was not drawn: {shown}")

    # And the pixels: the census says what the drawing did, and this says the
    # pixels reached the screen. The fixture's quadrants are a colour nothing
    # else in the interface uses, so finding them in the frame is finding the
    # picture - a client whose decode succeeded but whose quad never landed
    # passes every string check above and fails this one.
    require(shot.exists(), f"{shot}: the records run wrote no screenshot")
    width, height, pixels = parse_ppm(shot)
    counted = {
        colour: sum(1 for index in range(0, width * height * 3, 3) if pixels[index : index + 3] == bytes(colour))
        for colour in QUADRANTS
    }
    drawn = [colour for colour, count in counted.items() if count >= QUADRANT_PIXELS]
    require(len(drawn) >= 3, f"the picture is not on screen: quadrant pixels {counted}")

    click = RECORDS_CLICK_LINE.search(output)
    require(click is not None, "the click on the reasoning was never reported")
    require(
        click.group(1) == "false" and click.group(2) == "true",
        f"the click left the reasoning open {click.group(1)} -> {click.group(2)}",
    )
    opened = RECORDS_OPEN_LINE.search(output)
    require(opened is not None, "the opened run was never reported")
    # Opening a run shows its text: the shut line is one row, and the open one is
    # the reasoning itself, which is the difference a reader asked for.
    require("thought ✓=73 B open/" in opened.group(1), f"the open run is not the one that was clicked: {opened.group(1)}")
    require("shut/1 row(s)" in opened.group(1), f"a shut run is not one line: {opened.group(1)}")
    print(f"records: {count} runs drawn; the reasoning pulsed while it arrived and a click opened it ({runs_only.strip()})")


def check_embedded(binary: str) -> None:
    """A call that ran in a terminal shows that terminal's output.

    The protocol's sentence has two halves and the second is the interesting one:
    *"the Client displays live output as it's generated and continues to display
    it even after the terminal is released."* The release is what makes this worth
    asserting - `terminal/release` frees the client's record, so a client that
    reads the terminal at the point of drawing blanks the output the moment the
    agent is done with it. The count the gate reads is taken after the release
    has been answered, and it is incremented where the screen is drawn, so a
    non-zero count is a screen the editor kept rather than a record that happened
    to still exist.
    """
    command = display_command([binary, "--windowed", "--frames", str(EMBEDDED_FRAMES), "--exercise-embedded"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)

    drawn = EMBEDDED_LINE.search(output)
    require(drawn is not None, "the embedded terminal was never reported")
    require(int(drawn.group(1)) >= 1, f"the call's terminal was not drawn after release: {drawn.group(0)}")
    # The call itself has to have been drawn too, or the terminal is floating
    # under nothing: the chip is what says which command ran in it.
    require("run \u2713" in drawn.group(2), f"the call that embedded the terminal is not drawn: {drawn.group(2)}")

    print(f"embedded: {drawn.group(1)} terminal(s) drawn after the agent released it; calls: {drawn.group(2)}")


def check_markdown(binary: str) -> None:
    """Prose is drawn by the arms that claim it, counted where it is drawn.

    The sample the transcript exercise feeds carries the constructs whose
    drawing is otherwise only asserted by reading the code: a table that fits
    the panel and one that does not, a formula inline and one set apart, a
    struck word, and a link. What the gate reads is the panel's own census of
    the rows it put on the screen, by block kind - so an arm that stopped
    drawing anything is a count of zero rather than a line someone has to
    notice is missing - and it clicks the link, because a target that does
    nothing is worse than one not drawn as a target.

    Only a row the window shows is counted, so the kinds absent from the census
    are the ones below the fold rather than the ones that failed: this asserts
    what did reach the screen, not what did not.
    """
    command = display_command([binary, "--windowed", "--frames", str(MARKDOWN_FRAMES), "--exercise-transcript"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)

    drawn = MARKDOWN_BLOCKS.search(output)
    require(drawn is not None, "the transcript never reported what it drew")
    census = drawn.group(1)
    counts = dict((name, int(value)) for name, value in (part.split("=") for part in census.split()))
    require(counts.get("table", 0) >= 1, f"no table row reached the screen: {census}")
    require(counts.get("math", 0) >= 1, f"no formula row reached the screen: {census}")
    # The inline marks need their own counts, because a block's kind says nothing
    # about what is inside it: a paragraph holding a struck word is one
    # paragraph, so the block census would be unchanged if the rule stopped being
    # drawn. Two link runs is the expected number for one link - the words and
    # the address are separate runs and both are targets.
    require(counts.get("struck", 0) >= 1, f"no struck run reached the screen: {census}")
    require(counts.get("links", 0) >= 1, f"no link run reached the screen: {census}")

    clicked = LINK_CLICK.search(output)
    require(clicked is not None, "the click on a link was never reported")
    require("agentclientprotocol.com" in clicked.group(1), f"the click did not reach the link's address: {clicked.group(1)}")

    print(f"markdown: {census}; a click on a link opened {clicked.group(1)}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: screenshot_check.py <seggs-binary>", file=sys.stderr)
        return 2
    binary = sys.argv[1]
    shots = [Path("/tmp/seggs-shot-a.ppm"), Path("/tmp/seggs-shot-b.ppm")]
    try:
        for shot in shots:
            capture(binary, shot)
        images = [parse_ppm(shot) for shot in shots]
        for shot, image in zip(shots, images):
            describe(shot, image)
            check_content(shot, image)
            check_solid_quads(shot, image)
        compare(images[0], images[1])
        check_fallback(binary)
        check_text_scale(binary)
        check_baseline(binary)
        check_ime(binary)
        check_panel(binary)
        check_extensions(binary)
        check_narrow(binary)
        check_window_transitions(binary)
        check_density(binary)
        check_terminal(binary)
        check_run(binary)
        check_compose(binary)
        check_tabs(binary)
        check_tool_calls(binary)
        check_records(binary)
        check_markdown(binary)
        check_embedded(binary)
        check_terminal_paints(binary)
    except (OSError, subprocess.CalledProcessError, ValueError) as err:
        print(f"FAIL: {err}", file=sys.stderr)
        return 1
    print("PASS: renders agree, glyphs draw at the reported scale and baseline, composition draws and commits, extension panels take events and reload, fallback covers uncovered scripts, window transitions hold, tool calls draw as chips and open on a click, a session's records draw as records (reasoning pulses while it arrives, a picture arrives and is drawn, and a click opens it), prose draws the blocks it claims and a clicked link opens, a call's terminal draws and outlives its release, a live shell paints")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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
ATLAS_LINE = re.compile(r"atlas: (\d+) glyphs packed, (\d+) placeholder hits")
WINDOW_LINE = re.compile(r"window after step (\d+): logical (\d+)x(\d+), pixels (\d+)x(\d+)")
SCALE_LINE = re.compile(r"logical (\d+)x(\d+), pixels (\d+)x(\d+), scale (\d+\.\d+)")
METRICS_LINE = re.compile(r"atlas: advance ([0-9.]+), line height ([0-9.]+)")
EXTENSION_LINE = re.compile(r"extensions: (\d+) loaded")
PANEL_CLICK = re.compile(r"click: status is now panel (\S+): clicked (.+)")
RUN_LINE = re.compile(r"run (\S+): (\d+) steps, (\d+) artifacts, current=(\S+)")
REVIEW_LINE = re.compile(r"review: (\d+) change\(s\) waiting, accepted=(true|false)")
ANSWER_LINE = re.compile(r"run (\S+): (\d+) steps, (\d+) artifacts, (\S+) from (.+?), (\d+) bytes")

INSPECTOR_LINE = re.compile(r"inspector: selection=false")

HOVER_LINE = re.compile(r"hover (\S+) (\S+)")
APP_ACTION = re.compile(r"app action: (\S+)")
EDITOR_OPEN = re.compile(r"open: status is now Opened (.+)")
IME_COMPOSITION = re.compile(r"ime: composition (\d+) cell\(s\), selection (\d+)\.\.(\d+)")
IME_COMMIT = re.compile(r"ime: committed, document (\d+) -> (\d+) byte\(s\)")
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
    command = display_command([binary, "--windowed", "--frames", "22", "--exercise-click"], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    loaded = EXTENSION_LINE.search(app_output(result))
    require(loaded is not None, "the extension host reported no extensions")
    require(int(loaded.group(1)) >= 2, f"only {loaded.group(1)} extension(s) loaded, expected the panel and status bundles")
    click = PANEL_CLICK.search(app_output(result))
    require(click is not None, "a click on an extension panel did not reach a handler")
    # The run then presses Tab and Enter, and clicks an explorer row and a lane.
    # Between them the two kinds of request an extension can make are covered:
    # one the editor applies to the document, one it applies to an agent.
    opened = EDITOR_OPEN.search(app_output(result))
    require(opened is not None, "an explorer row did not open a file")
    # The inspector carries context rather than a roster: a click on a context
    # row switches what the next prompt will send, and says so.
    inspector = INSPECTOR_LINE.search(app_output(result))
    require(inspector is not None, "an inspector row click did not change what the next prompt carries")
    # And a pointer moving over a row, which panels use to respond before a
    # click. It is dispatched only when the node under the pointer changes.
    hover = HOVER_LINE.search(app_output(result))
    require(hover is not None, "moving the pointer over a panel reached no handler")
    print(
        f"panel: {loaded.group(1)} extension(s) loaded, click reached panel {click.group(1)}, "
        f"explorer row opened {opened.group(1)}, inspector row clicked, "
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
    command = display_command([binary, "--windowed", "--frames", "500", "--exercise-terminal", "--screenshot", str(out)], app_env())
    result = subprocess.run(command, check=True, env=app_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=RUN_TIMEOUT)
    output = app_output(result)
    if TERMINAL_LINE.search(output) is None:
        print("terminal run output:")
        for line in output.splitlines()[-10:]:
            print(f"  {line}")
    require(TERMINAL_LINE.search(output) is not None, "the terminal did not carry the shell's answer")
    require(ATLAS_LINE.search(output) is not None, "the frame loop did not finish with the terminal open")
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
    except (OSError, subprocess.CalledProcessError, ValueError) as err:
        print(f"FAIL: {err}", file=sys.stderr)
        return 1
    print("PASS: renders agree, glyphs draw at the reported scale and baseline, composition draws and commits, extension panels take events and reload, fallback covers uncovered scripts, window transitions hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

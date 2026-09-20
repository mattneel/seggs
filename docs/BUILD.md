# Build guide

## Target baseline

The app targets Zig 0.17.0, pinned by `.zigversion` and `minimum_zig_version`.
The source bootstrap selects SDL 3.4.4 and SDL_ttf 3.2.2.
These releases form a fixed baseline, not a claim about the latest releases.
The [source references](SOURCES.md) identify the upstream projects.

The default installation prefix is `.deps/install`.
The build imports C declarations through `addTranslateC`.
The core test target does not require SDL headers or shader tools.

## Linux prerequisites

Install the packages on an Ubuntu or Debian development system.

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake git pkg-config python3 \
  libfreetype6-dev libx11-dev libxext-dev libxrandr-dev \
  libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxrender-dev \
  glslang-tools libvulkan-dev mesa-vulkan-drivers fonts-dejavu-core
```

The bootstrap enables X11 and disables Wayland to limit the baseline dependencies.
A Wayland desktop can use XWayland.
A native Wayland build requires a separate SDL build with its development dependencies.
The app still needs a compatible Vulkan driver.
Package availability varies across distributions.

## macOS prerequisites

Install the command-line developer tools.

```sh
xcode-select --install
```

Install the build dependencies through Homebrew.

```sh
brew install cmake pkg-config freetype
```

The macOS path embeds Metal source and does not need glslangValidator.
SDL compiles the MSL source at runtime.
This platform path remains unverified in the delivery environment.

## Local source build

1. Run the bootstrap.
2. Add the local Zig directory to PATH.
3. Run the diagnostic tool.
4. Run the validation targets.
5. Start the app.

```sh
python3 tools/bootstrap.py --install-zig
export PATH="$PWD/.deps/zig:$PATH"
python3 tools/doctor.py
zig build verify
zig build run
```

The Zig installer checks the archive against the official HTTPS manifest's SHA-256 value.
That manifest and the archive share the upstream trust source.
The installer does not provide an independent signature check.
The installer refuses to replace an existing destination.

The bootstrap uses release tags and records their resolved commits in `.deps/resolved.json`.
It refuses a modified tracked source checkout.
The build still depends on system FreeType and driver versions.
It is not a hermetic dependency lock.

## Existing SDL installation

Select the SDK prefix explicitly.

```sh
zig build verify -Dsdl-prefix=/absolute/path/to/sdk
zig build run -Dsdl-prefix=/absolute/path/to/sdk -- --windowed
```

The SDK must expose `include/SDL3`, `include/SDL3_ttf`, and shared libraries under `lib` or `lib64`.
The build also uses the platform's normal library search paths.
It does not discover separate SDL and SDL_ttf prefixes through pkg-config.

For a nonstandard shader compiler path, set the build option.

```sh
zig build -Dglslang=/absolute/path/to/glslangValidator
```

## Terminal emulation

The editor's terminal is libghostty-vt, the emulator core extracted from
Ghostty, reached through its C API. It is built by `zig build -Demit-lib-vt`
with the Zig release Ghostty's own `build.zig.zon` names (0.16.0 at the pinned
commit), which is not the release this repository builds with. The C ABI is the
boundary, so neither toolchain has to move: `tools/bootstrap.py` installs the
pinned Zig into `.deps/zig-ghostty`, builds the library into the same prefix
SDL uses, and the editor links it as `ghostty-vt` through a `translate-c`
module like SDL and Yoga.

`dependencies.json` pins the repository and commit. Bumping that pin changes
which Zig the bootstrap downloads, because the version is part of the pin.

## Windows boundary

The repository provides a Vulkan shader path for Windows.
The bootstrap does not build a Windows SDK.
The CI workflow provides one from the pinned releases and runs `verify`
there, so the native build, the ACP integration suite, and the native tests
are exercised on Windows. Rendering is not: a hosted Windows runner has no
Vulkan driver, so the screenshot gate runs on Linux and macOS instead.
Windows compiles its shaders with the same command the build would run and
passes them to the build with `-Dshader-dir`.

1. Install Zig 0.17.0 and Python 3.12 or later.
2. Prepare matching SDL3 and SDL3_ttf development libraries in one SDK prefix.
3. Add the SDK's DLL directory to PATH.
4. Add glslangValidator to PATH.
5. Run the native build with that SDK prefix.

```powershell
$env:Path = "C:\sdk\bin;C:\tools\glslang\bin;$env:Path"
zig build verify -Dsdl-prefix=C:/sdk -Dpython=python
zig build run -Dsdl-prefix=C:/sdk -- --windowed
```

The compiler target and the SDK libraries must use compatible ABIs.
The app does not provide DXIL shaders or a D3D12 fallback.
The temporary-file save path also needs Windows path-encoding validation.

## Build targets

| Command | Meaning |
| --- | --- |
| `zig build` | Compile and install the app under `zig-out` |
| `zig build run` | Compile and run from the repository root |
| `zig build test` | Execute pure Zig core tests |
| `zig build integration` | Execute three native ACP transports against Python mock processes |
| `zig build integration-omp` | Run a live Oh-My-Pi ACP turn (requires `omp` on PATH and its credentials) |
| `zig build integration-claude` | Run a live Claude Code ACP turn (requires `claude-agent-acp` on PATH and its credentials) |
| `zig build test-native` | Execute native filesystem tests against SDL |
| `zig build check` | Compile the native app without execution |
| `zig build verify` | Execute core, transport, and filesystem tests, then compile the UI |
| `zig build screenshot` | Render two offscreen frames and compare the readbacks (needs a display and a Vulkan driver) |
| `python3 -m unittest discover -s tests -v` | Execute fixture tests without Zig or SDL |
| `python3 tools/check_repo.py` | Check repository structure and source contracts |

## Dependencies

`build.zig.zon` pins the toolchain, [zignal](https://github.com/arrufat/zignal)
(pure-Zig TrueType parsing for glyph selection), and
[quickjs-ng](https://github.com/mattneel/zig-quickjs-ng) (the extension host).
Both are pinned to a commit archive with a checksum, so a clean checkout builds
without any local setup.

Development builds of Zig have no release manifest, so `tools/zig-checksums.json`
records the expected sha256 for the pinned toolchain. Adding a platform means
downloading that archive, verifying it, and recording the digest there.

## Extensions

Extensions are TypeScript, bundled with esbuild. The build is optional: when
`extensions/dist` is absent the app runs and reports no extensions loaded.

```sh
cd extensions
npm install
npm run build
```

esbuild writes one IIFE script per source into `extensions/dist/`, which the
app loads at startup by resolving that directory under the workspace root.
`npm run typecheck` checks the sources against `extensions/types/seggs.d.ts`.

The QuickJS-NG bindings use `splitType`, which needs LLVM codegen, so the
executable is built with `use_llvm = true`. esbuild is a development
dependency; the shipped binary never invokes it.

## Display smoke test

Install Xvfb on a Linux test host.

```sh
sudo apt-get install -y xvfb
```

Run a bounded windowed session.

```sh
SDL_VIDEODRIVER=x11 xvfb-run -a zig build run -- --windowed --frames 8
```

The test needs a Vulkan implementation that works under that display setup.
The `--frames` option exits without the ordinary unsaved-change prompt.
No agent starts during this test.

Without a hardware GPU, force the Mesa software driver (lavapipe):

```sh
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json SDL_VIDEODRIVER=x11 \
  xvfb-run -a zig build run -- --windowed --frames 8
```

The ICD path is distribution-specific; locate it with `find /usr/share/vulkan/icd.d -name '*lvp*.json'`.

## Distribution boundary

The development build embeds an absolute library search path on Linux and macOS.
A relocatable package needs separate shared-library and install-name work.
The installer copies the mock to `share/seggs` beside the installed app layout.
The installer does not copy SDL libraries or fonts.

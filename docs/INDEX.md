# Seggs

Seggs is a GPU editor and a concurrent ACP client: one window that edits files,
runs agent harnesses beside them, and can be extended while it runs.

The editor is Zig over SDL3's GPU API, with one pipeline, one glyph atlas, and
one draw call per frame while every quad on it samples the atlas; a picture is
its own texture, and so its own draw. Interface is described as data by
extensions written in [SeggsC](EXTENSIONS.md), a TypeScript-shaped DSL, and laid
out with Yoga. Agents reach the editor over newline-delimited JSON-RPC on stdio,
and the editor answers with the files and terminals they ask for.

## What it does

- Edits UTF-8 files with a gap buffer, multiple documents, undo, selection, and
  grapheme-aware movement.
- Runs independent agent sessions with their own transcripts and permission
  requests that are explicit and one-shot. A review surface holds proposed edits
  until accepted; only the self-driving `--exercise-run` driver proposes to it,
  and an agent's own write goes straight to disk.
- Renders the transcript as Markdown, with a fenced diff drawn as a diff and tool
  calls drawn as chips where they happened, each opening to its fields and diff.
- Draws a displayed formula as the mathematics it is, typeset by a TeX engine
  rather than left as backslashes, and falls back to the source when the engine
  will not read it.
- Runs shells in a dock of tabs beside the editor: every dock resizes by dragging
  its divider, and one widget draws every list the interface opens.
- Repaints the whole interface, the terminal, and syntax colouring from a theme
  document, a TextMate `.tmTheme`, or a VS Code colour theme.
- Serves agent requests through a capability broker: editor-backed file reads and
  writes, and client-owned terminals with bounded output.
- Speaks to a language server for diagnostics and navigation; the debug adapter
  and Git clients are proven by the native tests, and nothing in the editor
  starts them.
- Draws its own interface, which extensions replace region by region without a
  restart.
- Writes a frame to a file in any of five image formats, and can drive itself to
  the state a reader would reach first, so what it looks like is checkable
  without a person in front of it.

## Where to start

| If you want to | Read |
| --- | --- |
| Build and run it | [Build](BUILD.md) |
| Understand the design | [Architecture](ARCHITECTURE.md) |
| Change the colours | [Architecture: themes](ARCHITECTURE.md#themes), then [what an import misses](LIMITATIONS.md#themes) |
| Write an extension | [SeggsC](EXTENSIONS.md) |
| Point an agent at it | [Agent setup](AGENTS.md) |
| Check what is verified | [Validation](VALIDATION.md) |
| Know what it does not do | [Limitations](LIMITATIONS.md) |
| See what is next | [Roadmap](ROADMAP.md) |

## Build the book

```sh
mdbook serve
```

The chapters are the repository's own Markdown under `docs/`, so a page edited
for the book is the page the repository links to.

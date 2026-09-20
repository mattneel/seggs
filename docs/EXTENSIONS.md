# SeggsC

SeggsC is a TypeScript-shaped DSL for the editor. An extension describes
interface as data, subscribes to events, and asks the editor to act. That is the
whole language: the `seggs` global, the node shapes below, and the events they
report.

What an extension cannot do is part of the design. It cannot reach the renderer,
the document, another extension's state, or the frame it is drawn in, except
through the surface described here.

Extensions are authored and bundled as TypeScript because that is convenient —
the editor is written in Zig, and a bundler that strips types is easier than a
parser that reads them. Nothing in the language depends on it: the host evaluates
plain JavaScript, and the declared types are checked before a bundle is written.
Authoring a bundle by hand in JavaScript is the same language.

This document is the whole contract.

## Interface

An extension describes interface as data. It returns a plain object and the
editor lays it out with Yoga and draws it through the same quad path as the rest
of the interface. Nothing about Yoga or the renderer reaches the description, so
a panel can be written without knowing either.

Bundles live in `extensions/dist`, built by esbuild from `extensions/src` and
evaluated by the host in `src/ext/host.zig`. Declarations for everything below
are in `extensions/types/seggs.d.ts`.

## API

| Call | Effect |
| --- | --- |
| `seggs.version()` | Core version string. |
| `seggs.status(message)` | Writes the status bar. It shows from the next frame. |
| `seggs.snapshot()` | State for this frame, or `undefined` before the first frame. |
| `seggs.ui.panel(name, provider)` | Fills a region. Replaces an earlier panel of the same name. The provider is called with the region's width and height. |
| `seggs.ui.on(event, handler)` | Subscribes to `click`, `activate`, or `key`. Subscriptions accumulate. |
| `seggs.agent.action(op, id)` | Asks the editor to `start`, `stop`, or `activate` an agent, by the id in the snapshot. |
| `seggs.editor.action(op, id)` | Asks the editor to `open` a file by the path the explorer shows, or `switch` to a buffer by name. |
| `seggs.extensions.list()` | What the host loaded, with the message from any bundle that failed. |
| `seggs.app.action(op)` | Asks the shell for something it does itself: `sidebar`, `prompt`, or `quick_open`. |

`seggs.snapshot()` returns:

```ts
{
  agents: { id: string; name: string; state: string; running: boolean }[];
  active: number;
  status: string;
  files: { root: string; entries: string[]; selected: string; scroll: number };
  buffers: { names: string[]; active: number };
  editor: { file: string; line: number; column: number; bytes: number; dirty: boolean };
}
```

## Regions

The interface offers named rectangles and an extension fills them by registering
a panel under that name. Regions drawn today:

| Region | Space |
| --- | --- |
| `activity` | The rail down the left edge, at every window size. |
| `explorer` | The file list, when the sidebar is open. |
| `tabs` | The tab strip above the document. |
| `header` | The line under the tabs, showing cursor and size. |
| `lanes` | The agent list at the top of the agents pane. |
| `transcript` | The space below the lanes, when the active agent has nothing to show. |
| `status` | The status bar across the bottom. |

The document itself — its text, line numbers, and highlighting — is drawn by the
editor rather than described by a panel: it is the file, not chrome around it.

The provider is called on every frame its region is drawn. It can read
`seggs.snapshot()` directly, so a panel that shows live state needs no
invalidation protocol. A provider that throws contributes nothing for that
frame and is reported once per call.

## Description

A node is an object with a `type`, style keys, and `children`:

```ts
seggs.ui.panel("lanes", () => ({
  type: "column",
  gap: 4,
  children: seggs.snapshot().agents.map((agent, index) => ({
    type: "row",
    height: 34,
    padding: 8,
    gap: 8,
    align: "center",
    background: index === seggs.snapshot().active ? "raised" : "panel",
    children: [
      { type: "box", width: 7, height: 7, color: "accent" },
      { type: "text", id: `lane-${agent.id}`, text: agent.name, grow: 1, color: "text", focusable: true },
    ],
  })),
}));
```

| Key | Meaning |
| --- | --- |
| `type` | `row`, `column`, `box`, or `text`. Defaults to `column`. |
| `id` | Name reported by events. Required for `focusable` nodes to be useful. |
| `text`, `color` | Content and text color of a `text` leaf. |
| `background` | Fill drawn behind a container before its children. |
| `width`, `height`, `minWidth`, `maxWidth` | Fixed sizes in device pixels. |
| `heightPercent` | Share of the parent's height. |
| `grow`, `shrink` | Flex factors, as in flexbox. |
| `padding`, `gap` | Space inside a node, and between its children. |
| `align` | Cross-axis placement: `start`, `center`, `end`, `stretch`. |
| `justify` | Main-axis placement: `start`, `center`, `end`, `between`. |
| `focusable` | Takes part in Tab order. |

Colors are theme names, never raw components, so a theme change reaches panels:
`text`, `muted`, `accent`, `amber`, `red`, `blue`, `purple`, `panel`, `raised`,
`selected`, `border`, `background`.

A `text` leaf is measured against the same cell grid the renderer draws on, so a
measured node occupies exactly the space its text fills.

A provider is told the size of its region, so a panel can decide what fits: the
file list drops its footer when the region is short, and the agent lanes drop
their state text when the column is narrow. Regions themselves come and go with
the window: below 1040 points the file list is dropped, below 880 the agent
column joins it, and the editor takes the space.

## Events

| Event | Fields | Fires |
| --- | --- | --- |
| `click` | `panel`, `id`, `x`, `y` | A click landed on a node. The deepest node with an `id` wins. |
| `activate` | `panel`, `id` | Enter or Space while the node has focus. |
| `key` | `panel`, `id`, `key` | Any other key while the panel owns the keyboard. |
| `hover` | `panel`, `id`, `x`, `y` | The pointer moved onto or off a node. Only a change is reported, so a handler does not run for every motion. |

Several extensions may subscribe to the same event: each handler is called for
every event and decides for itself whether the `panel` field names its own panel.

Clicking a panel gives it the keyboard and focuses the node under the pointer.
While a panel owns the keyboard, `Tab` and `Shift+Tab` move focus through the
focusable nodes of all panels and `Escape` returns the keyboard to the editor;
those three keys stay with the interface so an extension cannot trap them. Every
other key is reported to the focused node.

## Requests

`seggs.agent.action` does not act immediately. The request is queued and applied
by the editor between frames, so a handler never mutates state while a frame is
being drawn. The panel sees the result through the next `seggs.snapshot()`.

## Writing an extension from an agent

An agent augments the editor by writing an extension and reading back what
happened. The loop needs no new protocol: it is files in, files out, using the
capabilities the agent already has.

1. **Write** `extensions/src/<name>.ts` using `fs/write_text_file`.
2. **Build** it by running `node build.mjs` in `extensions/` through the terminal
   capability, which bundles every `src/*.ts` into `dist/<name>.js`.
3. **Wait a moment.** The editor watches its bundle directory and reloads within
   about a second. Nothing restarts, and the panels it draws change underneath.
4. **Read** `<workspace>/.seggs/extensions.json` to find out what happened. It is
   rewritten on every reload:

```json
{
  "generation": 2,
  "loaded": 4,
  "extensions": [
    { "name": "chrome.js", "loaded": true, "problem": "", "panels": 4 },
    { "name": "mine.js", "loaded": false, "problem": "SyntaxError: expecting ';'", "panels": 0 }
  ]
}
```

5. **Fix and repeat.** Writing the file again triggers another reload. A bundle
   that still fails keeps its message; one that loads reports `problem: ""`.

Managing extensions is managing files: a `.js` bundle in the directory is loaded,
deleting or renaming it unloads it, and a bundle whose name is not `.js` is
ignored. Reloading is all-or-nothing — every bundle is replaced at once — so an
extension cannot observe another one half-loaded.

Each extension gets its own JavaScript context. A bundle that throws does not
affect the others, and everything it registered disappears with it. When two
extensions register a panel for the same region the most recent one wins, so a
new bundle can take over a region without editing the old one.

An agent can watch its own work through `seggs.extensions.list()` inside an
extension, or simply by reading the report file it already has access to.

## Limits

Descriptions are untrusted input:

| Limit | Value |
| --- | --- |
| Description depth | 16 |
| Nodes per description | 512 |
| Event subscriptions | 32 |
| Queued actions | 32 |
| Panel name | 64 bytes |
| Action id | 64 bytes |

Exceeding a limit rejects that panel or request; it does not affect the rest of
the interface.

## Where to look

| Path | Role |
| --- | --- |
| `src/ext/host.zig` | JavaScript runtime, the `seggs` API, event dispatch, action queue. |
| `src/ext/ui.zig` | Description parsing, Yoga layout, drawing, hit testing. |
| `src/ui/yoga.h` | The only file that names a Yoga path. |
| `extensions/src/*.ts` | The panels shipped with the editor. |
| `<workspace>/.seggs/extensions.json` | Load report for authors and agents, rewritten on every reload. |

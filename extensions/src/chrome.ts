/// <reference path="../types/seggs.d.ts" />

// The chrome around the document: the file list, the tab strip, the line under
// it, and the status bar. All four were drawn by the editor itself; now the
// editor offers the rectangles and these panels fill them.
//
// The editor still draws the document: the text, line numbers, and highlighting
// are the file rather than chrome around it.

// The node the pointer is over, so rows can respond to it. It is a panel-local
// detail: the provider runs on every frame and reads it.
let chromeHovered = "";

seggs.ui.on("hover", (event) => {
  if (event.panel === "explorer" || event.panel === "tabs") chromeHovered = event.id;
});

seggs.ui.panel("explorer", (_width, height) => {
  const files = seggs.snapshot()?.files;
  if (!files) return { type: "column" };
  // The header and the footer take their space first, then a row is 24 tall.
  const rows = Math.max(0, Math.floor((height - 96) / 24));
  const visible = files.entries.slice(files.scroll, files.scroll + rows);
  return {
    type: "column",
    padding: 12,
    gap: 8,
    children: [
      { type: "text", text: "EXPLORER", color: "muted" },
      { type: "text", text: files.root, color: "accent" },
      // Rows sit directly against each other, so the list keeps the density it
      // had when the editor drew it.
      {
        type: "column",
        gap: 0,
        grow: 1,
        children: visible.map((path): SeggsPanelNode => ({
          type: "row",
          height: 24,
          padding: 4,
          align: "center",
          background: path === files.selected ? "raised" : chromeHovered === `file:${path}` ? "selected" : undefined,
          children: [
            {
              type: "text",
              id: `file:${path}`,
              text: path,
              color: path === files.selected || chromeHovered === `file:${path}` ? "text" : "muted",
              focusable: true,
              grow: 1,
            },
          ],
        })),
      },
      // Pushes the footer to the bottom, where it is dropped as the region runs
      // out of room rather than crowding the list.
      { type: "column", grow: 1 },
      ...(height >= 320 ? [{ type: "text" as const, text: "Ctrl+P  quick open", color: "muted" as const }] : []),
    ],
  };
});

seggs.ui.panel("tabs", () => {
  const buffers = seggs.snapshot()?.buffers;
  const names = buffers?.names ?? [];
  const active = buffers?.active ?? 0;
  return {
    type: "row",
    padding: 2,
    gap: 2,
    align: "end",
    children: names.map((name, index): SeggsPanelNode => ({
      type: "column",
      gap: 2,
      background: index === active ? "raised" : chromeHovered === `tab:${name}` ? "selected" : undefined,
      children: [
        {
          type: "row",
          padding: 4,
          children: [
            {
              type: "text",
              id: `tab:${name}`,
              text: name,
              color: index === active ? "text" : "muted",
              focusable: true,
            },
          ],
        },
        // Spans the tab: the column stretches its children.
        { type: "box", height: 2, color: index === active ? "accent" : "border" },
      ],
    })),
  };
});

seggs.ui.panel("header", () => {
  const editor = seggs.snapshot()?.editor;
  const text = editor
    ? `UTF-8  /  Ln ${editor.line}, Col ${editor.column}  /  ${editor.bytes} bytes${editor.dirty ? "  /  edited" : ""}`
    : "";
  return {
    type: "row",
    padding: 8,
    align: "center",
    children: [{ type: "text", text, color: "muted" }],
  };
});

seggs.ui.panel("status", () => ({
  type: "row",
  padding: 6,
  align: "center",
  children: [{ type: "text", text: seggs.snapshot()?.status ?? "", color: "text" }],
}));

// A file row opens a file, a tab switches buffers. Both are asked for rather
// than done directly, so the editor applies them between frames.
const handleChrome = (event: { panel: string; id: string }): void => {
  if (event.panel === "explorer" && event.id.startsWith("file:")) {
    seggs.editor.action("open", event.id.slice("file:".length));
    return;
  }
  if (event.panel === "tabs" && event.id.startsWith("tab:")) {
    seggs.editor.action("switch", event.id.slice("tab:".length));
  }
};

seggs.ui.on("click", handleChrome);
seggs.ui.on("activate", handleChrome);

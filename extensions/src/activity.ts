/// <reference path="../types/seggs.d.ts" />

// The activity rail. It used to be three letters drawn by the editor with one
// hard-coded marker; now it is a panel, so the labels, spacing, and hover state
// are interface rather than code.

type Entry = { op: "sidebar" | "prompt" | "quick_open"; label: string; isActive: boolean };

let railHovered = "";

seggs.ui.panel("activity", (_width, height) => {
  const state = seggs.snapshot();
  const entries: Entry[] = [
    { op: "sidebar", label: "F", isActive: state?.sidebar ?? true },
    { op: "prompt", label: "A", isActive: state?.focus === "prompt" },
    { op: "quick_open", label: ">", isActive: false },
  ];
  const rowHeight = 34;
  const visible = Math.max(0, Math.floor((height - 16) / (rowHeight + 6)));
  return {
    type: "column",
    padding: 8,
    gap: 6,
    background: "panel",
    children: entries.slice(0, Math.max(0, Math.min(entries.length, visible))).map((entry): SeggsPanelNode => {
      const id = `app:${entry.op}`;
      const hot = railHovered === id;
      return {
        type: "row",
        height: rowHeight,
        align: "center",
        justify: "center",
        background: entry.isActive ? "selected" : hot ? "raised" : undefined,
        children: [
          {
            type: "text",
            id,
            text: entry.label,
            color: entry.isActive ? "accent" : hot ? "text" : "muted",
            focusable: true,
          },
        ],
      };
    }),
  };
});

seggs.ui.on("hover", (event) => {
  if (event.panel !== "activity") return;
  railHovered = event.id;
});

seggs.ui.on("click", (event) => {
  if (event.panel !== "activity" || !event.id.startsWith("app:")) return;
  seggs.app.action(event.id.slice("app:".length) as "sidebar" | "prompt" | "quick_open");
});

seggs.ui.on("activate", (event) => {
  if (event.panel !== "activity" || !event.id.startsWith("app:")) return;
  seggs.app.action(event.id.slice("app:".length) as "sidebar" | "prompt" | "quick_open");
});

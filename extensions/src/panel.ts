/// <reference path="../types/seggs.d.ts" />

// The panel a session shows while no agent transcript exists. It used to be a
// string compiled into the editor; describing it here means the wording, the
// colors, and the spacing can change without touching the renderer.
//
// The provider runs each time the panel is drawn, so anything it reads is
// current at that moment.

const hint = (id: string, text: string): SeggsPanelNode => ({
  type: "text",
  id,
  text,
  color: "muted",
  // Focusable so Tab reaches it and the focus ring shows where the keyboard is.
  focusable: true,
});

seggs.ui.panel("transcript", () => ({
  type: "column",
  gap: 6,
  children: [
    {
      type: "text",
      id: "title",
      text: `No agent starts automatically. seggs ${seggs.version()}`,
      color: "text",
    },
    hint("blank-1", " "),
    hint("start", "F5 starts this agent."),
    hint("focus", "Ctrl+L focuses the prompt."),
    hint("send", "Ctrl+Enter sends to this agent."),
    hint("broadcast", "Ctrl+Shift+Enter sends to ready agents."),
    hint("blank-2", " "),
    {
      type: "row",
      gap: 6,
      children: [
        { type: "box", id: "marker", width: 3, height: 18, color: "accent" },
        {
          type: "text",
          text: "The local mock needs no account.",
          color: "muted",
        },
      ],
    },
    hint("worktrees", "Use separate worktrees for parallel edits."),
  ],
}));

// Events from the interface arrive here. A click reports the node that was hit,
// which is how a panel turns its own description into something interactive.
seggs.ui.on("click", (event) => {
  // The lanes panel handles its own clicks; this reports the rest.
  if (event.panel !== "transcript") return;
  seggs.status(`panel ${event.panel}: clicked ${event.id || "(panel)"}`);
});

// Enter or Space on the focused node.
seggs.ui.on("activate", (event) => {
  if (event.panel !== "transcript") return;
  seggs.status(`panel ${event.panel}: activate ${event.id || "(panel)"}`);
});

// Any other key while the panel owns the keyboard. Tab and Escape stay with the
// interface, so an extension cannot trap them.
seggs.ui.on("key", (event) => {
  if (event.panel !== "transcript") return;
  seggs.status(`panel ${event.panel}: key ${event.key} on ${event.id || "(panel)"}`);
});

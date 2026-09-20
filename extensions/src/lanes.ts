/// <reference path="../types/seggs.d.ts" />

// The agent lanes. This used to be drawn by the editor itself, one row per
// configured agent with a state dot, a state label, and a start/stop control.
// Now the editor offers the `lanes` rectangle and this extension fills it, so
// the wording, colors, and controls change without touching the renderer.
//
// Requests go back through `seggs.agent.action`, which the editor applies
// between frames.

type Agent = { id: string; name: string; state: string; running: boolean };

// The lane under the pointer, so a row responds before it is clicked.
let lanesHovered = "";

seggs.ui.on("hover", (event) => {
  if (event.panel === "lanes") lanesHovered = event.id;
});

const tint = (agent: Agent): "accent" | "purple" | "red" | "muted" => {
  switch (agent.state) {
    case "ready":
      return "accent";
    case "busy":
    case "cancelling":
      return "purple";
    case "failed":
      return "red";
    default:
      return "muted";
  }
};

seggs.ui.panel("lanes", (width) => {
  const state = seggs.snapshot();
  const agents: Agent[] = state?.agents ?? [];
  const active: number = state?.active ?? 0;
  // A narrow column keeps the name and drops the details rather than squeezing
  // every field until none of them can be read.
  const detailed = width >= 300;
  return {
    type: "column",
    gap: 4,
    children: agents.map((agent, index) => ({
      type: "row",
      height: 34,
      padding: 8,
      gap: 8,
      align: "center",
      background:
        index === active ? "raised" : lanesHovered === `lane-${agent.id}` || lanesHovered === `toggle-${agent.id}` ? "selected" : "panel",
      children: [
        { type: "box", width: 7, height: 7, color: tint(agent) },
        {
          type: "text",
          id: `lane-${agent.id}`,
          text: `${index + 1} ${agent.name}`,
          color: index === active ? "text" : "muted",
          grow: 1,
          focusable: true,
        },
        ...(detailed
          ? [{ type: "text" as const, text: agent.state.toUpperCase(), color: tint(agent) }]
          : []),
        {
          type: "text",
          id: `toggle-${agent.id}`,
          text: agent.running ? "STOP" : "START",
          color: "accent",
          focusable: true,
        },
      ],
    })),
  };
});

// A control acts, a lane selects. Both report through the snapshot, so the panel
// reflects what the editor actually did rather than what was asked of it.
const handle = (event: { panel: string; id: string }): void => {
  if (event.panel !== "lanes") return;
  const agents: Agent[] = seggs.snapshot()?.agents ?? [];
  const agent = agents.find(
    (candidate) => event.id === `toggle-${candidate.id}` || event.id === `lane-${candidate.id}`,
  );
  if (!agent) return;
  if (event.id.startsWith("toggle-")) {
    seggs.agent.action(agent.running ? "stop" : "start", agent.id);
    return;
  }
  seggs.agent.action("activate", agent.id);
};

seggs.ui.on("click", handle);
seggs.ui.on("activate", handle);

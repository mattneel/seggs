/**
 * Ambient types for SeggsC, the TypeScript-shaped DSL extensions are written in.
 *
 * The host installs `seggs` as a global before evaluating a bundle, so these
 * declarations are global on purpose. They exist so a bundle can be type
 * checked before it is written; the host itself evaluates plain JavaScript and
 * never sees them.
 */

/** A node in a panel description. Unknown fields are rejected. */
type SeggsPanelNode = {
  /** Container and leaf kinds. Defaults to `column`. */
  type?: "row" | "column" | "box" | "text";
  /** Name reported back when the node is clicked. */
  id?: string;
  /** Content of a `text` leaf. */
  text?: string;
  /** Theme color name, so a theme change reaches extension panels. */
  color?: "text" | "muted" | "accent" | "amber" | "red" | "blue" | "purple" | "panel" | "raised" | "selected" | "border" | "background";
  /** Fixed size in device pixels. */
  width?: number;
  height?: number;
  minWidth?: number;
  maxWidth?: number;
  /** Percentage of the parent's height, for bands that scale. */
  heightPercent?: number;
  /** Flex factors. `grow: 1` takes the space left over in a row or column. */
  grow?: number;
  shrink?: number;
  /** Fill drawn behind a container before its children. */
  background?: "text" | "muted" | "accent" | "amber" | "red" | "blue" | "purple" | "panel" | "raised" | "selected" | "border" | "background";
  /** Whether the node takes part in Tab order. Give it an `id` so events name it. */
  focusable?: boolean;
  /** Space inside the node, and between its children. */
  padding?: number;
  gap?: number;
  /** Cross-axis placement of children. */
  align?: "start" | "center" | "end" | "stretch";
  /** Main-axis placement of children. */
  justify?: "start" | "center" | "end" | "between";
  children?: SeggsPanelNode[];
};

declare const seggs: {
  /** Core version string, for example "0.2.0". */
  version(): string;
  /** State of the editor for this frame, or undefined before the first frame. */
  snapshot():
    | {
        agents: { id: string; name: string; state: string; running: boolean }[];
        active: number;
        status: string;
        sidebar: boolean;
        focus: "editor" | "prompt" | "panels";
        files: { root: string; entries: string[]; selected: string; scroll: number };
        buffers: { names: string[]; active: number };
        app: {
    /** Ask the shell for something it does itself. */
    action(op: "sidebar" | "prompt" | "quick_open"): void;
  };
  editor: { file: string; line: number; column: number; bytes: number; dirty: boolean };
      }
    | undefined;
  app: {
    /** Ask the shell for something it does itself. */
    action(op: "sidebar" | "prompt" | "quick_open"): void;
  };
  editor: {
    /** Ask the editor to show a file, by the path the explorer shows, or a buffer by name. */
    action(op: "open" | "switch", id: string): void;
  };
  extensions: {
    /** What the host loaded, with the message from any bundle that failed. */
    list(): {
      generation: number;
      loaded: number;
      extensions: { name: string; loaded: boolean; problem: string; panels: number }[];
    };
  };
  agent: {
    /**
     * Ask the interface to start, stop, or activate an agent. Requests are
     * applied between frames, so a handler never disturbs the frame it runs in.
     */
    action(op: "start" | "stop" | "activate", id: string): void;
  };
  /** Write a message to the editor status bar. */
  status(message: string): void;
  ui: {
    /**
     * Register a panel under a name, replacing any earlier one. The provider is
     * called whenever the panel is drawn, with the size of the region it fills,
     * so it can read live state and decide how much fits; a provider that throws
     * contributes nothing for that frame.
     */
    panel(name: string, provider: (width: number, height: number) => SeggsPanelNode): void;
    /**
     * Subscribe to interface events. `click` fires when a click lands on one of
     * the panel's nodes, with the node's `id` and the panel it belongs to.
     */
    on(
      event: "click",
      handler: (event: { panel: string; id: string; x: number; y: number }) => void,
    ): void;
    /** Fires when Enter or Space is pressed while the node has focus. */
    on(event: "activate", handler: (event: { panel: string; id: string }) => void): void;
    /** Fires for any other key while the panel owns the keyboard. */
    on(event: "key", handler: (event: { panel: string; id: string; key: string }) => void): void;
    /**
     * Fires when the pointer moves onto or off a node, so a panel can respond
     * before it is clicked. Only a change is reported.
     */
    on(event: "hover", handler: (event: { panel: string; id: string; x: number; y: number }) => void): void;
  };
};

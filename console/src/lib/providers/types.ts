// The data-source abstraction: today only OutlineProvider implements this,
// but keeping it as an interface is what lets a future backend (NetBox,
// flat YAML, whatever) slot in later without touching the UI or the widget
// layer - see registry.ts for how the active provider is chosen.

export interface DashboardLink {
  label: string;
  url: string;
}

export interface Machine {
  /** Stable id from the underlying provider (e.g. the Outline doc id). */
  id: string;
  hostname: string;
  tailscaleAddrs: string[];
  tags: string[];
  kvmUrl?: string;
  dashboardLinks: DashboardLink[];
  role?: string;
  /** Any table fields not mapped to a known column above. */
  raw: Record<string, string>;
  /** Deep link back to the source-of-truth doc, for "edit this" actions. */
  sourceUrl?: string;
}

export interface MachineProvider {
  listMachines(): Promise<Machine[]>;
}

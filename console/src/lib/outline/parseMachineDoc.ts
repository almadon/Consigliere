import type { DashboardLink, Machine } from "../providers/types";

/**
 * Expected convention (see console/README.md): a plain markdown table near
 * the top of each per-machine Outline doc, e.g.
 *
 *   | Field      | Value                               |
 *   |------------|--------------------------------------|
 *   | Hostname   | server01                             |
 *   | Tailscale  | 100.x.x.x, tag:server                |
 *   | KVM        | https://pikvm.example.ts.net         |
 *   | Dashboards | Grafana|https://..., Uptime|https://...|
 *   | Role       | swarm-manager                        |
 *
 * Only the first table in the doc is parsed; everything else in the doc
 * (notes, history, whatever) is left alone.
 */
export function parseMachineDoc(id: string, sourceUrl: string, text: string): Machine {
  const fields = extractFirstTable(text);

  const get = (name: string) => fields[name.toLowerCase()];

  const hostname = get("hostname") ?? "unknown";
  delete fields["hostname"];

  const tailscale = get("tailscale");
  delete fields["tailscale"];
  const tailscaleAddrs: string[] = [];
  const tags: string[] = [];
  for (const part of tailscale?.split(",").map((s) => s.trim()) ?? []) {
    if (part.startsWith("tag:")) tags.push(part);
    else if (part) tailscaleAddrs.push(part);
  }

  const kvmUrl = get("kvm");
  delete fields["kvm"];

  const role = get("role");
  delete fields["role"];

  const dashboardLinks = parseLinks(get("dashboards"));
  delete fields["dashboards"];

  return {
    id,
    hostname,
    tailscaleAddrs,
    tags,
    kvmUrl,
    role,
    dashboardLinks,
    raw: fields,
    sourceUrl,
  };
}

/** "Label|https://url, Label2|https://url2" - label falls back to the URL host if omitted. */
function parseLinks(value?: string): DashboardLink[] {
  if (!value) return [];
  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [maybeLabel, maybeUrl] = entry.split("|").map((s) => s.trim());
      const url = maybeUrl ?? maybeLabel ?? "";
      const label = maybeUrl ? maybeLabel : safeHostname(url);
      return { label: label || url, url };
    });
}

function safeHostname(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

/** Parses the first GFM-style pipe table in `text` into a lowercase-keyed field map. */
function extractFirstTable(text: string): Record<string, string> {
  const lines = text.split("\n").map((l) => l.trim());
  const fields: Record<string, string> = {};

  let start = -1;
  for (let i = 0; i < lines.length - 1; i++) {
    if (lines[i]?.startsWith("|") && /^\|?\s*:?-+:?\s*\|/.test(lines[i + 1] ?? "")) {
      start = i;
      break;
    }
  }
  if (start === -1) return fields;

  for (let i = start + 2; i < lines.length; i++) {
    const line = lines[i];
    if (!line?.startsWith("|")) break;

    // Split on unescaped pipes only; a backslash-escaped pipe inside a cell is a literal pipe
    // (how Outline/GFM writes one), so it must survive into the value.
    const cells = line
      .split(/(?<!\\)\|/)
      .slice(1, -1)
      .map((c) => c.trim().replace(/\\\|/g, "|"));
    if (cells.length < 2) continue;

    const [key, ...rest] = cells;
    if (key) fields[key.toLowerCase()] = rest.join("|").trim();
  }

  return fields;
}

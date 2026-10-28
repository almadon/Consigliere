// Best-effort live reachability lookup - if TAILSCALE_API_KEY isn't set,
// callers just get an empty map back and tiles render without a status dot
// rather than the dashboard failing to load.

interface TailscaleDevice {
  hostname: string;
  addresses: string[];
  online: boolean;
  lastSeen: string;
}

export async function getTailscaleStatusByHostname(): Promise<Map<string, TailscaleDevice>> {
  const key = process.env.TAILSCALE_API_KEY;
  const tailnet = process.env.TAILSCALE_TAILNET ?? "-";
  const byHostname = new Map<string, TailscaleDevice>();
  if (!key) return byHostname;

  try {
    const res = await fetch(
      `https://api.tailscale.com/api/v2/tailnet/${encodeURIComponent(tailnet)}/devices`,
      { headers: { Authorization: `Bearer ${key}` }, cache: "no-store" }
    );
    if (!res.ok) return byHostname;

    const body = (await res.json()) as { devices: TailscaleDevice[] };
    for (const d of body.devices ?? []) {
      byHostname.set(d.hostname.toLowerCase(), d);
    }
  } catch {
    // Network hiccup or API shape drift - degrade gracefully, see note above.
  }

  return byHostname;
}

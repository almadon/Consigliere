import { getProvider } from "../providers/registry";
import { getDocument, updateDocumentText } from "./client";
import type { Machine } from "../providers/types";

const START = "<!-- consigliere:overview:start -->";
const END = "<!-- consigliere:overview:end -->";

/**
 * Regenerates the table between the `consigliere:overview` markers in the
 * configured overview doc from every machine doc's own fields - this is
 * what replaces hand-copying data into a separate overview page. The rest
 * of the doc (anything outside the markers) is left untouched.
 *
 * The markers need to be added to the overview doc once, by hand:
 *
 *   <!-- consigliere:overview:start -->
 *   (this content gets replaced on every sync)
 *   <!-- consigliere:overview:end -->
 */
export async function syncOverview(): Promise<{ machineCount: number }> {
  const overviewDocId = process.env.OUTLINE_OVERVIEW_DOC_ID;
  if (!overviewDocId) throw new Error("OUTLINE_OVERVIEW_DOC_ID is not set");

  const machines = await getProvider().listMachines();
  const table = renderTable(machines);

  const doc = await getDocument(overviewDocId);
  const startIdx = doc.text.indexOf(START);
  const endIdx = doc.text.indexOf(END);

  if (startIdx === -1 || endIdx === -1 || endIdx < startIdx) {
    throw new Error(
      `Overview doc is missing the ${START} / ${END} markers - add them once, ` +
        "anywhere in the doc, and re-run sync."
    );
  }

  const before = doc.text.slice(0, startIdx + START.length);
  const after = doc.text.slice(endIdx);
  const newText = `${before}\n${table}\n${after}`;

  await updateDocumentText(overviewDocId, newText);
  return { machineCount: machines.length };
}

function renderTable(machines: Machine[]): string {
  const header = "| Hostname | Role | Tailscale | KVM | Dashboards |";
  const sep = "|---|---|---|---|---|";
  const rows = machines.map((m) => {
    const addrs = m.tailscaleAddrs.join(", ") || "-";
    const kvm = m.kvmUrl ? `[link](${m.kvmUrl})` : "-";
    const dashboards =
      m.dashboardLinks.map((l) => `[${l.label}](${l.url})`).join(", ") || "-";
    const source = m.sourceUrl ? `[${m.hostname}](${m.sourceUrl})` : m.hostname;
    return `| ${source} | ${m.role ?? "-"} | ${addrs} | ${kvm} | ${dashboards} |`;
  });
  return [header, sep, ...rows].join("\n");
}

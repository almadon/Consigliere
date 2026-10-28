import type { Machine } from "@/lib/providers/types";
import { MachineTile } from "./MachineTile";

export function TileGrid({
  machines,
  onlineByHostname,
}: {
  machines: Machine[];
  onlineByHostname: Map<string, boolean>;
}) {
  if (machines.length === 0) {
    return <p className="empty-state">No machines found - check MACHINE_PROVIDER config.</p>;
  }

  return (
    <div className="tile-grid">
      {machines.map((m) => (
        <MachineTile
          key={m.id}
          machine={m}
          online={onlineByHostname.get(m.hostname.toLowerCase())}
        />
      ))}
    </div>
  );
}

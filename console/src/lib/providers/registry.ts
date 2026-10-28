import type { MachineProvider } from "./types";
import { OutlineProvider } from "./outline";

export function getProvider(): MachineProvider {
  const kind = process.env.MACHINE_PROVIDER ?? "outline";

  switch (kind) {
    case "outline":
      return new OutlineProvider();
    default:
      throw new Error(
        `Unknown MACHINE_PROVIDER "${kind}" - only "outline" is implemented today.`
      );
  }
}

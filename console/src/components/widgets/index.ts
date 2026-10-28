// Widget registry - the point of keeping this indirection (rather than
// hardcoding a fixed tile layout) is that adding a new widget later means
// adding a component + a line here, not restructuring MachineTile.

export { KvmWidget } from "./KvmWidget";
export { DashboardLinksWidget } from "./DashboardLinksWidget";
export { SshLaunchWidget } from "./SshLaunchWidget";
export { StatusWidget } from "./StatusWidget";

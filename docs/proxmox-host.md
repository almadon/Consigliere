# Adding a Proxmox VE host

A Proxmox VE (PVE) node is Debian underneath, so the normal bootstrap and the reconciler work, but a few of the baseline's defaults would
damage it. Tag the node `util: [pve]` (and `type: metal` for a physical machine) and put the overrides in the fleet's
`config/vars/group/util_pve.yml`, so every node you add later gets them:

```yaml
baseline_short_hostname: false              # PVE ties the node's name to its certificates and (in a cluster) its membership
firewall_manage: false                      # PVE has its own firewall; ufw on top breaks VM and cluster networking
baseline_unattended_upgrades_manage: false  # PVE and kernel upgrades are done on purpose
baseline_packages: [sudo, curl, gnupg, ca-certificates, python3-apt, git, jq, rsync, htop, apt-listchanges]   # no ufw, no unattended-upgrades
tailscale_args: "--accept-dns=false"        # Tailscale must not rewrite the node's DNS; no routes are accepted or advertised
tailscale_udp_gro_tuning: false             # leave the NIC under the VM bridges alone
tailscale_ip_forwarding: false              # PVE manages forwarding itself
```

What it still gets: the Tailscale join, key-only SSH, the OpenTelemetry agent (`feat: [otel]`, journal and task logs to Loki) and the
reconciler itself. Docker-based features (the Arkeep and Beszel agents) are not tagged: back VMs up with Proxmox Backup Server.

- **Cluster nodes.** Do not change the node's name, `/etc/hosts` or the cluster network. Tailscale is installed without routes or an exit
  node, so it never touches the network corosync uses. Add one node first and check the cluster is quorate (`pvecm status`).
- **Check first.** `scripts/reconcile-now.sh <node> --check` reports what would change without changing anything.

## Enrolling the node (do NOT rename it)

The generic steps tell you to run `hostnamectl set-hostname <name>`. **Do not on a Proxmox node**: renaming it breaks its certificates and its
place in the cluster. The fleet identifies a host by its **Tailscale name**, which is separate from the OS hostname, so:

1. Register it in the fleet's `config/inventory/hosts.yml` under the Tailscale name you want (for example `radon`), with `type: metal`, `util: [pve]`
   and the features you want (`feat: [otel]`). If the OS hostname differs, give Tailscale the name explicitly: `tailscale_args: "--accept-dns=false
   --hostname=radon"` in the host's own vars file (it replaces the group value, so repeat `--accept-dns=false`).
2. On the node, as root, run the bootstrap **without** `NODE_NAME`, and with a tagged one-off Tailscale auth key (`TAILSCALE_AUTHKEY`).
3. Add the printed deploy key (read-only) to the fleet repo, then register the age key with `scripts/node.sh key <name>`.

## Metrics to VictoriaMetrics

Proxmox VE 9 can push its own metrics (nodes, guests, storage) over OpenTelemetry. With `util: [pve]` and `util: [victoria]` somewhere in the fleet, set
`otel_agent_otlp_listen: "127.0.0.1:4318"` and `otel_agent_metrics_url` (VictoriaMetrics' `/opentelemetry` base) for the Proxmox hosts. Then, once for the
cluster: Datacenter > Metric Server > Add > OpenTelemetry, server `127.0.0.1`, port `4318`, protocol HTTP, path `/v1/metrics`, verify SSL off. Each node's
`pvestatd` sends to its own local collector, which forwards to VictoriaMetrics as protobuf (which is all VictoriaMetrics accepts; Proxmox may send JSON).
Metric names arrive as `proxmox_node_*`, `proxmox_vm_*`, `proxmox_storage_*`; the `cpustat` ones are ratios, not percentages.

## Intel e1000e network ports can hang

A Proxmox node whose onboard Intel port uses the `e1000e` driver can lose its network under load until it is power-cycled; the kernel log of the previous boot shows
`e1000e ... Detected Hardware Unit Hang`. Switch off TSO/GSO/GRO on that port: set `nic_offload_interfaces` for the host (role `nic_offload`, applied by `util: [pve]`), for example
`[{name: eno1, disable: [tso, gso, gro]}]`. Applying it can reset that link for a second or two.

## Two nodes and a quorum device

Votes decide whether a node may change the cluster. With two nodes of one vote each and a quorum device (an arbitrator on a third machine, `corosync-qnetd`) holding one more, either node
plus the device is 2 of 3 and keeps working alone (the failover case). **A node with extra votes instead (say Radon with 2 and Argon with 1) works alone with no device, but then the other node can
never be quorate by itself, so it cannot take over; adding a device on top of that makes the heavy node depend on the device.** Pick one scheme on purpose. The device's host must be reachable on
5403/tcp from both nodes, and `pvecm qdevice setup <ip>` needs root SSH to it with `corosync-qnetd` installed.

# Adding a Proxmox VE host

A Proxmox VE (PVE) node is Debian underneath, so the normal bootstrap and the reconciler work, but a few of the baseline's defaults would
damage it. Tag the node `util: [pve]` (and `type: metal` for a physical machine) and put the overrides in the fleet's
`config/vars/group/util_pve.yml`, so every node you add later gets them:

```yaml
baseline_short_hostname: false              # PVE ties the node's name to its certificates and (in a cluster) its membership
firewall_manage: false                      # PVE has its own firewall; ufw on top breaks VM and cluster networking
baseline_unattended_upgrades_manage: false  # PVE and kernel upgrades are done on purpose
baseline_packages: [sudo, curl, gnupg, ca-certificates, python3-apt, git, jq, rsync, htop, apt-listchanges]   # no ufw, no unattended-upgrades
```

What it still gets: the Tailscale join, key-only SSH, the OpenTelemetry agent (`feat: [otel]`, journal and task logs to Loki) and the
reconciler itself. Docker-based features (the Arkeep and Beszel agents) are not tagged: back VMs up with Proxmox Backup Server.

- **Cluster nodes.** Do not change the node's name, `/etc/hosts` or the cluster network. Tailscale is installed without routes or an exit
  node, so it never touches the network corosync uses. Add one node first and check the cluster is quorate (`pvecm status`).
- **Check first.** `scripts/reconcile-now.sh <node> --check` reports what would change without changing anything.

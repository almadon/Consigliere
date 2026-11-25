# Credits

Consigliere is mostly glue. Nearly everything useful on a host is someone else's software, and this page names it, links to it, and says what it is used for. Thank you to the people who build and maintain all of it.

What this project adopts, under which licence, and what it passed over. A licence marked VERIFY has not been checked at the pinned version; check it before distributing anything built on this. The links go to each project's repository or home page, and `VERIFY` also covers whether a link still resolves.

| Component | Used for | Licence |
|---|---|---|
| [Ansible](https://github.com/ansible/ansible) ([docs](https://docs.ansible.com)) | Configuration engine | GPL-3.0, VERIFY |
| [Tailscale client](https://github.com/tailscale/tailscale) ([site](https://tailscale.com)) | Network | BSD-3-Clause, VERIFY |
| [sops](https://github.com/getsops/sops), [age](https://github.com/FiloSottile/age) | Secrets | MPL-2.0, BSD-3-Clause, VERIFY |
| [Docker CE](https://docs.docker.com/engine/) | Container engine | Apache-2.0, VERIFY |
| [Traefik](https://github.com/traefik/traefik) | Edge proxy | MIT, VERIFY |
| [Cert Warden](https://github.com/gregtwallace/certwarden) | ACME client | Stated in the README as non-commercial; VERIFY the exact terms |
| [OpenTelemetry Collector (contrib)](https://github.com/open-telemetry/opentelemetry-collector-contrib) ([docs](https://opentelemetry.io/docs/collector)) | Log and metric shipping | Apache-2.0, VERIFY |
| [Loki](https://github.com/grafana/loki), [Grafana](https://github.com/grafana/grafana) | Logs, dashboards | AGPL-3.0, VERIFY |
| [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) | Metrics | Apache-2.0, VERIFY |
| [Arkeep](https://github.com/arkeep-io/arkeep) | Backups | VERIFY |
| [restic](https://github.com/restic/restic), [rest-server](https://github.com/restic/rest-server) | Backups | BSD-2-Clause, VERIFY |
| [Arcane](https://github.com/getarcaneapp/arcane) | Compose GitOps | VERIFY |
| [Garage](https://garagehq.deuxfleurs.fr) | S3 object store | AGPL-3.0, VERIFY |
| [Muximux](https://github.com/mescon/Muximux), [Homarr](https://github.com/homarr-labs/homarr), [Beszel](https://github.com/henrygd/beszel) | Console, dashboard, host monitoring | VERIFY |
| [Wazuh](https://github.com/wazuh/wazuh) ([wazuh-docker](https://github.com/wazuh/wazuh-docker)) | Security monitoring | VERIFY |
| [Apprise](https://github.com/caronc/apprise) ([apprise-api](https://github.com/caronc/apprise-api)) | Notifications | BSD-2-Clause, VERIFY |
| [Supernotify](https://supernotify.rhizomatics.org.uk) ([repo](https://github.com/rhizomatics/supernotify)) | Delivers fleet alerts inside Home Assistant (used by the fleet, not deployed by this repo) | VERIFY |
| [Home Assistant](https://github.com/home-assistant/core) | Receives the notification relay's calls (not deployed by this repo) | VERIFY |
| [Pocket ID](https://github.com/pocket-id/pocket-id) | Sign-in (used by the fleet, not deployed by this repo) | VERIFY |
| Ansible collections [`community.general`](https://github.com/ansible-collections/community.general), [`community.docker`](https://github.com/ansible-collections/community.docker), [`ansible.posix`](https://github.com/ansible-collections/ansible.posix) | Modules the roles call (`hosts/requirements.yml`); `ansible.posix` 2.2.2 is also installed on the hosts (`hosts/requirements-hosts.yml`) because the bundled 2.1.x imports from a module removed in ansible-core 2.24 | GPL-3.0, VERIFY |
| [Alpine Linux](https://alpinelinux.org), [OpenRC](https://github.com/OpenRC/openrc), [BusyBox](https://busybox.net), [apk-tools](https://gitlab.alpinelinux.org/alpine/apk-tools) | A supported host platform: package manager, init system and cron the platform layer drives (`hosts/platforms/alpine.yml`) | MIT, BSD-2-Clause, GPL-2.0, VERIFY |
| [Forgejo runner](https://code.forgejo.org/forgejo/runner) | CI runner role | VERIFY |
| [Semaphore UI](https://github.com/semaphoreui/semaphore) | Ansible run UI | VERIFY |
| [Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui) | Z-Wave controller UI | VERIFY |
| [Proxmox Backup Server](https://www.proxmox.com/en/products/proxmox-backup-server/overview) (community container image [`ayufan/proxmox-backup-server`](https://github.com/ayufan/pve-backup-server-dockerfiles)) | Backups of Proxmox guests | AGPL-3.0 upstream, VERIFY the image |
| [Garage Web UI](https://github.com/khairul169/garage-webui) | Admin UI for Garage | VERIFY |
| [Tecnativa docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) | Limits what containers may ask the Docker socket | VERIFY |
| [nginx](https://nginx.org), [nginx-unprivileged](https://github.com/nginx/docker-nginx-unprivileged) | Static front ends (Cmdr, sign-in) | VERIFY |
| [Python](https://www.python.org) (container image and the host's own) | Cmdr back end, inventory and helper scripts | VERIFY |
| [PyYAML](https://github.com/yaml/pyyaml) | YAML in the helper scripts | VERIFY |
| [Next.js](https://github.com/vercel/next.js), [next-auth](https://github.com/nextauthjs/next-auth), [React](https://github.com/facebook/react), [TypeScript](https://github.com/microsoft/TypeScript) (`console/`) | The optional console app | VERIFY |
| GitHub Actions [`checkout`](https://github.com/actions/checkout), [`cache`](https://github.com/actions/cache), [`setup-python`](https://github.com/actions/setup-python) | CI | VERIFY |
| [PowerShell 7](https://github.com/PowerShell/PowerShell) | Windows reconcile and roles (pinned release zip) | VERIFY |
| [Git for Windows (MinGit)](https://github.com/git-for-windows/git) | git on Windows hosts, from the pinned release zip | VERIFY |
| [powershell-yaml](https://github.com/cloudbase/powershell-yaml) (and the [YamlDotNet](https://github.com/aaubry/YamlDotNet) it bundles) | YAML in the Windows reconcile | VERIFY |
| [Sigsum](https://www.sigsum.org) (`sigsum-verify`) | Checks age's release proofs when its pin is bumped | VERIFY |

World map outlines in Cmdr come from [Natural Earth](https://www.naturalearthdata.com) (public domain), via the [`world-atlas`](https://github.com/topojson/world-atlas) package.

**Passed over:** Zerobyte for backups (Arkeep chosen, 2026-10-01); Watchtower-style blind image updates for stacks (pin or exclude instead); a hand-rolled restic timer (retired once Arkeep's agent took over).

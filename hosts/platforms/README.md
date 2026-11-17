# Platform profiles

One file per platform family, read by the `platform` role. The role detects the family from the host's Ansible facts (`ansible_os_family`), or takes it from
`platform_host` when Ansible runs inside a container and so sees the container instead of the machine (Unraid, Alpine with the container reconciler).

| Key | Meaning |
|---|---|
| `family` | The profile's name. |
| `tier` | `full` (Ansible runs on the host and changes it), `container` (a container drives the host's Docker socket) or `native` (the OS's own agent: launchd, a Scheduled Task). |
| `capabilities` | What a role can count on when the run changes the host itself. In a container run, only `docker` is offered. |
| `defaults` | Values a role may read as `platform_defaults.<name>` instead of hardcoding them (package manager, service names). |

Capabilities, kept deliberately few: `host` (the run changes the machine itself), `apt`, `apk`, `systemd`, `openrc`, `launchd`, `docker` (a Docker socket), `ufw`.

A role states what it needs in `hosts/roles/<role>/platform.yml`:

    requires: [host, apt, systemd]

See docs/decisions.md, entry 19.

# Platform profiles

One file per platform family, read by the `platform` role. In a host run the family comes from the host's Ansible facts (`ansible_facts['os_family']`). When Ansible runs inside a
container it sees the container, not the machine (Unraid, Alpine with the container reconciler), so there the family comes from `platform_host` or, failing that, the host table's `os:`.
In a host run the table's `os:` and `arch:` never override the facts: a disagreement is only reported in the log, so a wrong entry cannot make a host run another platform's roles.

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

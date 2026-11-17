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

    requires: [host, apt, systemd]              # capabilities
    requires_version: {apt: ">=2.4,<2.6.2"}     # versions of tools on the host: comma-separated <op><version>

### Versions

Platforms differ by release as well as by family (the apt retry vulnerability is in apt 2.4 and later but not in Debian 11's apt 2.2, and Ubuntu 24.04 is not Debian 12).
The `platform` role publishes `platform_version` (`name`, `full`, `major`, `release` of the distribution; empty in a container run unless the host table gives `os_version:`).
A profile can change itself by release with a `versions:` list; each entry has a `when` spec and may override `defaults`, add `capabilities_add` or drop `capabilities_remove`:

    versions:
      - when: ">=12"
        defaults: {ssh_service: ssh}
      - when: "<13"
        capabilities_remove: [some_capability]

Differences that follow a package's version, not the release, are read from the tool itself: a profile's `tools:` maps a name to a command that prints its version
(`apt: "dpkg-query -W -f='${Version}' apt"`), and a role or the planner asks for it (`tasks_from: tool_version`, or `requires_version`). It is read only when asked,
cached in `platform_tool_versions`, and empty in a container run, where the machine's tools are out of reach.

Versions are compared the Debian way (`platform_version_compare` and `platform_version_matches`, in `hosts/plugins/filter/`): Ansible's own `version` test does not
order `1.0~rc1`, epochs (`1:0.5`) or `2.6.1ubuntu1` correctly. Run the tests with `python3 -m unittest discover -s hosts/tests`.

See docs/decisions.md, entry 19.

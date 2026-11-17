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

Capabilities, kept deliberately few: `host` (the run changes the machine itself), `apt`, `apk`, `systemd`, `openrc`, `launchd`, `cron`, `docker` (a Docker socket), `ufw`, and the ones that say a platform has a primitive: `package`, `service`, `schedule`, `boot`.

A role states what it needs in `hosts/roles/<role>/platform.yml`:

    requires: [host, apt, systemd]              # capabilities
    requires_version: {apt: ">=2.4,<2.6.2"}     # versions of tools on the host: comma-separated <op><version>

### Package, repository and service tasks

Roles do not call `apt` or `systemctl` for the things every platform has; they ask the platform role (`include_role: {name: platform, tasks_from: ...}`):

| Task | Inputs | What it does |
|---|---|---|
| `package` | `platform_package` (a logical name, a plain package name, or a list), `platform_package_update` | Installs through apt, apk or the generic module. A logical name comes from the profile's `packages:` map (`docker` is `docker-ce`, `docker-ce-cli`, ... on Debian and `docker`, `docker-cli-compose` on Alpine); a name with no entry is used as it is. |
| `repo` | `platform_repo` (`host`, and `apt:` / `apk:` settings) | Makes a vendor's repository available: key and source file on apt (a source set up another way is used instead of adding a second one), the community repository on Alpine. Sets `platform_repo_changed`. |
| `service` | `platform_service` (a logical name or the service's own), `platform_service_enabled`, `platform_service_state` | Enables and starts it on systemd or OpenRC; the profile's `services:` map gives the platform's name (`tailscale` is `tailscaled` on Debian). |
| `schedule` | `platform_schedule` (`name`, `description`, `command`, `calendar`, `randomized_delay`, `persistent`, `after`, `service_options`, `header`) | Runs a command on a schedule: a systemd service and timer (the files the roles used to write, byte for byte), or a cron entry on a host without systemd. The calendar is a systemd calendar expression; the cron backend translates it (`platform_calendar_to_cron`) and refuses what cron cannot say (a year, seconds, a day of the month together with a weekday). A delay becomes a `sleep`; output goes to the system log. **Cron cannot catch up a run missed while the host was off** (`persistent` is systemd only). |
| `boot_task` | `platform_boot_task` (`name`, `description`, `commands`, `remain_after_exit`, `unit_lines`, `apply`, `header`) | Runs commands at every boot: a systemd oneshot unit, or a script in `/etc/local.d/` with OpenRC's `local` service. `apply: changed` also runs it now when its definition changed. |

What only one init system has (a systemd unit's drop-in, a timer, an OpenRC `conf.d` line) stays in a task guarded by that capability (`'systemd' in platform_capabilities`), so a role degrades
by capability instead of failing. The capabilities `package` and `service` say a platform has these primitives; a role that only needs them (docker, tailscale) declares `requires: [host, package, service]`.

The matrix in `ci/` runs the platform layer for real on Debian, Ubuntu and Alpine in containers (`ci/run-matrix.sh`; CI does the same). On Alpine it also initialises OpenRC and runs the service task,
the docker role's start order (asserted against OpenRC's own dependency tree) and the baseline role end to end, twice (`ci/openrc.yml`); only the kernel and the Docker daemon are left out.

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

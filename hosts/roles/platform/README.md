# platform

Works out what kind of machine a host is, once per run, and gives roles a small set of tasks that do the same job on every platform. The design is in
[hosts/platforms/README.md](../../platforms/README.md) and [docs/platforms.md](../../../docs/platforms.md); the choices are decisions 19 to 26.

- **Does:** detects the platform family, release, architecture, whether Ansible changes the machine or runs in a container, and what a role can count on (`platform_*` facts); and answers `package`, `repo`, `service`, `schedule`, `boot_task`, `artifact` and `tool_version` for roles to call.
- **Owns settings:** the profiles in `hosts/platforms/` (the fleet can point `platform_profiles_dir` at its own copy), and a host's `os:` and `arch:` in the host table. Each task's inputs are its `platform_*` variable (see below).
- **Keeps state:** nothing for detection. The tasks leave what a caller asked for: package installs, repository key and source files, units, cron entries, `local.d` scripts, and `/var/lib/platform-artifacts/<name>` (the installed version of a pinned download).
- **Rolls back by:** nothing to roll back for detection. Every task is idempotent; a download that fails its digest installs nothing, and the version marker is written only after the files are in place.
- **Exposes:** `platform_family`, `platform_tier`, `platform_arch`, `platform_runtime_mode`, `platform_version`, `platform_capabilities`, `platform_defaults`, `platform_tool_versions`; the filters `platform_version_compare`, `platform_version_matches`, `platform_version_matches_any`, `platform_calendar_to_cron` and `platform_delay_seconds` (`hosts/plugins/filter/`).

## Use

Include the role (the planner does this for every run) and read the facts, or call one task:

    - ansible.builtin.include_role: {name: platform, tasks_from: package}
      vars: {platform_package: docker}
    - ansible.builtin.include_role: {name: platform, tasks_from: schedule}
      vars:
        platform_schedule:
          name: fleet-example
          description: Example job
          command: /usr/local/sbin/fleet-example.sh
          calendar: "*-*-* 03:30:00"
          randomized_delay: 30min

| Task | Variable | Does |
|---|---|---|
| `package` | `platform_package` | Installs by logical or plain name (apt, apk or the generic module) |
| `repo` | `platform_repo` | Makes a vendor repository available (apt key and source; Alpine's community repository) |
| `service` | `platform_service` | Enables and starts a service on systemd or OpenRC |
| `schedule` | `platform_schedule` | A systemd timer, or a cron entry |
| `boot_task` | `platform_boot_task` | A systemd oneshot, or a `local.d` script |
| `artifact` | `platform_artifact` | A pinned, digest-checked release download |
| `tool_version` | `platform_tool` | Reads the installed version of a tool into `platform_tool_versions` |

A task passes its own explicit values to the tasks it calls, so a variable of the same name set elsewhere in the play does not change what it does.

## Test

`python3 -m unittest discover -s hosts/tests` (the version, schedule and route filters) and `ci/run-matrix.sh` (the layer on Debian, Ubuntu and Alpine in containers; Alpine also runs OpenRC, a cron job and a boot task for real).

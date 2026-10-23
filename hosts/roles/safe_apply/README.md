# safe_apply

Changes a running service's configuration so that the change can undo itself. A role that owns a config file for a long-running service includes this role instead of writing the file and restarting.

**What it guarantees:** if the new configuration does not leave the service healthy, the previous known-good files are put back, the service is restarted on them, the run **fails** (a rollback is never reported as success), the reason is written to the journal (`journalctl -t fleet-safe-apply`) and, when `fleet-notify` is installed, sent as an alert.

| Step | What happens |
|---|---|
| 1 | Is the service healthy *now*? Only a healthy state is worth keeping as known-good. |
| 2 | For each file that will change: the running one is kept as `<file>.last-good`, the one before as `<file>.last-good.prev`. |
| 3 | The new files are written (with the tool's own `validate` command when given: the file is not replaced if it fails), the service is restarted (systemd `reset-failed` first, so a unit that crash-looped can be restarted at all), and after `wait` seconds it is checked: running, **not restarted by itself since**, health URL or command ok. |
| 4 | Unhealthy: last-good files back, restart, check again, journal + notification, fail. |
| 5 | That content is remembered (`<file>.failed-rev`) and not applied again until it changes, so a bad revision does not restart the service every 20 minutes. |

Use it (the caller renders the content):

```yaml
- ansible.builtin.include_role:
    name: safe_apply
  vars:
    safe_apply_name: otelcol-contrib
    safe_apply_files:
      - {dest: /etc/otelcol-contrib/config.yaml, content: "{{ _rendered_config }}", mode: "0644", validate: "/usr/bin/otelcol-contrib validate --config=%s"}
    safe_apply_restart: {kind: systemd, name: otelcol-contrib, daemon_reload: true}
```

`kind` is `systemd` (`name`), `compose` (`project_src`, `name` of the container to inspect) or `command` (`command`, `restart_command`). Optional `safe_apply_health: {url, statuses, command, wait}`; `safe_apply_force: true` restarts and checks even when no file changed (a package upgrade); there is nothing to roll back then, and an unhealthy result still fails the run.

**What it does not do.** A first install has no known-good state to return to: a failure just fails, with the service's last log lines. A service that migrates its data when it starts must not be auto-rolled back: leave it out and record the decision. A rollback can reinstate an older configuration that a newer one replaced for a reason (a security fix): the failed attempt is reported, so someone decides.

**Tested** with Ansible: locally with a command-type service (first install, good change, bad change rolled back, same bad content refused, fix applied, no-op rerun), and on a real host with a throwaway systemd unit that crash-loops into systemd's start limit (rolled back, running again on the old files, failed content remembered). The compose kind is written the same way but has not been exercised against a real container yet.

Used by: `otel_agent`. The other roles that own service configuration (`traefik_server`, `apprise_server`, `muximux`, `loki_server`, `grafana_server`, `victoria_server`, `cmdr`) are to follow, one at a time.

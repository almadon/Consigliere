# fleet_plan

Runs what a host's tags select. Included from `hosts/site.yml`; a role does not call it.

- **Does:** runs the `platform` role; runs the base roles (`baseline`, `tailscale`, `sops`, `docker`: `fleet_plan_base_roles`); reads the tag manifests (`hosts/tags/` and the fleet's `config/tags/`) through the `fleet_roles` lookup and runs the roles and task files they name, in order; skips a role the host's platform cannot run (a missing capability or tool version in its `platform.yml`) with a message that says which; applies the firewall last.
- **Owns settings:** the manifests, which live in the framework and the fleet repo, not here. `fleet_plan_base_roles` can be overridden.
- **Keeps state:** none.
- **Rolls back by:** not applicable; the roles it runs own their rollback (`safe_apply` where they use it).
- **Exposes:** the plan (a debug line listing the platform, the tags and the roles that run) and `fleet_plan_missing`, the list of requirements a skipped role did not meet.

A role declares what it needs in `hosts/roles/<role>/platform.yml`:

    requires: [host, apt, systemd]            # capabilities (hosts/platforms/)
    requires_version: {apt: ">=2.4"}          # versions of tools on the host

A role with no `platform.yml` runs wherever a tag selects it. See [docs/platforms.md](../../../docs/platforms.md).

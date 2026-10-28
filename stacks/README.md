# stacks/

Docker Compose / Swarm stack definitions live here, one directory per
service. This tree is owned by **Arcane**, not Ansible - Arcane watches it
directly and handles sync, drift detection, and redeploys for both
standalone and swarm targets.

The `hosts/docker` role only installs and configures the Docker engine
itself; it does not touch anything under here.

## Layout convention

```
stacks/
  <service-name>/
    docker-compose.yml
    .env.example        # document required vars; real .env stays untracked
```

Scaffolded so far: [`console/`](console/) (this repo's own webUI), [`wazuh/`](wazuh/) and [`mailflow/`](mailflow/) (a webmail client for IMAP accounts,
behind Traefik, amd64 and arm64). Add a directory per service as they're containerized.

### Exception: vendored stacks

`wazuh/` doesn't follow the `docker-compose.yml`-at-the-top convention
above - it vendors the official `wazuh-docker` repo as a git submodule
and points Arcane at *its* compose file instead of copying one in. Do this
for any stack complex/actively-maintained enough that hand-transcribing it
risks drifting from upstream (multi-file configs, generated certs, that
kind of thing) - see [wazuh/README.md](wazuh/README.md) for the reasoning.
Plain single-file stacks should still follow the convention above.

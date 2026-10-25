# zwave_js_ui

[Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui) in Docker: the Z-Wave controller as a **server**. Home Assistant's Z-Wave integration connects to its websocket
(`ws://<this host>:3000`) instead of running Z-Wave JS inside Home Assistant, so a rebuilt or standby Home Assistant holds no Z-Wave state at all.

- **Owner of what:** the repo owns the container (image version, the stick's path, ports, memory). **You own the Z-Wave settings**, made in its web UI on port 8091 (serial port `/dev/zwave`,
  the S0/S2 keys, the websocket server) and kept in `<dir>/store`: that directory holds the network keys, so back it up (an Arkeep policy, or the PBS backup of the guest).
- **The stick:** `zwave_js_ui_device` must be the stable `/dev/serial/by-id/...` path. If it does not exist the run stops with instructions rather than letting Docker create a directory in its place and crash-loop.
- **Exposure:** both ports bind to the host's LAN address by default. The websocket server has no password; do not publish it, and put it on the VLAN Home Assistant uses. Switch authentication on in the UI for port 8091.
- **Applying a change** goes through [safe_apply](../safe_apply/README.md) (the compose path), so a bad change is rolled back to the previous compose file.
- **Not hardened further yet:** the container runs with `no-new-privileges` only; dropping capabilities or a read-only root should be tried against the real image before it is added.
- Moving from the official Home Assistant Z-Wave app: `runbooks/zwave-and-xenia.md` in the fleet repo.

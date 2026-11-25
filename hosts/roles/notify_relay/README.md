# notify_relay and notify_client

Fleet alerts through Home Assistant's [Supernotify](https://supernotify.rhizomatics.org.uk), with one host holding the Home Assistant token (decision 31).

- **Does:** `notify_client` installs `fleet-notify` on a host; it sends the alert to the relay. `notify_relay` runs the relay, which calls the `supernotify/notify` action.
- **Owns settings:** this repo and the fleet repo. Who gets what, and how, is configured in Supernotify.
- **Keeps state:** none. Alerts are not queued or retried.
- **Rolls back by:** `safe_apply` on the relay's code and compose file. The secrets file is not rolled back.
- **Exposes:** port 8087 on the relay host's tailnet address: `POST /notify` (needs the shared key) and `GET /healthz`.

**There is no second delivery path.** If Home Assistant or the relay is down, the alert is not delivered. `fleet-notify` then exits non-zero and says why. Watch Home Assistant from something outside it.

## Setting it up

1. In Home Assistant, make a **non-admin** user for this and create a long-lived access token for it. As far as we know a token cannot be limited to one action (**VERIFY**), so treat it as able to control things.
2. In the fleet repo, tag one host `util: [notify_relay]` and the hosts that should send alerts `feat: [notify]`. Remove `feat: [apprise]` from those hosts.
3. Set `notify_relay_ha_url` and `notify_relay_targets` in `config/vars/group/util_notify_relay.yml`, and `notify_client_url` in `config/vars/group/feat_notify.yml`.
4. Create two secrets: `notify.relay` with `notify_relay_ha_token`, and `notify.client` with `notify_client_key` (a long random value). Run `scripts/access.sh sync`.
5. After the hosts reconcile, test from one of them: `fleet-notify "test" "hello"; echo $?`.

`util: [notify]` is something else: the Apprise API server.

## What was tested

The relay and the rendered `fleet-notify` script, against a stand-in for Home Assistant (`hosts/tests/test_notify_relay.py`). **Not tested:** a real Home Assistant or Supernotify, the roles on a host, and whether Supernotify accepts these priorities and `force_resend` from this call (**VERIFY**; the payload follows one Novak's gateway uses). Unraid and other hosts without a package manager are not supported by `notify_client`.

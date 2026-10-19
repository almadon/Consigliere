#!/usr/bin/env bash
# Reports the outcome of a reconcile run through fleet-notify (the apprise role), when it is installed. Sourced by
# reconcile.sh; every function is best-effort and never changes the run's exit status.
#
#   FAILED run     -> a notification (tag alert) naming the failing task. The same failure is reported again only after
#                     RECONCILE_NOTIFY_REPEAT_SECS (default 6 hours).
#   run that fixes a reported failure -> "recovered" (tag info)
#   applied run that changed something -> the changed task names (tag info); RECONCILE_NOTIFY_CHANGES=0 turns this off
#
# Needs: RUN_LOG (the run's captured output), RECONCILE_MODE, and a state directory (RECONCILE_STATE_DIR, default WORKDIR).

_notify() {  # _notify <tag> <title> <body>
  FLEET_NOTIFY_TAG="$1" timeout 30 fleet-notify "$2" "$(printf '%s' "$3" | cut -c1-900)" >/dev/null 2>&1 || true
}

report_run() {  # report_run <exit status>
  local rc="$1" log="${RUN_LOG:-}" state="${RECONCILE_STATE_DIR:-${WORKDIR:-/tmp}}/notify-state"
  command -v fleet-notify >/dev/null 2>&1 || return 0
  local now sig prev_sig prev_ts detail changed names
  now="$(date +%s)"
  if [ "$rc" -ne 0 ]; then
    detail="$(
      { [ -f "$log" ] && awk '/^TASK \[/{t=$0} /fatal:|FAILED!/{print t; print $0; exit} /^ERROR/{e=$0} END{if(e!="")print e}' "$log"; } 2>/dev/null |
        sed 's/\x1b\[[0-9;]*m//g' | head -4
    )"
    [ -n "$detail" ] || detail="exit status $rc (see: journalctl -u fleet-reconcile)"
    sig="$(printf '%s' "$detail" | sha256sum | cut -c1-16)"
    prev_sig=""; prev_ts=0
    [ -f "$state" ] && read -r prev_sig prev_ts <"$state" 2>/dev/null || true
    if [ "$sig" = "$prev_sig" ] && [ $((now - ${prev_ts:-0})) -lt "${RECONCILE_NOTIFY_REPEAT_SECS:-21600}" ]; then
      return 0
    fi
    _notify alert "reconcile FAILED" "$detail"
    printf '%s %s\n' "$sig" "$now" >"$state" 2>/dev/null || true
    return 0
  fi
  if [ -f "$state" ]; then
    rm -f "$state"
    _notify info "reconcile recovered" "The last run succeeded."
  fi
  [ "${RECONCILE_NOTIFY_CHANGES:-1}" = 1 ] || return 0
  [ "${RECONCILE_MODE:-apply}" = apply ] || return 0
  [ -f "$log" ] || return 0
  changed="$(sed -n 's/.*changed=\([0-9][0-9]*\).*/\1/p' "$log" | tail -1)"
  if [ "${changed:-0}" -gt 0 ]; then
    names="$(awk '/^==> Applying/{f=1} f&&/^TASK \[/{t=$0} f&&/^changed: /{print t}' "$log" |
      sed 's/\x1b\[[0-9;]*m//g; s/^TASK \[//; s/\][ *]*$//' | sort -u | head -8 | paste -sd';' - | sed 's/;/; /g')"
    _notify info "reconcile applied $changed change(s)" "${names:-(see journalctl -u fleet-reconcile)}"
  fi
  return 0
}

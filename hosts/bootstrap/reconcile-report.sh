#!/usr/bin/env bash
# Reports the outcome of a reconcile run: as a syslog line when RECONCILE_SYSLOG is set (hosts with no journal, i.e. Unraid), and through fleet-notify (the apprise role), when it is installed. Sourced by
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

# Where to send the run summary as syslog (host:port, TCP), for hosts with no journal for the log collector to read (Unraid): RECONCILE_SYSLOG in the environment, or
# a line RECONCILE_SYSLOG=10.0.1.3:1514 in the host's reconcile.env (re-read at every run, so changing it needs no container restart). Empty = nothing is sent.
_syslog_target() {
  local t="${RECONCILE_SYSLOG:-}" f
  if [ -z "$t" ]; then
    for f in "${CRED_DIR:+$(dirname "$CRED_DIR")/reconcile.env}" /etc/fleet-reconcile/reconcile.env; do
      [ -n "$f" ] && [ -r "$f" ] || continue
      t="$(sed -n 's/^RECONCILE_SYSLOG=//p' "$f" | tail -1 | tr -d "\"'")"
      [ -n "$t" ] && break
    done
  fi
  printf '%s' "$t"
}

# The run's "PLAY RECAP" line as one RFC 3164 syslog message, program fleet-reconcile, host name = this host's own (--uts host gives the Unraid container the server's name):
# in Loki it is {host_name="spire", unit="fleet-reconcile"}, which is what cmdr's reconcile status reads. A run that died before any recap is sent as failed=1.
syslog_recap() {  # syslog_recap <exit status>
  local rc="$1" log="${RUN_LOG:-}" t host line sev
  [ "${RECONCILE_MODE:-apply}" = check ] && return 0
  t="$(_syslog_target)"; [ -n "$t" ] || return 0
  host="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"; [ -n "$host" ] || return 0
  line=""
  [ -f "$log" ] && line="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'ok=[0-9]+ +changed=[0-9]+ +unreachable=[0-9]+ +failed=[0-9]+' | tail -1)"
  sev=14
  if [ "$rc" -ne 0 ]; then
    sev=11
    [ -n "$line" ] || line="$host : ok=0 changed=0 unreachable=0 failed=1 (no recap, exit status $rc)"
  fi
  [ -n "$line" ] || return 0
  local sh_timeout=(); command -v timeout >/dev/null 2>&1 && sh_timeout=(timeout 8)
  "${sh_timeout[@]}" bash -c 'exec 3<>"/dev/tcp/$0/$1" && printf "%s\n" "$2" >&3' "${t%:*}" "${t##*:}" \
    "<$sev>$(date '+%b %e %H:%M:%S') $host fleet-reconcile: $line" >/dev/null 2>&1 || true
}

report_run() {  # report_run <exit status>
  local rc="$1" log="${RUN_LOG:-}" state="${RECONCILE_STATE_DIR:-${WORKDIR:-/tmp}}/notify-state"
  syslog_recap "$rc" || true
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

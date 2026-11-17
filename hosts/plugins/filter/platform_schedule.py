"""Schedules for the platform layer (hosts/platforms/README.md): the fleet writes them as systemd calendar expressions; a host without systemd runs them from cron.

  platform_calendar_to_cron(spec)  -> {"minute", "hour", "day", "month", "weekday"} as cron fields
  platform_delay_seconds(text)     -> int; "30min", "1h", "2h30min", "90s", "45" (seconds) as systemd writes a RandomizedDelaySec

Supported calendar forms (what the fleet uses, plus the usual neighbours):
  minutely hourly daily weekly monthly quarterly semiannually yearly
  [weekdays] [date] [time]      Sun *-*-* 04:00:00     *-*-* 03:30:00     Mon..Fri 05:00     *-*-15 02:00     *:0/15
    weekdays: Mon, Mon,Thu, Mon..Fri (names in any case, 3 letters or full)
    date:     Y-M-D, each part * or a number, list, range or */N; the year must be * (cron has none)
    time:     H:M[:S], each part * or a number, list, range, */N or N/N; the seconds must be 0 (cron has minutes)
A calendar cron cannot express exactly is an error, not a guess: a restricted day of month together with a restricted weekday (cron ORs them, systemd ANDs them),
a specific year, non-zero seconds.
"""
import re

_DAYS = {"mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6, "sun": 0}
_KEYWORDS = {
    "minutely": ("*", "*", "*", "*", "*"),
    "hourly": ("0", "*", "*", "*", "*"),
    "daily": ("0", "0", "*", "*", "*"),
    "weekly": ("0", "0", "*", "*", "1"),
    "monthly": ("0", "0", "1", "*", "*"),
    "quarterly": ("0", "0", "1", "1,4,7,10", "*"),
    "semiannually": ("0", "0", "1", "1,7", "*"),
    "yearly": ("0", "0", "1", "1", "*"),
    "annually": ("0", "0", "1", "1", "*"),
}
_RANGES = {"minute": (0, 59), "hour": (0, 23), "day": (1, 31), "month": (1, 12)}


def _day_num(name):
    d = name.strip().lower()[:3]
    if d not in _DAYS:
        raise ValueError("unknown weekday %r" % name)
    return _DAYS[d]


def _weekdays(text):
    out = []
    for part in text.split(","):
        part = part.strip()
        if ".." in part:
            a, b = (_day_num(x) for x in part.split(".."))
            order = [1, 2, 3, 4, 5, 6, 0]
            ia, ib = order.index(a), order.index(b)
            if ia > ib:
                raise ValueError("weekday range %r runs backwards" % part)
            out += order[ia:ib + 1]
        else:
            out.append(_day_num(part))
    return ",".join(str(n) for n in sorted(set(out)))


def _field(text, kind):
    """One systemd field (minute, hour, day, month) as a cron field."""
    lo, hi = _RANGES[kind]
    if text == "*":
        return "*"
    parts = []
    for part in text.split(","):
        m = re.fullmatch(r"\*/(\d+)", part)
        if m:
            parts.append("*/" + m.group(1))
            continue
        m = re.fullmatch(r"(\d+)/(\d+)", part)                 # systemd: start/step
        if m:
            parts.append("%d-%d/%d" % (int(m.group(1)), hi, int(m.group(2))))
            continue
        m = re.fullmatch(r"(\d+)\.\.(\d+)", part)
        if m:
            parts.append("%d-%d" % tuple(int(x) for x in m.groups()))
            continue
        if re.fullmatch(r"\d+", part):
            parts.append(str(int(part)))
            continue
        raise ValueError("cannot translate %s %r" % (kind, text))
    for p in parts:
        for n in re.findall(r"\d+", p.split("/")[0]):
            if not lo <= int(n) <= hi:
                raise ValueError("%s %s is outside %d..%d" % (kind, n, lo, hi))
    return ",".join(parts)


def platform_calendar_to_cron(spec):
    s = str(spec).strip()
    if s.lower() in _KEYWORDS:
        mi, ho, da, mo, wd = _KEYWORDS[s.lower()]
        return {"minute": mi, "hour": ho, "day": da, "month": mo, "weekday": wd}
    tokens = s.split()
    if not tokens:
        raise ValueError("empty calendar")
    weekday, date, time = "*", "*-*-*", None
    for tok in tokens:
        if re.fullmatch(r"[A-Za-z][A-Za-z.,]*", tok):
            weekday = _weekdays(tok)
        elif re.fullmatch(r"[\d*]+-[\d*]+-[\d*,./]+|[\d*/,.]+-[\d*/,.]+-[\d*/,.]+", tok):
            date = tok
        elif ":" in tok:
            time = tok
        else:
            raise ValueError("cannot read %r in the calendar %r" % (tok, s))
    if time is None:
        time = "00:00:00"
    y, mo, da = date.split("-")
    if y != "*":
        raise ValueError("cron has no year: %r" % s)
    t = time.split(":")
    if len(t) == 2:
        t.append("0")
    if len(t) != 3:
        raise ValueError("cannot read the time %r" % time)
    h, mi, se = t
    if se not in ("0", "00"):
        raise ValueError("cron has minutes, not seconds: %r" % s)
    day = _field(da, "day")
    if day != "*" and weekday != "*":
        raise ValueError("a day of the month together with a weekday means 'both' in systemd and 'either' in cron: %r" % s)
    return {"minute": _field(mi, "minute"), "hour": _field(h, "hour"), "day": day, "month": _field(mo, "month"), "weekday": weekday}


def platform_delay_seconds(text):
    s = str(text).strip().lower()
    if re.fullmatch(r"\d+", s):
        return int(s)
    units = {"us": 1e-6, "ms": 1e-3, "s": 1, "sec": 1, "second": 1, "seconds": 1, "m": 60, "min": 60, "minute": 60, "minutes": 60, "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600, "d": 86400, "day": 86400, "days": 86400}
    total, pos = 0.0, 0
    for m in re.finditer(r"\s*(\d+)\s*([a-z]+)\s*", s):
        if m.start() != pos or m.group(2) not in units:
            raise ValueError("cannot read the duration %r" % text)
        total += int(m.group(1)) * units[m.group(2)]
        pos = m.end()
    if pos != len(s) or pos == 0:
        raise ValueError("cannot read the duration %r" % text)
    return int(total)


class FilterModule(object):
    def filters(self):
        return {"platform_calendar_to_cron": platform_calendar_to_cron, "platform_delay_seconds": platform_delay_seconds}

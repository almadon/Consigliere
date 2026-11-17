"""Version comparison for the platform layer (hosts/platforms/README.md).

Ansible's own `version` test does not order Debian versions correctly: it knows nothing of `~` (1.0~rc1 sorts before 1.0), epochs (1:0.5 is newer than 2.0)
or suffixes such as 2.6.1ubuntu1. This implements the ordering of Debian Policy 5.6.12, which is also what dpkg uses. The same rules give the right answer for
plain dotted versions (2.10 is newer than 2.6) and are close enough for Alpine's (3.20.3-r0, with -r0 as the revision) and systemd's.

Filters:
  platform_version_compare(a, b)    -> -1, 0 or 1
  platform_version_matches_any(v, specs) -> bool; true when the version matches at least one spec of the list (for example a list of vulnerable ranges)
  platform_version_matches(v, spec) -> bool; spec is comma-separated clauses of <op><version>, op one of >= <= > < == = !=
                                       e.g. ">=2.4.0,<2.4.15"; an empty or missing version matches nothing
"""
import re

_CLAUSE = re.compile(r"^\s*(>=|<=|==|!=|>|<|=)\s*([0-9A-Za-z][^\s,<>=!]*)\s*$")


def _order(c):
    if c == "":
        return 0
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _compare_part(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i]) if i < len(a) else 0
            bc = _order(b[j]) if j < len(b) else 0
            if ac != bc:
                return -1 if ac < bc else 1
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and j < len(b) and a[i].isdigit() and b[j].isdigit():
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first_diff:
            return -1 if first_diff < 0 else 1
    return 0


def _split(version):
    v = str(version).strip()
    epoch = 0
    if ":" in v:
        e, v = v.split(":", 1)
        epoch = int(e) if e.isdigit() else 0
    revision = ""
    if "-" in v:
        v, revision = v.rsplit("-", 1)
    return epoch, v, revision


def platform_version_compare(a, b):
    ea, ua, ra = _split(a)
    eb, ub, rb = _split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    for x, y in ((ua, ub), (ra, rb)):
        c = _compare_part(x, y)
        if c:
            return c
    return 0


def platform_version_matches(version, spec):
    if version is None or str(version).strip() == "":
        return False
    clauses = [c for c in str(spec).split(",") if c.strip()]
    if not clauses:
        raise ValueError("empty version spec")
    for clause in clauses:
        m = _CLAUSE.match(clause)
        if not m:
            raise ValueError("bad version clause %r in %r (want e.g. '>=2.4.0')" % (clause, spec))
        op, want = m.groups()
        c = platform_version_compare(version, want)
        ok = {">=": c >= 0, "<=": c <= 0, ">": c > 0, "<": c < 0, "==": c == 0, "=": c == 0, "!=": c != 0}[op]
        if not ok:
            return False
    return True


def platform_version_matches_any(version, specs):
    return any(platform_version_matches(version, s) for s in (specs or []))


class FilterModule(object):
    def filters(self):
        return {"platform_version_compare": platform_version_compare, "platform_version_matches": platform_version_matches,
                "platform_version_matches_any": platform_version_matches_any}

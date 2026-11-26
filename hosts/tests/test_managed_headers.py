"""Every file the framework writes onto a host must say at the top that it is managed, so nobody edits it there and loses the edit.

This reads the role and platform task files, follows each template, copy and safe_apply entry to its content, and looks for the marker in the first lines.
A file that cannot or must not carry it goes in EXCEPTIONS with the reason. It does not cover lineinfile/replace edits (the file belongs to the system),
files written by shell or PowerShell scripts, or the macOS and Windows roles' non-Ansible parts.
"""
import glob
import os
import re
import unittest

try:
    import yaml
except ImportError:  # the same condition the route tests have
    yaml = None

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MARK = re.compile(r"managed by (ansible|consigliere)|ansible_managed", re.I)
HEAD_LINES = 12

# destination (as written in the task) -> why it has no marker
EXCEPTIONS = {
    "{{ restic_server_dir }}/htpasswd": "a credential file with its own parser; a comment line has not been shown to be safe",
    "/etc/fleet-exposure-watch.key": "the whole content is the key",
    "{{ muximux_dir }}/data/config.yaml": "merged into a file the app rewrites, and the UI owns much of it: a 'managed' header would be wrong",
    "{{ muximux_dir }}/managed.json": "the role's own record of what it set",
    "{{ grafana_server_dir }}/dashboards/{{ item.name }}.json": "a dashboard definition; an unknown key has not been shown to be safe",
    "/var/lib/platform-artifacts/{{ platform_artifact.name }}": "the installed version number, read back as the whole file",
    "{{ item.dest }}": "safe_apply and platform_artifact write what their caller gives them; the callers are checked",
    "{{ item.dest }}.failed-rev": "safe_apply's record of a content hash",
}
WRITERS = ("template", "copy", "blockinfile")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def entries():
    """(task file, destination, content or None when it comes from outside the repo)"""
    task_files = sorted(glob.glob(os.path.join(ROOT, "hosts", "roles", "*", "tasks", "*.yml")) +
                        glob.glob(os.path.join(ROOT, "hosts", "roles", "*", "handlers", "*.yml")))
    for path in task_files:
        role = os.path.dirname(os.path.dirname(path))
        role_tasks = "".join(read(p) for p in glob.glob(os.path.join(role, "tasks", "*.yml")))
        yield from walk(yaml.safe_load(read(path)), path, role, role_tasks)


def walk(tasks, path, role, role_tasks):
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        for key in ("block", "rescue", "always"):
            yield from walk(task.get(key), path, role, role_tasks)
        for key, args in task.items():
            module = key.split(".")[-1]
            if module in WRITERS and isinstance(args, dict) and "dest" in args:
                if args.get("remote_src"):
                    continue  # a copy of a file already on the host: a backup, or the fleet's own content
                for dest, content in expand(task, args, role, role_tasks):
                    yield path, dest, content
        include = task.get("ansible.builtin.include_role") or task.get("include_role") or {}
        files = (task.get("vars") or {}).get("safe_apply_files")
        if include.get("name") == "safe_apply" and isinstance(files, list):
            for item in files:
                yield path, item["dest"], text_of(str(item["content"]), role, role_tasks)


def expand(task, args, role, role_tasks):
    """One entry per file: a task that loops over names is expanded when the loop is written out in the task."""
    loop = task.get("loop")
    if "{{ item" in str(args.get("src", "")) and isinstance(loop, list):
        for item in loop:
            src, dest = str(args["src"]), str(args["dest"])
            values = item if isinstance(item, dict) else {None: item}
            for k, v in values.items():
                token = "{{ item }}" if k is None else "{{ item.%s }}" % k
                src, dest = src.replace(token, str(v)), dest.replace(token, str(v))
            yield dest, file_text(role, src)
    elif "content" in args:
        yield str(args["dest"]), text_of(str(args["content"]), role, role_tasks)
    else:
        yield str(args["dest"]), file_text(role, str(args.get("src", "")))


def text_of(content, role, role_tasks):
    """Inline content, plus the template it comes from, directly or through a variable set with a template lookup."""
    for name in re.findall(r"\{\{\s*(_[a-z0-9_]+)\s*\}\}", content):
        found = re.search(name + r""":\s*["']\{\{\s*lookup\('(?:ansible\.builtin\.)?(?:template|file)',\s*'([^']+)'""", role_tasks)
        if found:
            content = (file_text(role, found.group(1)) or "") + content
    for ref in re.findall(r"lookup\('(?:ansible\.builtin\.)?(?:template|file)',\s*'([^']+)'", content):
        content = (file_text(role, ref) or "") + content
    return content


def file_text(role, name):
    for sub in ("templates", "files", ""):
        path = os.path.join(role, sub, name)
        if name and os.path.isfile(path):
            return read(path)
    return None


@unittest.skipUnless(yaml, "needs PyYAML")
class ManagedHeaders(unittest.TestCase):
    def test_every_written_file_says_it_is_managed(self):
        missing, unresolved, seen = [], [], 0
        for path, dest, content in entries():
            if dest in EXCEPTIONS:
                continue
            where = f"{os.path.relpath(path, ROOT)}: {dest}"
            if content is None:
                unresolved.append(where)
                continue
            seen += 1
            if not MARK.search("\n".join(content.splitlines()[:HEAD_LINES])):
                missing.append(where)
        self.assertGreater(seen, 60, "the scan found suspiciously few files")
        self.assertEqual((sorted(set(missing)), sorted(set(unresolved))), ([], []),
                         "\nFirst list: no 'Managed by Ansible' line near the top. Second: the source could not be followed.\n"
                         "Add the header, or an entry in EXCEPTIONS with the reason.")

    def test_exceptions_still_exist(self):
        dests = {dest for _, dest, _ in entries()}
        self.assertEqual(sorted(set(EXCEPTIONS) - dests), [], "remove exceptions that no task uses any more")


if __name__ == "__main__":
    unittest.main()

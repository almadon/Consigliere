"""Run: python3 -m unittest discover -s hosts/tests   (from the repository root; needs PyYAML)"""
import importlib.util
import os
import tempfile
import unittest

import yaml

_p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "lookup", "fleet_routes.py")
_spec = importlib.util.spec_from_file_location("fleet_routes", _p)
fr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fr)


def make(files):
    d = tempfile.mkdtemp()
    for name, text in files.items():
        with open(os.path.join(d, name), "w") as fh:
            fh.write(text)
    return d


A64 = """
cert: a64.one
via: constant
routes:
  - {name: mail, host: mail.a64.one, backend: "http://mailflow-frontend:80", profile: relaxed}
  - {name: arc, host: arc.ctrl.a64.one, backend: "http://arcane:3552", via: [constant, Liaison], internal: true}
  - {name: ds, host: ds.ctrl.a64.one, backend: "http://homarr-gate:8080", via: ampere}
"""
RMRG = """
via: nova
routes:
  - {name: rosie, host: rosie.casa, backend: "http://rosie:80"}
"""


class Load(unittest.TestCase):
    def zones(self, files):
        return fr.load_zones([make(files)], yaml.safe_load)

    def test_file_default_and_route_override(self):
        zones, problems = self.zones({"a64.one.yml": A64, "rmrg.casa.yml": RMRG})
        self.assertEqual(problems, [])
        mine, more = fr.routes_for_host(zones, "constant")
        self.assertEqual(more, [])
        self.assertEqual([z["name"] for z in mine], ["a64.one"])
        self.assertEqual([r["name"] for r in mine[0]["routes"]], ["mail", "arc"])       # ds is ampere's
        self.assertEqual(mine[0]["cert"], "a64.one")

    def test_via_list_and_case(self):
        zones, _ = self.zones({"a64.one.yml": A64})
        self.assertIn("arc", [r["name"] for z in fr.routes_for_host(zones, "liaison")[0] for r in z["routes"]])
        self.assertIn("arc", [r["name"] for z in fr.routes_for_host(zones, "LIAISON")[0] for r in z["routes"]])

    def test_via_is_stripped_and_other_keys_kept(self):
        zones, _ = self.zones({"a64.one.yml": A64})
        arc = [r for r in fr.routes_for_host(zones, "constant")[0][0]["routes"] if r["name"] == "arc"][0]
        self.assertNotIn("via", arc)
        self.assertTrue(arc["internal"])
        self.assertEqual(arc["backend"], "http://arcane:3552")

    def test_host_with_no_routes_gets_nothing(self):
        zones, _ = self.zones({"a64.one.yml": A64})
        self.assertEqual(fr.routes_for_host(zones, "svault")[0], [])

    def test_zones_in_name_order_each_with_only_its_hosts_routes(self):
        both = "via: [constant, nova]\nroutes:\n  - {name: x, host: x.meuse.one, backend: 'http://x'}\n"
        zones, _ = self.zones({"rmrg.casa.yml": RMRG.replace("nova", "constant"), "a64.one.yml": A64, "meuse.one.yml": both})
        mine, _ = fr.routes_for_host(zones, "constant")
        self.assertEqual([z["name"] for z in mine], ["a64.one", "meuse.one", "rmrg.casa"])

    def test_missing_dir_is_skipped(self):
        zones, problems = fr.load_zones(["/no/such/dir", ""], yaml.safe_load)
        self.assertEqual((zones, problems), ([], []))


class Problems(unittest.TestCase):
    def problems(self, text, name="z.yml"):
        return fr.load_zones([make({name: text})], yaml.safe_load)[1]

    def test_route_without_via(self):
        p = self.problems("routes:\n  - {name: a, host: a.x, backend: 'http://a'}\n")
        self.assertTrue(any("no `via`" in x for x in p), p)

    def test_bad_names_and_shapes(self):
        self.assertTrue(self.problems("via: h\nroutes:\n  - {name: Bad_Name, host: a.x, backend: b}\n"))
        self.assertTrue(self.problems("via: h\nroutes:\n  - not-a-mapping\n"))
        self.assertTrue(self.problems("routes: nope\n"))
        self.assertTrue(self.problems("- just\n- a list\n"))
        self.assertTrue(self.problems("via: h\nroutes:\n  - {name: a, backend: b}\n"))      # neither host nor rule

    def test_unknown_file_key_is_an_error(self):
        p = self.problems("via: h\nvia_typo: x\nroutes: []\n")
        self.assertTrue(any("unknown key" in x for x in p), p)

    def test_invalid_yaml(self):
        self.assertTrue(any("not valid YAML" in x for x in self.problems("routes: [\n")))

    def test_same_name_twice_on_one_host_is_an_error(self):
        zones, _ = fr.load_zones([make({"a.yml": "via: h\nroutes:\n  - {name: dup, host: a.x, backend: b}\n",
                                        "b.yml": "via: h\nroutes:\n  - {name: dup, host: b.x, backend: b}\n"})], yaml.safe_load)
        _, more = fr.routes_for_host(zones, "h")
        self.assertTrue(any("dup" in x for x in more), more)
        # but the same name on two different hosts is fine
        self.assertEqual(fr.routes_for_host(zones, "other")[1], [])


if __name__ == "__main__":
    unittest.main()

"""Run: python3 -m unittest discover -s hosts/tests   (from the repository root)"""
import importlib.util
import os
import unittest

_p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "filter", "platform_version.py")
_spec = importlib.util.spec_from_file_location("platform_version", _p)
pv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pv)


class Compare(unittest.TestCase):
    def test_orderings_dpkg_agrees_on(self):
        # (smaller, larger): each pair is what `dpkg --compare-versions a lt b` answers true for
        pairs = [
            ("1.0", "1.1"), ("1.0~rc1", "1.0"), ("1.0~~", "1.0~"), ("1.0~", "1.0"), ("1.0", "1.0a"), ("1.0", "1.0+dfsg"),
            ("1.0-1", "1.0-2"), ("2.0", "1:0.5"), ("2.6.2", "2.6.10"), ("2.6.1", "2.6.1ubuntu1"), ("2.6.1ubuntu1", "2.6.2"),
            ("2.4.14+deb12u1", "2.4.15"), ("2.4.15~rc1", "2.4.15"), ("2.4.15", "2.4.15+deb12u1"), ("1.0-1", "1.0-1+b1"),
            ("2.8.3", "3.0.0"), ("3.20.3-r0", "3.20.3-r1"), ("1:1.0", "2:0.1"), ("0.9", "1.0"), ("1.9", "1.10"),
        ]
        for small, large in pairs:
            self.assertEqual(pv.platform_version_compare(small, large), -1, "%s should sort before %s" % (small, large))
            self.assertEqual(pv.platform_version_compare(large, small), 1, "%s should sort after %s" % (large, small))

    def test_equal(self):
        for a, b in [("1.0", "1.0"), ("1.00", "1.0"), ("2.6.2-0", "2.6.2"), ("0:1.0", "1.0")]:
            self.assertEqual(pv.platform_version_compare(a, b), 0, "%s == %s" % (a, b))


class Matches(unittest.TestCase):
    def test_ranges(self):
        m = pv.platform_version_matches
        self.assertTrue(m("2.6.1", ">=2.4,<2.6.2"))
        self.assertFalse(m("2.6.2", ">=2.4,<2.6.2"))
        self.assertTrue(m("2.4.14+deb12u1", "<2.4.15"))
        self.assertFalse(m("2.4.15", "<2.4.15"))
        self.assertTrue(m("12", ">=12"))
        self.assertFalse(m("11", ">=12"))
        self.assertTrue(m("24.04", ">=22.04,<26"))
        self.assertTrue(m("3.0.4", "==3.0.4"))
        self.assertTrue(m("3.0.5", "!=3.0.4"))

    def test_any(self):
        ranges = [">=2.4,<2.4.15", ">=2.5,<2.6.2", ">=2.7,<2.8.4", ">=2.9,<3.0.4"]
        any_ = pv.platform_version_matches_any
        self.assertTrue(any_("2.4.14+deb12u1", ranges))
        self.assertFalse(any_("2.4.15", ranges))
        self.assertTrue(any_("2.6.1", ranges))      # Debian 12 as released
        self.assertFalse(any_("2.2.4", ranges))     # Debian 11: below every range
        self.assertTrue(any_("3.0.3", ranges))
        self.assertFalse(any_("3.0.4", ranges))
        self.assertFalse(any_("", ranges))          # unknown version: not treated as vulnerable
        self.assertFalse(any_("2.6.1", []))

    def test_missing_version_matches_nothing(self):
        for v in (None, "", "   "):
            self.assertFalse(pv.platform_version_matches(v, ">=1"))
            self.assertFalse(pv.platform_version_matches(v, "<1"))

    def test_bad_spec_is_an_error_not_a_silent_false(self):
        for spec in ("", "2.4", ">>2", "~=2.4"):
            with self.assertRaises(ValueError):
                pv.platform_version_matches("2.4.1", spec)


if __name__ == "__main__":
    unittest.main()

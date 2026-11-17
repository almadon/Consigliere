"""Run: python3 -m unittest discover -s hosts/tests   (from the repository root)"""
import importlib.util
import os
import unittest

_p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "filter", "platform_schedule.py")
_spec = importlib.util.spec_from_file_location("platform_schedule", _p)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)


def cron(spec):
    c = ps.platform_calendar_to_cron(spec)
    return " ".join(c[k] for k in ("minute", "hour", "day", "month", "weekday"))


class Calendar(unittest.TestCase):
    def test_what_the_fleet_uses(self):
        self.assertEqual(cron("Sun *-*-* 04:00:00"), "0 4 * * 0")
        self.assertEqual(cron("*-*-* 03:30:00"), "30 3 * * *")
        self.assertEqual(cron("*-*-* 04:10:00"), "10 4 * * *")
        self.assertEqual(cron("sat 03:30"), "30 3 * * 6")

    def test_keywords(self):
        self.assertEqual(cron("daily"), "0 0 * * *")
        self.assertEqual(cron("hourly"), "0 * * * *")
        self.assertEqual(cron("weekly"), "0 0 * * 1")
        self.assertEqual(cron("monthly"), "0 0 1 * *")
        self.assertEqual(cron("Daily"), "0 0 * * *")

    def test_weekdays(self):
        self.assertEqual(cron("Mon,Thu 04:00"), "0 4 * * 1,4")
        self.assertEqual(cron("Mon..Fri 05:00"), "0 5 * * 1,2,3,4,5")
        self.assertEqual(cron("Sunday 01:00"), "0 1 * * 0")
        self.assertEqual(cron("Sat,Sun 01:00"), "0 1 * * 0,6")

    def test_time_and_date_parts(self):
        self.assertEqual(cron("*:0/15"), "0-59/15 * * * *")
        self.assertEqual(cron("*:00"), "0 * * * *")
        self.assertEqual(cron("*-*-* 03,15:00"), "0 3,15 * * *")
        self.assertEqual(cron("*-*-* */6:00"), "0 */6 * * *")
        self.assertEqual(cron("*-*-15 02:00"), "0 2 15 * *")
        self.assertEqual(cron("*-01-01 00:00"), "0 0 1 1 *")
        self.assertEqual(cron("*-*-* 02:05..10"), "5-10 2 * * *")

    def test_refuses_what_cron_cannot_say(self):
        for spec in ("2026-*-* 03:00", "*-*-* 03:00:30", "Mon *-*-15 03:00", "never", "*-*-* 25:00", "Fri..Mon 03:00", "", "*-*-* 03:xx"):
            with self.assertRaises(ValueError, msg=spec):
                ps.platform_calendar_to_cron(spec)


class Delay(unittest.TestCase):
    def test_durations(self):
        self.assertEqual(ps.platform_delay_seconds("30min"), 1800)
        self.assertEqual(ps.platform_delay_seconds("15min"), 900)
        self.assertEqual(ps.platform_delay_seconds("1h"), 3600)
        self.assertEqual(ps.platform_delay_seconds("2h 30min"), 9000)
        self.assertEqual(ps.platform_delay_seconds("2h30min"), 9000)
        self.assertEqual(ps.platform_delay_seconds("90s"), 90)
        self.assertEqual(ps.platform_delay_seconds("45"), 45)
        self.assertEqual(ps.platform_delay_seconds("0"), 0)

    def test_bad(self):
        for t in ("", "soon", "5 parsecs", "min"):
            with self.assertRaises(ValueError, msg=t):
                ps.platform_delay_seconds(t)


if __name__ == "__main__":
    unittest.main()

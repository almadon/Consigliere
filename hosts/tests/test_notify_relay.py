"""The notification relay and the fleet-notify client, end to end against a stand-in for Home Assistant. Standard library only."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "roles", "notify_relay", "files"))
import relay  # noqa: E402

KEY = "k" * 32
CLIENT = os.path.join(HERE, "..", "roles", "notify_client", "templates", "fleet-notify.j2")


def serve(handler):
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


class FakeHomeAssistant(BaseHTTPRequestHandler):
    status, calls = 200, []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        FakeHomeAssistant.calls.append((self.path, self.headers.get("Authorization"), json.loads(body)))
        self.send_response(FakeHomeAssistant.status)
        self.send_header("Content-Length", "0")
        self.end_headers()


class RelayTest(unittest.TestCase):
    def setUp(self):
        FakeHomeAssistant.status, FakeHomeAssistant.calls = 200, []
        self.ha, ha_url = serve(FakeHomeAssistant)
        self.settings = relay.settings({"RELAY_HA_URL": ha_url, "RELAY_HA_TOKEN": "secret-token", "RELAY_KEY": KEY, "RELAY_TARGETS": '["person.alex"]'})
        self.relay, self.url = serve(relay.handler(self.settings))
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        for srv in (self.relay, self.ha):
            srv.shutdown()
            srv.server_close()
        shutil.rmtree(self.tmp)

    def notify(self, *args, key=KEY, endpoint=None, tag=None):
        script = os.path.join(self.tmp, "fleet-notify")
        with open(CLIENT) as src, open(script, "w") as out:
            out.write(src.read().replace("{{ inventory_hostname }}", "host1").replace("{{ notify_client_title_prefix }}", "host1"))
        cfg = os.path.join(self.tmp, "cfg.json")
        with open(cfg, "w") as f:
            json.dump({"endpoint": endpoint or self.url, "key": key}, f)
        env = dict(os.environ, FLEET_NOTIFY_CONFIG=cfg)
        env.pop("FLEET_NOTIFY_TAG", None)
        if tag:
            env["FLEET_NOTIFY_TAG"] = tag
        return subprocess.run(["bash", script, *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)

    @unittest.skipUnless(shutil.which("curl"), "needs curl")
    def test_alert_reaches_home_assistant(self):
        r = self.notify("disk full", 'volume "a" & b=c\nsecond line')
        self.assertEqual(r.returncode, 0, r.stderr)
        path, auth, data = FakeHomeAssistant.calls[0]
        self.assertEqual((path, auth), ("/api/services/supernotify/notify", "Bearer secret-token"))
        self.assertEqual(data, {"title": "[host1] disk full", "message": 'volume "a" & b=c\nsecond line', "target": ["person.alex"],
                                "priority": "high", "force_resend": True})

    @unittest.skipUnless(shutil.which("curl"), "needs curl")
    def test_tags_set_priority_and_unknown_is_loud(self):
        self.notify("a", "b", tag="info")
        self.notify("a", "b", tag="something-new")
        self.assertEqual([c[2]["priority"] for c in FakeHomeAssistant.calls], ["low", "high"])

    @unittest.skipUnless(shutil.which("curl"), "needs curl")
    def test_failures_are_visible_to_the_caller(self):
        FakeHomeAssistant.status = 401
        refused = self.notify("a", "b")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("refused the call (HTTP 401)", refused.stderr)
        self.assertNotIn("secret-token", refused.stderr)
        self.ha.shutdown()
        self.ha.server_close()
        down = self.notify("a", "b")
        self.assertNotEqual(down.returncode, 0)
        self.assertIn("could not be reached", down.stderr)

    @unittest.skipUnless(shutil.which("curl"), "needs curl")
    def test_wrong_key_and_no_relay(self):
        self.assertIn("wrong or missing key", self.notify("a", "b", key="x" * 32).stderr)
        self.assertEqual(FakeHomeAssistant.calls, [])
        self.assertNotEqual(self.notify("a", "b", endpoint="http://127.0.0.1:1").returncode, 0)

    def test_refuses_to_start_without_a_real_key(self):
        with self.assertRaises(SystemExit):
            relay.settings({"RELAY_HA_URL": "http://x", "RELAY_HA_TOKEN": "t", "RELAY_KEY": "short", "RELAY_TARGETS": '["person.a"]'})


if __name__ == "__main__":
    unittest.main()

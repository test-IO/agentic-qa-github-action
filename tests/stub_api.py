"""Minimal stand-in for the Agentic QA REST API, for exercising scripts/run.sh."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "mixed"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8771
WORK = sys.argv[3] if len(sys.argv) > 3 else "/tmp"


def check(name, state, reasoning=None, seconds=12):
    return {
        "id": name,
        "state": state,
        "reasoning": reasoning,
        "created_at": "2026-09-02T10:00:00Z",
        "updated_at": "2026-09-02T10:00:%02dZ" % seconds,
        "check": {"name": name, "check_suite_name": "Smoke"},
    }


RESULTS = {
    "mixed": [
        check("Login works", "passed", "ok"),
        check("Checkout \"flow\"", "failed", "Button <Submit> not found & missing"),
        check("Search", "blocked"),
    ],
    "green": [check("Login works", "passed", "ok"), check("Checkout", "passed", "ok")],
    "blocked": [check("Login works", "passed", "ok"), check("Search", "blocked")],
    "empty": [],
}

GROWING = [
    check("Login works", "passed", "ok"),
    check("Search", "passed", "ok"),
    check("Cart", "blocked"),
    check("Checkout", "blocked"),
]

polls = {"n": 0}
ce_calls = {"n": 0}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj=None):
        body = json.dumps(obj or {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.headers.get("Authorization", "").startswith("ApiKey "):
            return self.reply(401, {"error": "Not Authorized"})
        if self.path.endswith("/token/verify"):
            if MODE == "expired":
                return self.reply(403, {"error": "Token not found or expired"})
            return self.reply(200, {"status": "ok"})
        if self.path.endswith("/proxy_configs"):
            proxies = [{"id": "proxy-1", "name": "Corp EU", "url": "http://proxy.example.com:3128"}]
            if MODE == "no_proxies":
                proxies = []
            return self.reply(200, {"proxy_configs": proxies, "count": len(proxies)})
        if self.path.endswith("/check_executions"):
            if MODE == "growing":
                # first read sees one row, later reads see all four
                ce_calls["n"] += 1
                rows = GROWING if ce_calls["n"] >= 2 else GROWING[:1]
                return self.reply(200, {"check_executions": rows})
            if MODE == "stuck_running":
                return self.reply(200, {"check_executions": [
                    check("Login works", "passed", "ok"), check("Slow one", "running")]})
            return self.reply(200, {"check_executions": RESULTS.get(MODE, [])})
        polls["n"] += 1
        status = "running" if polls["n"] < 2 else "completed"
        return self.reply(200, {"test_session": {"id": "sess-1", "status": status}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or "{}")
        if self.path.endswith("/run"):
            return self.reply(200, {"test_session": {"id": "sess-1", "status": "started"}})
        with open(os.path.join(WORK, "payload.json"), "w") as handle:
            json.dump(body, handle, indent=2)
        with open(os.path.join(WORK, "create_path"), "w") as handle:
            handle.write(self.path)
        if MODE == "validation":
            return self.reply(422, {"error": {"device_serial": ["is not a known device"]}})
        return self.reply(201, {"test_session": {"id": "sess-1", "status": "created"}})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

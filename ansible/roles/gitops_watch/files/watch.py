"""The phone's watcher: watches the laptop (prod) and xiaoxin (lab, the laptop's outside) from a third machine, and
speaks on the *other* machine when one of them is in trouble — the laptop's own alerting cannot announce that the
laptop, or its alerting, is down.

Checks (config.json, written by ansible role gitops_watch), every INTERVAL seconds:
  tcp        host:port answers (the machine is up and on the tailnet)
  http       a URL answers 2xx within the timeout (a user can reach the service)
  reachable  a URL answers at all, any status (k3s's API: 401 without credentials is alive)
  heartbeat  a POST to /<id> arrived within max_age seconds (Alertmanager's Watchdog, sent every minute: the
             laptop's Prometheus → Alertmanager chain works)
A check is down after `fail_after` failures in a row, up again after `ok_after` successes. A check whose `depends`
is down is not announced (one sentence: "the laptop is unreachable", not four).

Announcements: speakd (POST {"text","lang"}) on the check's `say_via` machine, the other one when that fails, a
Termux notification when both fail. Quiet hours (21-8): nothing is spoken; at 8 what is still down is said once.
Still down: said again every `repeat_hours`. GET /status: the state as JSON; GET /metrics: gitops_watch_up{check}.

POST /notify: an event from another checker on this phone (Gatus, ~/gatus: the endpoint checks, the status page,
certificate expiry), JSON {"name", "group", "state": "down"|"up", "text"}: announced like a check of this watcher —
quiet hours, the morning summary, the fallback to the other speaker / a notification — on the machine that
`notify.via[group]` names; nothing while the check `notify.depends[group]` is down (that machine is unreachable: one
sentence, not one per endpoint). An "up" whose "down" was never announced is not announced either.
"""
import datetime
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


def in_quiet(hour, quiet):
    """quiet "21-8": 21:00 to 07:59; "" = never."""
    if not quiet:
        return False
    a, b = (int(x) for x in quiet.split("-"))
    return (a <= hour < b) if a < b else (hour >= a or hour < b)


class Watcher:
    def __init__(self, cfg, now=time.time, probe=None, speak=None, notify=None):
        self.cfg, self.now = cfg, now
        self.probe = probe or self._probe
        self.speak = speak or self._speak
        self.notify = notify or self._notify
        self.tz = datetime.timezone(datetime.timedelta(hours=cfg.get("tz_offset_hours", 9)))
        self.lock = threading.Lock()
        start = now()
        self.state = {c["id"]: {"up": True, "fails": 0, "oks": 0, "since": start, "said": None, "last_ok": start}
                      for c in cfg["checks"]}
        self.beats = {c["id"]: start for c in cfg["checks"] if c["kind"] == "heartbeat"}   # grace after a start
        self.held = {}   # id → sentence, down during quiet hours, said in the morning if still down
        self.ext = {}    # /notify: name → {"said": bool, "via": machine} while down

    # ── probes ──────────────────────────────────────────────────────────────────────────────────────────────────
    def _probe(self, c):
        t = c.get("timeout", 5)
        if c["kind"] == "tcp":
            host, port = c["target"].rsplit(":", 1)
            with socket.create_connection((host, int(port)), timeout=t):
                return True
        if c["kind"] in ("http", "reachable"):
            ctx = ssl._create_unverified_context()   # k3s's own CA; only "does it answer" is asked
            try:
                with urllib.request.urlopen(c["target"], timeout=t, context=ctx) as r:
                    return 200 <= r.status < 300 or c["kind"] == "reachable"
            except urllib.error.HTTPError:
                return c["kind"] == "reachable"
        if c["kind"] == "heartbeat":
            return self.now() - self.beats[c["id"]] <= c.get("max_age", 600)
        raise ValueError(c["kind"])

    def beat(self, cid):
        with self.lock:
            if cid in self.beats:
                self.beats[cid] = self.now()
                return True
        return False

    # ── announcements ──────────────────────────────────────────────────────────────────────────────────────────
    def _speak(self, url, text):
        body = json.dumps({"text": text, "lang": "zh"}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=20).read()

    def _notify(self, text):
        subprocess.run(["termux-notification", "--title", "gitops watch", "--content", text], timeout=15, check=False)

    def say(self, text, via):
        speakers = self.cfg["speakers"]
        order = [via] + [m for m in speakers if m != via]
        for m in order:
            try:
                self.speak(speakers[m], text)
                log(event="said", via=m, text=text)
                return m
            except Exception as e:   # noqa: BLE001 — the next machine, then the phone itself
                log(event="speak-failed", via=m, error=str(e)[:200])
        try:
            self.notify(text)
        except Exception as e:   # noqa: BLE001
            log(event="notify-failed", error=str(e)[:200])
        log(event="unspoken", text=text)
        return None

    # ── one round ──────────────────────────────────────────────────────────────────────────────────────────────
    def tick(self):
        checks = self.cfg["checks"]
        changed = []
        for c in checks:
            try:
                ok = bool(self.probe(c))
            except Exception:   # noqa: BLE001 — a failed probe is a failure
                ok = False
            with self.lock:
                s = self.state[c["id"]]
                if ok:
                    s["fails"], s["oks"], s["last_ok"] = 0, s["oks"] + 1, self.now()
                    if not s["up"] and s["oks"] >= c.get("ok_after", 2):
                        s["up"], s["since"] = True, self.now()
                        changed.append(c)
                else:
                    s["oks"], s["fails"] = 0, s["fails"] + 1
                    if s["up"] and s["fails"] >= c.get("fail_after", 3):
                        s["up"], s["since"] = False, self.now()
                        changed.append(c)
        return self.announce(changed)

    def blocked(self, c):
        """A dependency is down: this check's state is explained by it."""
        d = c.get("depends")
        return bool(d) and not self.state[d]["up"]

    def announce(self, changed):
        now = self.now()
        quiet = in_quiet(datetime.datetime.fromtimestamp(now, self.tz).hour, self.cfg.get("quiet", "21-8"))
        said = []
        by_id = {c["id"]: c for c in self.cfg["checks"]}
        for c in changed:
            s = self.state[c["id"]]
            if s["up"]:
                if c["id"] in self.held:      # down and back during the night: nobody needs to hear it
                    del self.held[c["id"]]
                    continue
                if s["said"] is None or self.blocked(c):
                    continue                  # never announced down (e.g. hidden by its dependency): no "back"
                text = c["up_text"]
                s["said"] = None
            else:
                if self.blocked(c):
                    continue
                text = c["down_text"]
                if quiet:
                    self.held[c["id"]] = text
                    log(event="held", check=c["id"], text=text)
                    continue
                s["said"] = now
            said.append((text, c["say_via"]))
        if not quiet:
            # the morning: what went down at night and is still down; reminders for what stays down
            if self.held:
                still = {}   # say_via → sentences, in the order of the checks
                for i, t in self.held.items():
                    if i.startswith("ext:"):   # a /notify event: still down (an "up" removes it from held)
                        if i[4:] in self.ext:
                            self.ext[i[4:]]["said"] = True
                            still.setdefault(self.ext[i[4:]]["via"], []).append(t)
                        continue
                    if not self.state[i]["up"] and not self.blocked(by_id[i]):
                        self.state[i]["said"] = now
                        still.setdefault(by_id[i]["say_via"], []).append(t)
                self.held.clear()
                for via, ts in still.items():
                    said.append(("夜里发现的问题，还没有恢复。" + "".join(ts), via))
            repeat = self.cfg.get("repeat_hours", 12) * 3600
            for c in self.cfg["checks"]:
                s = self.state[c["id"]]
                if not s["up"] and s["said"] is not None and now - s["said"] >= repeat and not self.blocked(c):
                    s["said"] = now
                    said.append(("仍未恢复：" + c["down_text"], c["say_via"]))
        for text, via in said:
            self.say(text, via)
        return [t for t, _ in said]

    # ── events from other checkers (POST /notify) ─────────────────────────────────────────────────────────────
    def event(self, ev):
        """→ the sentence announced now, or None (held for the morning, hidden by a dependency, or nothing to say)"""
        ncfg = self.cfg.get("notify", {})
        name, group = str(ev.get("name", "?")), str(ev.get("group", ""))
        what = str(ev.get("text") or name)
        down = ev.get("state") == "down"
        via = ncfg.get("via", {}).get(group, ncfg.get("default_via", next(iter(self.cfg["speakers"]))))
        dep = ncfg.get("depends", {}).get(group)
        now = self.now()
        quiet = in_quiet(datetime.datetime.fromtimestamp(now, self.tz).hour, self.cfg.get("quiet", "21-8"))
        key = "ext:" + name
        with self.lock:
            hidden = bool(dep) and dep in self.state and not self.state[dep]["up"]
            if down:
                self.ext[name] = {"said": False, "via": via}
                text = ncfg.get("down", "外部检查失败：{}。").format(what)
                if hidden:
                    log(event="notify-hidden", name=name, depends=dep)
                    return None
                if quiet:
                    self.held[key] = text
                    log(event="held", check=key, text=text)
                    return None
                self.ext[name]["said"] = True
            else:
                e = self.ext.pop(name, None)
                self.held.pop(key, None)
                if not e or not e["said"]:
                    return None
                text = ncfg.get("up", "外部检查恢复：{}。").format(what)
        self.say(text, via)
        return text

    def status(self):
        with self.lock:
            return {i: {"up": s["up"], "since": s["since"], "last_ok": s["last_ok"]} for i, s in self.state.items()}


def log(**kw):
    print(json.dumps({"ts": datetime.datetime.now().isoformat(timespec="seconds"), **kw}, ensure_ascii=False), flush=True)


def serve(w, port):
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(min(n, 65536))
            if self.path == "/notify":
                try:
                    ev = json.loads(body or b"{}")
                except ValueError:
                    self.send_response(400)
                    self.end_headers()
                    return
                log(event="notify", **{k: str(v)[:200] for k, v in ev.items()})
                threading.Thread(target=w.event, args=(ev,), daemon=True).start()   # speaking takes seconds
                self.send_response(202)
                self.end_headers()
                return
            ok = w.beat(self.path.strip("/"))
            self.send_response(200 if ok else 404)
            self.end_headers()

        def do_GET(self):
            if self.path == "/status":
                body = json.dumps(w.status(), ensure_ascii=False).encode()
                ctype = "application/json"
            elif self.path == "/metrics":
                body = "".join(f'gitops_watch_up{{check="{i}"}} {int(s["up"])}\n' for i, s in w.status().items()).encode()
                ctype = "text/plain; version=0.0.4"
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


def main():
    cfg = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "config.json")))
    w = Watcher(cfg)
    serve(w, cfg.get("port", 9195))
    log(event="start", checks=[c["id"] for c in cfg["checks"]])
    while True:
        try:
            w.tick()
        except Exception as e:   # noqa: BLE001 — keep watching
            log(event="tick-failed", error=str(e)[:300])
        time.sleep(cfg.get("interval", 30))


if __name__ == "__main__":
    main()

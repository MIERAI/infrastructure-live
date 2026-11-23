"""Unit tests of watch.py (no network): python3 -I test_watch.py"""
import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import watch  # noqa: E402

TZ = datetime.timezone(datetime.timedelta(hours=9))


def at(h, m=0, day=21):
    return datetime.datetime(2026, 11, day, h, m, tzinfo=TZ).timestamp()


CFG = {
    "quiet": "21-8", "repeat_hours": 12,
    "speakers": {"xiaoxin": "http://x/", "laptop": "http://l/"},
    "notify": {"via": {"laptop": "xiaoxin"}, "depends": {"laptop": "laptop"}},
    "checks": [
        {"id": "laptop", "kind": "tcp", "target": "l:22", "say_via": "xiaoxin",
         "down_text": "笔记本连不上了。", "up_text": "笔记本恢复了。"},
        {"id": "shop", "kind": "http", "target": "http://l/", "say_via": "xiaoxin", "depends": "laptop",
         "down_text": "商店访问不了。", "up_text": "商店恢复了。"},
        {"id": "alerting", "kind": "heartbeat", "max_age": 600, "say_via": "xiaoxin", "depends": "laptop",
         "down_text": "告警系统没有心跳。", "up_text": "告警系统恢复了。"},
        {"id": "xiaoxin", "kind": "tcp", "target": "x:22", "say_via": "laptop",
         "down_text": "小新连不上了。", "up_text": "小新恢复了。"},
    ],
}


class Fake:
    def __init__(self, t):
        self.t = t
        self.down = set()
        self.spoken = []        # (url, text)
        self.dead_speakers = set()
        self.notified = []

    def now(self):
        return self.t

    def probe(self, c):
        if c["kind"] == "heartbeat":
            return self.w._probe(c)
        return c["id"] not in self.down

    def speak(self, url, text):
        if url in self.dead_speakers:
            raise OSError("unreachable")
        self.spoken.append((url, text))


def watcher(t):
    f = Fake(t)
    f.w = watch.Watcher(CFG, now=f.now, probe=f.probe, speak=f.speak, notify=f.notified.append)
    return f


def run(f, n, step=30):
    out = []
    for _ in range(n):
        f.t += step
        f.w.beat("alerting")
        out += f.w.tick()
    return out


class Watch(unittest.TestCase):
    def test_quiet_hours(self):
        self.assertTrue(watch.in_quiet(21, "21-8"))
        self.assertTrue(watch.in_quiet(3, "21-8"))
        self.assertFalse(watch.in_quiet(8, "21-8"))
        self.assertFalse(watch.in_quiet(12, ""))

    def test_down_after_three_failures_spoken_on_the_other_machine(self):
        f = watcher(at(10))
        f.down.add("xiaoxin")
        self.assertEqual(run(f, 2), [])
        self.assertEqual(run(f, 1), ["小新连不上了。"])
        self.assertEqual(f.spoken, [("http://l/", "小新连不上了。")])
        f.down.clear()
        self.assertEqual(run(f, 1), [])
        self.assertEqual(run(f, 1), ["小新恢复了。"])

    def test_one_sentence_when_the_machine_is_down(self):
        f = watcher(at(10))
        f.down |= {"laptop", "shop"}
        self.assertEqual(run(f, 5), ["笔记本连不上了。"])

    def test_service_down_on_a_live_machine(self):
        f = watcher(at(10))
        f.down.add("shop")
        self.assertEqual(run(f, 3), ["商店访问不了。"])

    def test_heartbeat_stops(self):
        f = watcher(at(10))
        out = []
        for _ in range(25):          # 12.5 min without a beat
            f.t += 30
            out += f.w.tick()
        self.assertEqual(out, ["告警系统没有心跳。"])
        self.assertEqual(run(f, 2), ["告警系统恢复了。"])

    def test_night_held_until_morning_when_still_down(self):
        f = watcher(at(23))
        f.down.add("shop")
        self.assertEqual(run(f, 5), [])
        self.assertEqual(f.spoken, [])
        f.t = at(8, 0, day=22) - 30
        self.assertEqual(run(f, 1), ["夜里发现的问题，还没有恢复。商店访问不了。"])
        f.down.clear()
        self.assertEqual(run(f, 2), ["商店恢复了。"])

    def test_night_problem_gone_by_morning_is_not_spoken(self):
        f = watcher(at(2))
        f.down.add("shop")
        run(f, 5)
        f.down.clear()
        run(f, 5)
        f.t = at(8) - 30
        self.assertEqual(run(f, 2), [])
        self.assertEqual(f.spoken, [])

    def test_reminder_every_12_hours(self):
        f = watcher(at(8, 30))
        f.down.add("shop")
        self.assertEqual(run(f, 3), ["商店访问不了。"])
        self.assertEqual(run(f, 10), [])
        f.t += 12 * 3600
        self.assertEqual(run(f, 1), ["仍未恢复：商店访问不了。"])

    def test_falls_back_to_the_other_speaker_then_a_notification(self):
        f = watcher(at(10))
        f.dead_speakers.add("http://x/")
        f.down.add("shop")
        run(f, 3)
        self.assertEqual(f.spoken, [("http://l/", "商店访问不了。")])
        f.dead_speakers.add("http://l/")
        f.down.add("xiaoxin")
        run(f, 3)
        self.assertEqual(f.notified, ["小新连不上了。"])

    def test_notify_event_spoken_and_resolved(self):
        f = watcher(at(10))
        ev = {"name": "laptop/storefront", "group": "laptop", "text": "商店网站(prod)"}
        self.assertEqual(f.w.event({**ev, "state": "down"}), "外部检查失败：商店网站(prod)。")
        self.assertEqual(f.spoken, [("http://x/", "外部检查失败：商店网站(prod)。")])
        self.assertEqual(f.w.event({**ev, "state": "up"}), "外部检查恢复：商店网站(prod)。")
        self.assertIsNone(f.w.event({**ev, "state": "up"}))          # no second "up"

    def test_notify_hidden_while_the_machine_is_down(self):
        f = watcher(at(10))
        f.down.add("laptop")
        run(f, 3)
        ev = {"name": "laptop/grafana", "group": "laptop", "text": "Grafana"}
        self.assertIsNone(f.w.event({**ev, "state": "down"}))
        self.assertIsNone(f.w.event({**ev, "state": "up"}))           # never announced down: no "up"
        self.assertEqual(f.spoken, [("http://x/", "笔记本连不上了。")])

    def test_notify_at_night_held_until_morning(self):
        f = watcher(at(23))
        ev = {"name": "laptop/argo", "group": "laptop", "text": "Argo CD"}
        self.assertIsNone(f.w.event({**ev, "state": "down"}))
        self.assertEqual(f.spoken, [])
        f.t = at(8, 0, day=22) - 30
        self.assertEqual(run(f, 1), ["夜里发现的问题，还没有恢复。外部检查失败：Argo CD。"])
        self.assertEqual(f.w.event({**ev, "state": "up"}), "外部检查恢复：Argo CD。")

    def test_notify_down_and_back_at_night_is_not_spoken(self):
        f = watcher(at(2))
        ev = {"name": "laptop/board", "group": "laptop", "text": "交付看板"}
        f.w.event({**ev, "state": "down"})
        self.assertIsNone(f.w.event({**ev, "state": "up"}))
        f.t = at(8) - 30
        self.assertEqual(run(f, 2), [])
        self.assertEqual(f.spoken, [])

    def test_unknown_heartbeat_is_refused(self):
        f = watcher(at(10))
        self.assertFalse(f.w.beat("nope"))
        self.assertTrue(f.w.beat("alerting"))


if __name__ == "__main__":
    unittest.main()

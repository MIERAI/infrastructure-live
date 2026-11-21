"""Unit tests of to_configmaps.py: python3 -I test_to_configmaps.py"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import to_configmaps as t  # noqa: E402

PHONE = {"type": "prometheus", "uid": "prometheus"}
NEW = {"type": "prometheus", "uid": "phone-prometheus"}


class Rewrite(unittest.TestCase):
    def test_panel_and_target_objects(self):
        d = {"panels": [{"datasource": dict(PHONE), "targets": [{"datasource": dict(PHONE), "expr": "up"}]}]}
        self.assertEqual(t.rewrite(d, "phone-prometheus"), 2)
        self.assertEqual(d["panels"][0]["datasource"], NEW)
        self.assertEqual(d["panels"][0]["targets"][0]["datasource"], NEW)

    def test_string_forms(self):
        d = {"panels": [{"datasource": "Prometheus"}, {"datasource": "${DS_PROMETHEUS}"}]}
        self.assertEqual(t.rewrite(d, "phone-prometheus"), 2)
        self.assertEqual([p["datasource"] for p in d["panels"]], [NEW, NEW])

    def test_leaves_others(self):
        d = {"panels": [{"datasource": {"type": "grafana", "uid": "-- Grafana --"}}, {"datasource": "Loki"},
                        {"datasource": {"type": "loki", "uid": "prometheus"}}]}
        before = json.dumps(d)
        self.assertEqual(t.rewrite(d, "phone-prometheus"), 0)
        self.assertEqual(json.dumps(d), before)

    def test_datasource_variable_pinned(self):
        d = {"templating": {"list": [{"name": "ds", "type": "datasource", "query": "prometheus"},
                                     {"name": "job", "type": "query", "datasource": dict(PHONE)}]}}
        self.assertEqual(t.rewrite(d, "phone-prometheus"), 2)
        ds_var, q_var = d["templating"]["list"]
        self.assertEqual(ds_var["current"]["value"], "phone-prometheus")
        self.assertEqual(q_var["datasource"], NEW)


class ConfigMap(unittest.TestCase):
    def test_configmap(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "blog.json")
            with open(p, "w", encoding="utf-8") as f:
                json.dump({"id": 7, "uid": "blog1", "title": "博客", "panels": [{"datasource": PHONE}]}, f)
            cm, n = t.configmap(p, "monitoring", "phone-prometheus")
        self.assertEqual(n, 1)
        self.assertEqual(cm["metadata"]["name"], "phone-dashboard-blog")
        self.assertEqual(cm["metadata"]["labels"]["grafana_dashboard"], "1")
        dash = json.loads(cm["data"]["phone-blog.json"])
        self.assertIsNone(dash["id"])
        self.assertEqual(dash["title"], "博客")
        self.assertEqual(dash["panels"][0]["datasource"], NEW)


if __name__ == "__main__":
    unittest.main()

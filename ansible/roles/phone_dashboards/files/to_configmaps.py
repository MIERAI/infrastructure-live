"""Phone Grafana dashboards → ConfigMaps for the laptop Grafana's dashboard sidecar.

    python3 -I to_configmaps.py NAMESPACE DATASOURCE_UID DIR/NAME.json... > list.json

The phone's panels point at its own Prometheus by uid "prometheus"; on the laptop that uid is the laptop's Prometheus,
so every Prometheus reference is pinned to DATASOURCE_UID. Output is a v1 List (JSON = YAML for kubectl).
"""
import json
import os
import sys

PHONE_UIDS = {"prometheus"}
PHONE_NAMES = {"prometheus", "Prometheus"}   # legacy string form: datasource by name


def ds(uid):
    return {"type": "prometheus", "uid": uid}


def is_phone_ref(v):
    if isinstance(v, dict):
        return v.get("uid") in PHONE_UIDS and v.get("type", "prometheus") == "prometheus"
    if isinstance(v, str):
        return v in PHONE_NAMES or v.startswith("${DS_")
    return False


def rewrite(node, uid):
    """Rewrite in place; returns the number of references changed."""
    n = 0
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "datasource" and is_phone_ref(v):
                node[k] = ds(uid)
                n += 1
            else:
                n += rewrite(v, uid)
        # a datasource variable would let the viewer pick the laptop's own Prometheus: pin it
        if node.get("type") == "datasource" and node.get("query") == "prometheus":
            node["current"] = {"text": uid, "value": uid}
            n += 1
    elif isinstance(node, list):
        for x in node:
            n += rewrite(x, uid)
    return n


def configmap(path, namespace, uid):
    with open(path, encoding="utf-8") as f:
        dash = json.load(f)
    dash.pop("__inputs", None)
    dash["id"] = None          # ids are per Grafana instance; uid identifies the dashboard
    count = rewrite(dash, uid)
    name = os.path.splitext(os.path.basename(path))[0]
    cm = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": f"phone-dashboard-{name}",
            "namespace": namespace,
            "labels": {"grafana_dashboard": "1", "gitops-platform/source": "phone"},
            "annotations": {"gitops-platform/managed-by": "infrastructure-live ansible role phone_dashboards"},
        },
        "data": {f"phone-{name}.json": json.dumps(dash, ensure_ascii=False, indent=1, sort_keys=True)},
    }
    return cm, count


def main(argv):
    namespace, uid, *paths = argv
    items = []
    for p in paths:
        cm, count = configmap(p, namespace, uid)
        print(f"{cm['metadata']['name']}: {count} datasource references", file=sys.stderr)
        items.append(cm)
    json.dump({"apiVersion": "v1", "kind": "List", "items": items}, sys.stdout, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])

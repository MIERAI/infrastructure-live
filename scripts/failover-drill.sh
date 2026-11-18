#!/usr/bin/env bash
# Failover drill: delete the Postgres primary of an api-factory environment while traffic is flowing
# (synthetic-traffic Deployment), then report how long until the cluster is healthy again and which API errors
# the outage caused (from the api-factory logs).
#   scripts/failover-drill.sh [namespace]      (default api-factory-prod: 2 instances)
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
NS=${1:-api-factory-prod}
n=$(kubectl -n "$NS" get cluster postgres -o jsonpath='{.spec.instances}')
[ "$n" -ge 2 ] || { echo "✗ $NS has $n instance(s): nothing to fail over to"; exit 1; }
old=$(kubectl -n "$NS" get cluster postgres -o jsonpath='{.status.currentPrimary}')
t0=$(date +%s)
kubectl -n "$NS" delete pod "$old" --wait=false >/dev/null
echo "• $NS: deleted primary $old"
# healthy again with a different primary (the phase can still say healthy for a moment right after the delete)
until new=$(kubectl -n "$NS" get cluster postgres -o jsonpath='{.status.currentPrimary}') && [ "$new" != "$old" ] &&
      [ "$(kubectl -n "$NS" get cluster postgres -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ]; do
  [ $(( $(date +%s) - t0 )) -lt 600 ] || { echo "✗ not healthy after 10 min"; exit 1; }
  sleep 2
done
healthy=$(( $(date +%s) - t0 ))
sleep 10   # let the API pools reconnect / surface errors
since=$(( $(date +%s) - t0 + 5 ))
for p in $(kubectl -n "$NS" get pods -l app=api-factory -o name); do kubectl -n "$NS" logs "$p" --since="${since}s"; done |
  python3 -c '
import sys, json, datetime
t0 = int(sys.argv[1]); errs = []
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("level") != "ERROR": continue
    t = datetime.datetime.fromisoformat(d["time"][:26].rstrip("Z")).replace(tzinfo=datetime.timezone.utc).timestamp()
    errs.append(t - t0)
if errs:
    print(f"  API errors: {len(errs)} between +{min(errs):.1f}s and +{max(errs):.1f}s")
else:
    print("  API errors: none")
' "$t0"
echo "✓ new primary $new, cluster healthy after ${healthy}s"

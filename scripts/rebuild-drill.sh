#!/usr/bin/env bash
# From-scratch rebuild drill: delete the cluster and every local secret, rebuild everything from Git, and time it.
#   scripts/rebuild-drill.sh --yes
# Phases: down → up (kind + Argo CD + secrets + root app) → every Application Synced/Healthy → smoke checks
# (each app serves /healthz; api-factory answers an authenticated RPC; the databases archive WAL).
# Not covered: data. Backups live in the cluster's object store and go with it (on GKE: GCS, outside the cluster);
# the databases come back empty (dev re-seeded by the schema Job).
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = --yes ] || { echo "deletes the kind cluster 'gitops' and .secrets/ — run with --yes"; exit 1; }
start=$(date +%s); last=$start
phase() { local now; now=$(date +%s); printf '  %-40s %5ss  (total %ss)\n' "$1" $((now - last)) $((now - start)); last=$now; }
log=$(mktemp); trap 'rm -f "$log"' EXIT
run() { "$@" >"$log" 2>&1 || { cat "$log"; echo "✗ failed: $*"; exit 1; }; }

echo "━━ rebuild drill $(date '+%F %T')"
run scripts/down.sh;                                              phase "down (cluster + secrets deleted)"
run scripts/up.sh;                                                phase "up (kind, Argo CD, secrets, root app)"
expect=$(find ../gitops-manifests/apps -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
run scripts/wait-synced.sh --timeout 1800 --healthy --expect $(( ${expect:-1} + 1 ))
phase "all $(( ${expect:-1} + 1 )) applications Synced/Healthy"

for port in 18080 18081 18082 18083; do
  for _ in $(seq 1 60); do curl -fsS -m 2 "localhost:$port/healthz" >/dev/null 2>&1 && break; sleep 2; done
  curl -fsS -m 2 "localhost:$port/healthz" >/dev/null || { echo "✗ localhost:$port/healthz"; exit 1; }
done
for env in dev:18080 prod:18081; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $(cat ".secrets/api-factory-${env%%:*}.token")" -d '{"pageSize":1}' \
    "localhost:${env##*:}/factory.jobs.v1.JobService/ListJobs")
  [ "$code" = 200 ] || { echo "✗ api-factory ${env%%:*}: authenticated RPC → $code"; exit 1; }
done
for ns in api-factory-dev api-factory-prod; do
  for _ in $(seq 1 60); do
    [ "$(kubectl -n "$ns" get cluster postgres -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')" = True ] && break
    sleep 5
  done
  [ "$(kubectl -n "$ns" get cluster postgres -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')" = True ] ||
    { echo "✗ $ns: WAL archiving not working"; exit 1; }
done
phase "smoke checks (4 apps, 2 authenticated RPCs, WAL archiving)"
echo "✓ rebuilt from Git in $(( $(date +%s) - start ))s"

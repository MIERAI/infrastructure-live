#!/usr/bin/env bash
# From-scratch rebuild drill: delete the cluster and every local secret, rebuild everything from Git, and time it.
#   scripts/rebuild-drill.sh --yes
# Phases: tofu destroy → tofu apply (kind + Argo CD + secrets + root app) → every Application Synced/Healthy → smoke
# checks. Needs: TF_VAR_ghcr_token (gh auth token --user MIERAI, read:packages) and the age key (secrets/kind.sops.yaml).
# (each app serves /healthz; api-factory answers an authenticated RPC; the databases archive WAL).
# Not covered: data. Backups live in the cluster's object store and go with it (on GKE: GCS, outside the cluster);
# the databases come back empty (dev re-seeded by the migrate init container).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ "$TARGET" = kind ] || { echo "rebuild-drill.sh: kind only"; exit 1; }
[ "${1:-}" = --yes ] || { echo "deletes the kind cluster 'gitops' — run with --yes"; exit 1; }
export TF_VAR_ghcr_token=${TF_VAR_ghcr_token:-$(gh auth token --user MIERAI)}
tofu() { command tofu -chdir=tofu/kind "$@" -input=false -no-color; }
start=$(date +%s); last=$start
phase() { local now; now=$(date +%s); printf '  %-40s %5ss  (total %ss)\n' "$1" $((now - last)) $((now - start)); last=$now; }
log=$(mktemp); trap 'rm -f "$log"' EXIT
run() { "$@" >"$log" 2>&1 || { cat "$log"; echo "✗ failed: $*"; exit 1; }; }

echo "━━ rebuild drill $(date '+%F %T')"
run tofu destroy -auto-approve;                                   phase "tofu destroy (cluster deleted)"
run tofu apply -auto-approve;                                     phase "tofu apply (kind, Argo CD, secrets, root app)"
# the Applications the root renders = the resources of apps/kustomization.yaml (not every *.yaml: the kustomization
# file itself is one)
expect=$(grep -cE '^  - .*\.yaml' ../gitops-manifests/apps/kustomization.yaml 2>/dev/null || echo 1)
run scripts/wait-synced.sh --timeout 1800 --healthy --expect $(( ${expect:-1} + 1 ))
phase "all $(( ${expect:-1} + 1 )) applications Synced/Healthy"

for app in api-factory-dev api-factory-prod sample-app-dev sample-app-prod; do
  url=$(app_url "$app")
  for _ in $(seq 1 60); do curl -fsS -m 2 "$url/healthz" >/dev/null 2>&1 && break; sleep 2; done
  curl -fsS -m 2 "$url/healthz" >/dev/null || { echo "✗ $url/healthz"; exit 1; }
done
for env in dev prod; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $(cat "$SECRETS/api-factory-$env.token")" -d '{"pageSize":1}' \
    "$(app_url "api-factory-$env")/factory.jobs.v1.JobService/ListJobs")
  [ "$code" = 200 ] || { echo "✗ api-factory $env: authenticated RPC → $code"; exit 1; }
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

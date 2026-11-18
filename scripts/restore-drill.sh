#!/usr/bin/env bash
# Point-in-time recovery drill for an api-factory environment (CloudNativePG + Barman Cloud plugin).
#   scripts/restore-drill.sh [namespace]      (default api-factory-dev)
# 1. writes a marker row (database "postgres", table restore_drill: the app's data is not touched), notes the time,
#    deletes the row, switches WAL and waits until that segment is archived
# 2. restores a new cluster "restore-drill" from the backups to that time and checks the row is back
# 3. reports how long the restore took, then removes the restored cluster and the marker table
# The live cluster keeps serving the whole time. Needs a completed base backup (ScheduledBackup "daily", immediate).
set -euo pipefail
NS=${1:-api-factory-dev}
CL=postgres
primary=$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}')
image=$(kubectl -n "$NS" get cluster "$CL" -o jsonpath='{.spec.imageName}')
psql_live() { kubectl -n "$NS" exec "$primary" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -tAc "$1"; }
cleanup() {
  kubectl -n "$NS" delete cluster restore-drill --ignore-not-found --wait=false >/dev/null
  psql_live "DROP TABLE IF EXISTS restore_drill" >/dev/null || true
}
trap cleanup EXIT

backup=$(kubectl -n "$NS" get backups -o jsonpath='{range .items[?(@.status.phase=="completed")]}{.metadata.name}{"\n"}{end}' | tail -1)
[ -n "$backup" ] || { echo "✗ no completed backup in $NS"; exit 1; }
marker="drill-$(date +%s)"
psql_live "CREATE TABLE IF NOT EXISTS restore_drill(marker text); INSERT INTO restore_drill VALUES ('$marker')" >/dev/null
sleep 2; target=$(psql_live "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"); sleep 2
psql_live "DELETE FROM restore_drill" >/dev/null
# The DELETE commit (first record after the target) must be in the archive, or recovery stops before the target and
# retries until archive_timeout ships the segment (~5 min). Separate statement: psql -c "a; b" is ONE transaction,
# which would put the commit after the switch.
wal=$(psql_live "SELECT pg_walfile_name(pg_switch_wal())")
for _ in $(seq 1 60); do
  [ "$(psql_live "SELECT last_archived_wal >= '$wal' FROM pg_stat_archiver")" = t ] && break; sleep 1
done
echo "• $NS: marker $marker written, target time $target, row deleted (latest base backup: $backup)"

start=$(date +%s)
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: restore-drill }
spec:
  instances: 1
  imageName: $image
  storage: { size: 1Gi }
  resources:   # the admission policies (require-resources) apply to the drill's Pods and bootstrap Job too
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
  bootstrap:
    recovery:
      source: origin
      recoveryTarget: { targetTime: "$target" }
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: backups, serverName: $CL }
YAML
for _ in $(seq 1 180); do
  phase=$(kubectl -n "$NS" get cluster restore-drill -o jsonpath='{.status.phase}')
  [ "$phase" = "Cluster in healthy state" ] && break; sleep 5
done
[ "$phase" = "Cluster in healthy state" ] || { echo "✗ restored cluster not healthy after 15 min: $phase"; exit 1; }
got=$(kubectl -n "$NS" exec restore-drill-1 -c postgres -- psql -X -U postgres -d postgres -tAc "SELECT marker FROM restore_drill")
took=$(( $(date +%s) - start ))
if [ "$got" = "$marker" ]; then
  echo "✓ point-in-time restore: marker is back in the restored cluster (restore took ${took}s)"
else
  echo "✗ restored cluster has '$got', expected '$marker'"; exit 1
fi

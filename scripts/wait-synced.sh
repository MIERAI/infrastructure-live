#!/usr/bin/env bash
# 等 Argo CD 的 Application 都同步完(gitops-manifests 的每个应用都被创建并同步)。
#   usage: scripts/wait-synced.sh [--timeout 600] [--healthy] [--only REGEX] [--expect N]
#     --only   只看名字匹配的 Application(其余只要求存在)
#     --expect Application 至少要有几个(包括 root)
set -euo pipefail
timeout=600; healthy=""; only="."; expect=2
while [ $# -gt 0 ]; do
  case $1 in
    --timeout) timeout=$2; shift 2 ;;
    --healthy) healthy=1; shift ;;
    --only) only=$2; shift 2 ;;
    --expect) expect=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
end=$(( $(date +%s) + timeout ))
while :; do
  rows=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  total=$(grep -c . <<<"$rows" || true)
  watched=$(awk -v re="$only" '$1 ~ re' <<<"$rows")
  n=$(grep -c . <<<"$watched" || true)
  ok=$(awk -v h="$healthy" '$2=="Synced" && (h=="" || $3=="Healthy")' <<<"$watched" | grep -c . || true)
  if [ "$total" -ge "$expect" ] && [ "$n" -gt 0 ] && [ "$ok" = "$n" ]; then
    echo "✓ $ok/$n applications synced${healthy:+ and healthy} ($total in total)"; printf '%s\n' "$rows"; exit 0
  fi
  if [ "$(date +%s)" -ge "$end" ]; then echo "✗ timeout ($ok/$n, $total in total)"; printf '%s\n' "$rows"; exit 1; fi
  sleep 10
done

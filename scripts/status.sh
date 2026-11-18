#!/usr/bin/env bash
# 一眼看清: 每个 Application 的同步 / 健康、正在服务的版本(/healthz 的 X-App-Version)、访问地址
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
printf '%-18s %-10s %-12s %-10s %s\n' APPLICATION SYNC HEALTH SERVING URL
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' |
while read -r name sync health; do
  ver=-; url=-
  if url=$(app_url "$name"); then
    ver=$(curl -s -m 2 -D - -o /dev/null "$url/healthz" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')
    ver=${ver:-down}
  fi
  printf '%-18s %-10s %-12s %-10s %s\n' "$name" "$sync" "$health" "$ver" "$url"
done

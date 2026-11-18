#!/usr/bin/env bash
# 一眼看清: 每个 Application 的同步 / 健康、正在服务的版本(/healthz 的 X-App-Version)、访问地址
set -euo pipefail
cd "$(dirname "$0")/.."
printf '%-18s %-10s %-12s %-10s %s\n' APPLICATION SYNC HEALTH SERVING URL
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' |
while read -r name sync health; do
  case $name in
    api-factory-dev) port=18080 ;; api-factory-prod) port=18081 ;;
    sample-app-dev) port=18082 ;; sample-app-prod) port=18083 ;; *) port= ;;
  esac
  ver=-; url=-
  if [ -n "$port" ]; then
    url=http://localhost:$port
    ver=$(curl -s -m 2 -D - -o /dev/null "$url/healthz" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')
    ver=${ver:-down}
  fi
  printf '%-18s %-10s %-12s %-10s %s\n' "$name" "$sync" "$health" "$ver" "$url"
done

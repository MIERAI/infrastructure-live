#!/usr/bin/env bash
# Local UIs over port-forward (restarted automatically when a pod is replaced).
#   scripts/ui.sh        start (background) and print the URLs + where the passwords are
#   scripts/ui.sh stop   stop them
# Argo Rollouts dashboard needs the kubectl-argo-rollouts plugin (ROLLOUTS_PLUGIN, default: on PATH or ../bin).
set -euo pipefail
cd "$(dirname "$0")/.."
pidfile=.secrets/ui.pids
stop() {   # the loop first (no restart), then its port-forward child
  [ -f "$pidfile" ] && while read -r p; do
    kids=$(pgrep -P "$p" || true)   # before the loop dies: afterwards its child is re-parented
    kill "$p" 2>/dev/null || true
    for k in $kids; do kill "$k" 2>/dev/null || true; done
  done < "$pidfile"
  rm -f "$pidfile"
}
if [ "${1:-}" = stop ]; then stop; echo "✓ stopped"; exit 0; fi
stop
mkdir -p .secrets
keep() { (while true; do "$@" >/dev/null 2>&1 || true; sleep 2; done) & echo $! >> "$pidfile"; }
keep kubectl -n argocd port-forward svc/argocd-server 8443:80
keep kubectl -n monitoring port-forward svc/platform-monitoring-grafana 3000:80
keep kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
plugin=${ROLLOUTS_PLUGIN:-$(command -v kubectl-argo-rollouts || echo ../bin/kubectl-argo-rollouts)}
[ -x "$plugin" ] && keep "$plugin" dashboard --port 3100
sleep 3
cat <<TXT
✓ UIs (scripts/ui.sh stop to close)
  Argo CD     http://localhost:8443   admin / .secrets/argocd-admin.password
  Grafana     http://localhost:3000   admin / .secrets/grafana-admin.password
  Prometheus  http://localhost:9090
  Rollouts    http://localhost:3100$([ -x "$plugin" ] || echo "   (kubectl-argo-rollouts plugin not found: skipped)")
TXT

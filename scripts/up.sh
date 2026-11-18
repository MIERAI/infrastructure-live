#!/usr/bin/env bash
# 本地的平台: kind 集群 → Argo CD → 密钥(不进 Git)→ 根应用。之后的一切由 gitops-manifests 决定
#   需要: docker / kind / kubectl / gh(GHCR 的拉取令牌: gh auth token,要 read:packages)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
if [ "$TARGET" = kind ] && ! kind get clusters | grep -qx gitops; then
  kind create cluster --config kind/cluster.yaml
fi
# laptop: k3s and the host's object store come from scripts/laptop-host.sh
echo "━━ Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k argocd --server-side --force-conflicts >/dev/null
for d in $(kubectl -n argocd get deploy -o name); do kubectl -n argocd rollout status "$d" --timeout=300s >/dev/null; done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
# wait until repo-server accepts connections (an early failed comparison can stick for a while)
for _ in $(seq 1 60); do
  kubectl -n argocd get endpointslices -l kubernetes.io/service-name=argocd-repo-server \
    -o jsonpath='{.items[*].endpoints[*].conditions.ready}' | grep -q true && break
  sleep 2
done
echo "━━ 密钥(本地生成,不进 Git)"
scripts/secrets.sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d > "$SECRETS/argocd-admin.password"
echo "━━ 根应用"
sed "s#path: apps#path: $ROOT_PATH#" bootstrap/root.yaml | kubectl apply -f - >/dev/null
echo "✓ 平台就绪。UI: scripts/ui.sh(Argo CD / Grafana / Prometheus / Rollouts),密码在 $SECRETS/"

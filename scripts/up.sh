#!/usr/bin/env bash
# 本地的平台: kind 集群 → Argo CD → 密钥(不进 Git)→ 根应用。之后的一切由 gitops-manifests 决定
#   需要: docker / kind / kubectl / gh(GHCR 的拉取令牌: gh auth token,要 read:packages)
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=gitops
if ! kind get clusters | grep -qx $CLUSTER; then
  kind create cluster --config kind/cluster.yaml
fi
kubectl config use-context kind-$CLUSTER >/dev/null
echo "━━ Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k argocd --server-side --force-conflicts >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server deploy/argocd-server --timeout=300s >/dev/null
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
echo "━━ 密钥(本地生成,不进 Git)"
scripts/secrets.sh
echo "━━ 根应用"
kubectl apply -f bootstrap/root.yaml >/dev/null
echo "✓ 平台就绪。Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8443:80 → http://127.0.0.1:8443"
echo "  admin 密码: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

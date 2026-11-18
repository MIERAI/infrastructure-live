#!/usr/bin/env bash
# 运行时的密钥: Git(公开的 gitops-manifests)里只有引用(secretKeyRef),值在这里生成。
# 已经存在的不覆盖(重复执行安全)。API 的令牌存在 .secrets/<TARGET>/(不进 Git),调用时用。
#   GHCR_USER(默认 MIERAI)/ GHCR_TOKEN(默认 gh auth token --user $GHCR_USER,要 read:packages)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
mkdir -p "$SECRETS"
GHCR_USER=${GHCR_USER:-MIERAI}
GHCR_TOKEN=${GHCR_TOKEN:-$(gh auth token --user "$GHCR_USER")}
rand() { openssl rand -hex 24; }
has() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
for ns in api-factory-dev api-factory-prod sample-app-dev sample-app-prod; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null
  # 私有的镜像(GHCR)
  has "$ns" ghcr-pull || kubectl -n "$ns" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" >/dev/null
done
# S3 credentials for database backups: the object store (SeaweedFS identity) and every api-factory namespace
[ -f "$SECRETS/s3-access-key" ] || { rand > "$SECRETS/s3-access-key"; rand > "$SECRETS/s3-secret-key"; }
ak=$(cat "$SECRETS/s3-access-key"); sk=$(cat "$SECRETS/s3-secret-key")
kubectl get namespace object-storage >/dev/null 2>&1 || kubectl create namespace object-storage >/dev/null
has object-storage seaweedfs-s3 || kubectl -n object-storage create secret generic seaweedfs-s3 --from-literal=s3.json="$(printf \
  '{"identities":[{"name":"cnpg","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$ak" "$sk")" >/dev/null
for ns in api-factory-dev api-factory-prod; do
  has "$ns" backup-s3 || kubectl -n "$ns" create secret generic backup-s3 \
    --from-literal=ACCESS_KEY_ID="$ak" --from-literal=ACCESS_SECRET_KEY="$sk" >/dev/null
  if ! has "$ns" api-factory; then
    pw=$(rand)
    [ -f "$SECRETS/$ns.token" ] || printf %s "$(rand)" > "$SECRETS/$ns.token"   # keep the API token across re-creation; no newline
    token=$(cat "$SECRETS/$ns.token")
    db="postgres://factory:$pw@postgres-rw:5432"                 # CloudNativePG primary service
    kubectl -n "$ns" create secret generic postgres-app --type=kubernetes.io/basic-auth \
      --from-literal=username=factory --from-literal=password="$pw" >/dev/null
    kubectl -n "$ns" create secret generic api-factory \
      --from-literal=DATABASE_URL="$db/factory?sslmode=disable" \
      --from-literal=FACTORY_SHARDS="1-2=$db/shard_a?sslmode=disable;*=$db/shard_b?sslmode=disable" \
      --from-literal=PAGE_TOKEN_KEY="$(rand)" \
      --from-literal=AUTH_TOKEN_SHA256="$(printf %s "$token" | shasum -a 256 | cut -d' ' -f1)" >/dev/null
  fi
  # synthetic traffic needs the plain token (the server only knows its sha256)
  # --from-literal + $(cat): no trailing newline even if the file has one (a newline made every Authorization header
  # invalid for k6 / curl, while the server's sha256 above, also from $(cat), was right: only the load test noticed)
  has "$ns" api-token || kubectl -n "$ns" create secret generic api-token --from-literal=token="$(cat "$SECRETS/$ns.token")" >/dev/null
done
# Grafana admin (kube-prometheus-stack: grafana.admin.existingSecret)
kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring >/dev/null
if ! has monitoring grafana-admin; then
  pw=$(rand)
  kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$pw" >/dev/null
  printf %s "$pw" > "$SECRETS/grafana-admin.password"
fi
echo "✓ secrets ($TARGET; API tokens: $SECRETS/<namespace>.token, Grafana: $SECRETS/grafana-admin.password)"

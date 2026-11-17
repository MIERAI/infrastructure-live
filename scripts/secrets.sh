#!/usr/bin/env bash
# 运行时的密钥: Git(公开的 gitops-manifests)里只有引用(secretKeyRef),值在这里生成。
# 已经存在的不覆盖(重复执行安全)。API 的令牌存在 .secrets/(不进 Git),调用时用。
#   GHCR_USER(默认 MIERAI)/ GHCR_TOKEN(默认 gh auth token --user $GHCR_USER,要 read:packages)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .secrets
GHCR_USER=${GHCR_USER:-MIERAI}
GHCR_TOKEN=${GHCR_TOKEN:-$(gh auth token --user "$GHCR_USER")}
rand() { openssl rand -hex 24; }
has() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
for ns in api-factory-dev api-factory-prod sample-app-dev sample-app-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # 私有的镜像(GHCR)
  has "$ns" ghcr-pull || kubectl -n "$ns" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" >/dev/null
done
for ns in api-factory-dev api-factory-prod; do
  if ! has "$ns" api-factory; then
    pw=$(rand); token=$(rand)
    db="postgres://factory:$pw@postgres:5432"
    kubectl -n "$ns" create secret generic postgres --from-literal=POSTGRES_PASSWORD="$pw" >/dev/null
    kubectl -n "$ns" create secret generic api-factory \
      --from-literal=DATABASE_URL="$db/factory?sslmode=disable" \
      --from-literal=FACTORY_SHARDS="1-2=$db/shard_a?sslmode=disable;*=$db/shard_b?sslmode=disable" \
      --from-literal=PAGE_TOKEN_KEY="$(rand)" \
      --from-literal=AUTH_TOKEN_SHA256="$(printf %s "$token" | shasum -a 256 | cut -d' ' -f1)" >/dev/null
    printf %s "$token" > ".secrets/$ns.token"
  fi
done
echo "✓ secrets(API 的令牌: .secrets/<namespace>.token)"

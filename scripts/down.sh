#!/usr/bin/env bash
# 删除本地的平台(集群和里面的一切)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ "$TARGET" = kind ] || { echo "down.sh only deletes the kind cluster (laptop: k3s-uninstall.sh on the host)"; exit 1; }
kind delete cluster --name gitops
rm -rf "$SECRETS"

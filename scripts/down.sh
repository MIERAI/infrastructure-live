#!/usr/bin/env bash
# 删除本地的平台(集群和里面的一切)
set -euo pipefail
cd "$(dirname "$0")/.."
kind delete cluster --name gitops
rm -rf .secrets

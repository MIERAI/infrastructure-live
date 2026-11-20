# Sourced by every script: which cluster to act on.
#   TARGET=kind   (default) local kind cluster (tofu/kind), context kind-gitops, apps on localhost:18080-18083
#   TARGET=laptop k3s on the always-on laptop (kubeconfig ~/.kube/laptop.yaml, written by ansible/), apps on <laptop>:30080-30083
#   TARGET=demo   the demo cluster anyone can build (tofu/demo), context kind-gitops-demo, apps on localhost:28080-28083
# kubectl always gets an explicit --context: the scripts never act on whatever context happens to be current
# (it could be a company cluster) and never change it.
# shellcheck shell=bash
export TARGET=${TARGET:-kind}
case $TARGET in
  kind)   export KUBECONFIG=${KIND_KUBECONFIG:-$HOME/.kube/kind-gitops.yaml}   # written by tofu/kind
          KCTX=kind-gitops; ROOT_PATH=apps; HOST=localhost ;;
  laptop) export KUBECONFIG=${LAPTOP_KUBECONFIG:-$HOME/.kube/laptop.yaml}
          KCTX=laptop; ROOT_PATH=clusters/laptop; HOST=${LAPTOP_HOST:-100.90.245.89} ;;
  demo)   export KUBECONFIG=${DEMO_KUBECONFIG:-$HOME/.kube/gitops-demo.yaml}   # written by tofu/demo
          KCTX=kind-gitops-demo; ROOT_PATH=clusters/demo; HOST=localhost ;;
  *) echo "unknown TARGET=$TARGET (kind | laptop | demo)" >&2; exit 2 ;;
esac
SECRETS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.secrets/$TARGET
export KCTX ROOT_PATH HOST SECRETS
kubectl() { command kubectl --context "$KCTX" "$@"; }
# app_url api-factory-dev → http://localhost:18080 (kind) / http://<laptop>:30080
app_url() {
  local p
  case $1 in
    api-factory-dev) p=30080 ;; api-factory-prod) p=30081 ;; sample-app-dev) p=30082 ;; sample-app-prod) p=30083 ;;
    *) return 1 ;;
  esac
  [ "$TARGET" = kind ] && p=$((p - 12000))
  [ "$TARGET" = demo ] && p=$((p - 2000))
  echo "http://$HOST:$p"
}

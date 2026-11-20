# Demo: the platform on your machine

The whole platform on a local [kind](https://kind.sigs.k8s.io) cluster, **without any of our keys, tokens or
accounts**: Argo CD syncs [gitops-manifests](https://github.com/MIERAI/gitops-manifests) (`clusters/demo`) — the
platform (Kyverno admission policies, Argo Rollouts, CloudNativePG, Prometheus/Grafana, object storage) and every
public application: `sample-app` (canary releases) and `storefront` (a monorepo: three services, kustomize + Helm,
dev → staging → prod). Private applications (api-factory) are left out.

## Run

Needs: Docker (≈ 6 GB of memory for it), [OpenTofu](https://opentofu.org) ≥ 1.10, kubectl. macOS or Linux.

```sh
git clone https://github.com/MIERAI/infrastructure-live && cd infrastructure-live
tofu -chdir=tofu/demo init
tofu -chdir=tofu/demo apply          # ~2 min: kind cluster + Argo CD; then Argo CD deploys the rest
export KUBECONFIG=~/.kube/gitops-demo.yaml
TARGET=demo scripts/wait-synced.sh --healthy --timeout 900   # every Application Synced / Healthy (~5–10 min)
```

## Look around

| What | How |
|---|---|
| Every application, its sync and health | `kubectl -n argocd get applications` |
| sample-app dev / prod | `curl localhost:28082/hello`, `curl localhost:28083/hello` |
| storefront (web → api) | `kubectl -n storefront-dev port-forward svc/web 8081:8080` → http://localhost:8081 |
| Argo CD UI | `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080, user `admin`, password in `.secrets/gitops-demo/argocd-admin.password` |
| Grafana | `kubectl -n monitoring port-forward svc/kps-grafana 3000:80` → http://localhost:3000, `admin` / `.secrets/gitops-demo/grafana-admin.password` |
| The admission policies at work | `kubectl -n storefront-dev run x --image=nginx` → rejected (no resources, no probe, root user…) |

## Change things: your fork

The cluster above syncs **our** repository. To change it and watch Argo CD follow:

1. Fork [gitops-manifests](https://github.com/MIERAI/gitops-manifests); in your fork: `scripts/fork.sh <your GitHub
   user>`, commit, push.
2. `tofu -chdir=tofu/demo apply -var manifests_repo=https://github.com/<you>/gitops-manifests.git`
3. Commit to your fork, e.g. `sample-app/overlays/prod`: replicas → Argo CD syncs within ~30 s. A new application =
   a new directory with an `app.yaml` (see `storefront/app.yaml`).

## Remove

`tofu -chdir=tofu/demo destroy` (deletes the kind cluster; the state and `.secrets/gitops-demo` stay local).

Ports or name clash with something you run? `-var host_port_base=38080 -var cluster_name=other`.

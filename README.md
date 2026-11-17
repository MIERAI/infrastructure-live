# infrastructure-live

> Part of the [GitOps Platform Blueprint](https://github.com/MIERAI/gitops-platform-blueprint)

The platform layer: a Kubernetes cluster, Argo CD, and the runtime secrets. After `up.sh`, everything that runs in the
cluster is defined by [gitops-manifests](https://github.com/MIERAI/gitops-manifests) — this repository only bootstraps the control plane.

Today the cluster is **local (kind)**. The GKE version (Terraform: VPC, GKE, Cloud SQL, Workload Identity) will replace
`kind/` without changing the delivery flow.

## Layout

| Path | What |
|---|---|
| `kind/cluster.yaml` | Local cluster; NodePorts 30080–30083 → localhost 18080–18083 |
| `argocd/` | Argo CD from the pinned upstream manifest (v3.5.6) + local settings (30s Git polling, plain HTTP UI) |
| `bootstrap/root.yaml` | Root Application (app of apps) → `gitops-manifests/apps` |
| `scripts/up.sh` / `down.sh` | Create / delete the platform |
| `scripts/secrets.sh` | Runtime secrets, generated locally and **never committed** (image pull secret, database password, API token) |

## Usage

```sh
scripts/up.sh
kubectl get applications -n argocd               # root + api-factory-{dev,prod} + sample-app-{dev,prod}
kubectl -n argocd port-forward svc/argocd-server 8443:80    # UI: http://127.0.0.1:8443 (user admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
scripts/down.sh
```

Requirements: docker, kind, kubectl, gh (the GHCR pull secret uses `gh auth token`; the token needs `read:packages`).

| Endpoint | URL |
|---|---|
| sample-app dev / prod | `http://localhost:18082/hello`, `http://localhost:18083/hello` |
| api-factory dev / prod | `http://localhost:18080`, `http://localhost:18081` (Connect; `Authorization: Bearer $(cat .secrets/api-factory-dev.token)`) |

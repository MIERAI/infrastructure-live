# Demo: the platform on your machine

The whole platform on a local [kind](https://kind.sigs.k8s.io) cluster, **without any of our keys, tokens or
accounts**: Argo CD syncs [gitops-manifests](https://github.com/MIERAI/gitops-manifests) (`clusters/demo`) — the
platform (Kyverno admission policies, Argo Rollouts, CloudNativePG, Prometheus/Grafana, object storage) and every
public application: `sample-app` (canary releases) and `storefront` (a monorepo: three services, kustomize + Helm,
dev → staging → prod). Private applications (api-factory) are left out.

## Run

Needs: Docker with ≈ 8 GB of memory (the cluster uses ≈ 5.5 GB), [OpenTofu](https://opentofu.org) ≥ 1.10, kubectl. macOS or Linux.

```sh
git clone https://github.com/MIERAI/infrastructure-live && cd infrastructure-live
tofu -chdir=tofu/demo init
tofu -chdir=tofu/demo apply          # ~1 min: kind cluster + Argo CD; then Argo CD deploys the rest
export KUBECONFIG=~/.kube/gitops-demo.yaml
TARGET=demo scripts/wait-synced.sh --healthy --timeout 900   # 16 Applications Synced / Healthy (~3–5 min)
```

## Look around

| What | How |
|---|---|
| Every application, its sync and health | `kubectl -n argocd get applications` |
| sample-app dev / prod | `curl localhost:28082/hello`, `curl localhost:28083/hello` |
| storefront (web → api) | `kubectl -n storefront-dev port-forward svc/web 8081:8080` → http://localhost:8081 |
| Argo CD UI | `kubectl -n argocd port-forward svc/argocd-server 8080:80` → http://localhost:8080, user `admin`, password in `.secrets/gitops-demo/argocd-admin.password` |
| Grafana | `kubectl -n monitoring port-forward svc/platform-monitoring-grafana 3000:80` → http://localhost:3000, `admin` / `.secrets/gitops-demo/grafana-admin.password` |
| The admission policies at work | `kubectl -n storefront-dev run x --image=nginx` → rejected (no readiness probe, no resources, root user…) |

## Change things: your fork

The cluster above syncs **our** repository. To change it and watch Argo CD follow:

1. Fork [gitops-manifests](https://github.com/MIERAI/gitops-manifests) (keep the name); in your fork:
   `scripts/fork.sh <your GitHub user or organization>`, commit, push.
2. `tofu -chdir=tofu/demo apply -var manifests_repo=https://github.com/<you>/gitops-manifests.git`
3. Commit to your fork, e.g. `sample-app/overlays/prod`: replicas → Argo CD syncs within ~30 s. A new application =
   a new directory with an `app.yaml` (see `storefront/app.yaml`).

## Release your own code: the whole flow

Your code → test → image in **your** GHCR (signed) → your dev → promote → your prod. Steps 1–2 above first, then:

1. Fork [sample-app](https://github.com/MIERAI/sample-app) (keep the name).
2. In **both** forks, open the Actions tab and click *I understand my workflows, go ahead and enable them* (GitHub does
   not run the workflows of a fork until then; there is no API for it).
3. Let the sample-app fork write to your gitops-manifests (a deploy key: that one repository only):
   ```sh
   ssh-keygen -t ed25519 -N '' -C ci-promote -f /tmp/deploy
   gh repo deploy-key add /tmp/deploy.pub -R <you>/gitops-manifests --allow-write --title ci-promote
   gh secret set MANIFESTS_DEPLOY_KEY -R <you>/sample-app < /tmp/deploy && rm /tmp/deploy /tmp/deploy.pub
   ```
4. Let the promote workflow open pull requests:
   `gh api -X PUT repos/<you>/gitops-manifests/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true`
5. Change sample-app (e.g. the greeting in `main.go` and its test), push to `main` (or Actions → ci → Run workflow).
   CI: test → `ghcr.io/<you>/sample-app:<commit>` (signed) → commits it to your `sample-app/overlays/dev`. The entry
   switches to your image (`newName`); the other environments keep running ours until you promote.
6. Your image must be **public** for the demo cluster to pull it (it has no token): under a user account, a package
   built from a public repository is public; under an organization it is private — package settings → *Change
   visibility* → Public. Within ~5 min: `curl localhost:28082/hello` shows your change (canary + analysis on the way).
7. Promote: your gitops-manifests → Actions → promote → app `sample-app` → it opens a PR (version must have run 10 min
   in dev) → merge → `curl localhost:28083/hello`.

**Forking into an organization** — new organizations block what the flow needs; an owner allows it once in the
organization's settings: *Actions → General → Workflow permissions*: allow GitHub Actions to create pull requests;
*Deploy keys*: enabled; *Packages → Package creation*: Public; and, to use the `gh` commands above, *Third-party
access*: grant GitHub CLI. Under a user account none of this is needed.

Tested end to end with a fork in a separate organization (2026-11-20): every step above, in this order.

## Remove

`tofu -chdir=tofu/demo destroy` (deletes the kind cluster; the state and `.secrets/gitops-demo` stay local).

Ports or name clash with something you run? `-var host_port_base=38080 -var cluster_name=other`.

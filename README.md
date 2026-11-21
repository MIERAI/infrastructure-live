# infrastructure-live

> Bootstraps the clusters that run [slo-platform](https://github.com/MIERAI/slo-platform): k3s on the hosts, Argo CD,
> runtime secrets and the root Application that points at slo-platform. Design principles and shared CI:
> [GitOps Platform Blueprint](https://github.com/MIERAI/gitops-platform-blueprint).

The platform layer: the hosts, the Kubernetes clusters, Argo CD and the runtime secrets. Everything that runs in the
clusters after that comes from slo-platform (the product, at the version pinned in `tofu/<cluster>/main.tf`) and
[gitops-manifests](https://github.com/MIERAI/gitops-manifests) (its instance: `platform.yaml`, the applications and our
extras).

Infrastructure as code with open-source tools only; no bootstrap shell scripts:

| Layer | Tool | Where |
|---|---|---|
| Hosts (the always-on laptop: backup disk, k3s, object store, CI runner; xiaoxin: k3s; the phone: off-site target, watcher) | **Ansible** (k3s via the official [k3s-ansible](https://github.com/k3s-io/k3s-ansible)) | `ansible/` |
| Clusters + platform (Argo CD, runtime secrets, root application; kind for the demo) | **OpenTofu** | `tofu/` |
| Secrets (one source for both) | **SOPS + age**, encrypted in Git | `secrets/*.sops.yaml` |
| Everything in the clusters | Argo CD | gitops-manifests |

Two real clusters, both k3s at home: `laptop` (prod, the always-on HP laptop) and `lab` (xiaoxin: fault experiments
and slo-platform's daily regression). Their root Application is slo-platform's (`slo_platform` in `tofu/laptop` and
`tofu/lab`); `slo_platform = null` brings back the old root (gitops-manifests `clusters/<name>`), kept as the rollback
path for a week after the switch. There is no cloud code here: a managed-cloud version (GKE, Workload Identity, Secret
Manager) is only an idea for later, not something started.

## Try it: the demo

Anyone can run the platform locally, without our keys or tokens: [`tofu/demo`](tofu/demo/README.md) (one command;
the platform and every public application). CI runs exactly that every week and on every change.

## Layout

| Path | What |
|---|---|
| `tofu/modules/platform` | Argo CD (Helm chart, pinned), namespaces + runtime secrets, root application (argocd-apps chart): slo-platform's when `slo_platform` is set, else the manifests repo's `root_path` |
| `tofu/kind` | Local kind cluster (NodePorts 30080–30083 → localhost 18080–18083) + platform; kubeconfig `~/.kube/kind-gitops.yaml` |
| `tofu/laptop` | Platform on the laptop's k3s (kubeconfig `~/.kube/laptop.yaml` from Ansible); root: slo-platform, cluster `laptop` |
| `tofu/lab` | The lab cluster: platform on xiaoxin's k3s (`~/.kube/xiaoxin.yaml` from Ansible, group `lab`), where the fault experiments run; root: slo-platform, cluster `lab`; small (no Kyverno, no Grafana) |
| `tofu/demo` | The demo anyone can run: kind + platform, throwaway secrets, public applications only (gitops-manifests `clusters/demo`) |
| `ansible/` | `site.yml`: backup disk → k3s → SeaweedFS (S3, outside the cluster) → kubeconfig → GitHub Actions runner; the lab (xiaoxin); the phone: off-site target and `gitops_watch` (watches the laptop and xiaoxin from outside, speaks on the other machine, receives Alertmanager's Watchdog) |
| `secrets/` | `kind.sops.yaml`, `laptop.sops.yaml`: S3 keys, database passwords, API tokens, Grafana admin |
| `scripts/` | Operations only: drills (restore / failover / rebuild), `ui.sh`, `status.sh`, `wait-synced.sh` (`env.sh`: `TARGET=kind\|laptop`) |

## State and keys (never in this public repository)

- OpenTofu state: `~/Library/Application Support/gitops/tofu/<cluster>.tfstate`, **encrypted by OpenTofu** (it holds the
  decrypted secrets). Passphrase: `~/Library/Application Support/gitops/tofu-state.passphrase`.
- SOPS age key: `~/Library/Application Support/sops/age/keys.txt`.
- Back both up outside the workstation: without the age key the secrets cannot be decrypted, without the passphrase
  the state cannot be read (the clusters keep running; the state can be re-imported).

## Usage

```sh
export TF_VAR_ghcr_token=$(gh auth token --user MIERAI)      # GHCR pull secret (read:packages)

# kind (local)
tofu -chdir=tofu/kind init && tofu -chdir=tofu/kind apply
scripts/wait-synced.sh --healthy                            # every Application Synced/Healthy (~5 min)
tofu -chdir=tofu/kind destroy

# laptop: host layer, then platform
(cd ansible && ansible-galaxy collection install -r requirements.yml && ansible-playbook site.yml [--check --diff])
tofu -chdir=tofu/laptop init && tofu -chdir=tofu/laptop apply
#   at home without Tailscale: TF_VAR_kubeconfig=~/.kube/laptop-lan.yaml TF_VAR_kube_context=laptop-lan

# lab (xiaoxin, where the fault experiments run): host layer, then platform
(cd ansible && ansible-playbook site.yml --limit lab)
tofu -chdir=tofu/lab init && tofu -chdir=tofu/lab apply

# secrets: edit (decrypts in $EDITOR, re-encrypts on save), then apply (tofu: Kubernetes secrets; ansible: host)
sops secrets/laptop.sops.yaml
```

Requirements: docker, kubectl, gh, `brew install opentofu ansible sops age`. The k3s.orchestration server role restarts
k3s on every playbook run (~30 s without API; pods keep running).

| Endpoint | URL |
|---|---|
| sample-app dev / prod | `http://localhost:18082/hello`, `http://localhost:18083/hello` (laptop: `<laptop>:30082/30083`) |
| api-factory dev / prod | `http://localhost:18080`, `:18081` (Connect; `Authorization: Bearer $(cat .secrets/kind/api-factory-dev.token)`) |

UIs: `scripts/ui.sh` (Argo CD / Grafana / Prometheus / Rollouts; passwords in `.secrets/<cluster>/`, written by OpenTofu).

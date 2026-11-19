# infrastructure-live

> Part of the [GitOps Platform Blueprint](https://github.com/MIERAI/gitops-platform-blueprint)

The platform layer: the hosts, the Kubernetes clusters, Argo CD and the runtime secrets. Everything that runs in the
clusters after that is defined by [gitops-manifests](https://github.com/MIERAI/gitops-manifests).

Infrastructure as code with open-source tools only; no bootstrap shell scripts:

| Layer | Tool | Where |
|---|---|---|
| Hosts (the always-on laptop: backup disk, k3s, object store, CI runner) | **Ansible** (k3s via the official [k3s-ansible](https://github.com/k3s-io/k3s-ansible)) | `ansible/` |
| Clusters + platform (kind cluster; Argo CD, runtime secrets, root application) | **OpenTofu** | `tofu/` |
| Secrets (one source for both) | **SOPS + age**, encrypted in Git | `secrets/*.sops.yaml` |
| Everything in the clusters | Argo CD | gitops-manifests |

The GKE version replaces `tofu/kind` (VPC, GKE, Workload Identity, Secret Manager) without changing the delivery flow;
the laptop's Ansible layer then disappears (cloud hosts are created by OpenTofu).

## Layout

| Path | What |
|---|---|
| `tofu/modules/platform` | Argo CD (Helm chart, pinned), namespaces + runtime secrets, root application (argocd-apps chart) |
| `tofu/kind` | Local kind cluster (NodePorts 30080–30083 → localhost 18080–18083) + platform; kubeconfig `~/.kube/kind-gitops.yaml` |
| `tofu/laptop` | Platform on the laptop's k3s (kubeconfig `~/.kube/laptop.yaml` from Ansible) |
| `ansible/` | `site.yml`: backup disk → k3s → SeaweedFS (S3, outside the cluster) → kubeconfig → GitHub Actions runner |
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

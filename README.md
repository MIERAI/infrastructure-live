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
| Hosts (the always-on laptop: backup disk, k3s with API audit log, object store, CI runner; xiaoxin: k3s, key-only ssh; the phone: off-site target, watcher, dashboards for the laptop Grafana, detection alerting) | **Ansible** (k3s via the official [k3s-ansible](https://github.com/k3s-io/k3s-ansible)) | `ansible/` |
| Clusters + platform (Argo CD, runtime secrets, root application; kind for the demo) | **OpenTofu** | `tofu/` |
| Secrets (one source for both) | **SOPS + age**, encrypted in Git | `secrets/*.sops.yaml` |
| Everything in the clusters | Argo CD | gitops-manifests |

Two real clusters, both k3s at home: `laptop` (prod, the always-on HP laptop) and `lab` (xiaoxin: fault experiments
and slo-platform's daily regression). Their root Application is slo-platform's (`slo_platform` in `tofu/laptop` and
`tofu/lab`); `slo_platform = null` brings back the old root (gitops-manifests `clusters/<name>`), kept as the rollback
path for a week after the switch (2026-11-21). There is no cloud code here: a managed-cloud version (GKE, Workload
Identity, Secret Manager) is only an idea for later, not something started.

## Try it: the demo

Anyone can run the platform locally, without our keys or tokens: [`tofu/demo`](tofu/demo/README.md) (one command;
the platform and every public application). CI runs exactly that every week and on every change.

## Layout

| Path | What |
|---|---|
| `tofu/modules/platform` | Argo CD (Helm chart, pinned), namespaces + runtime secrets (api-factory, `backup-s3` for `backup_namespaces`, Grafana admin, off-site backup, delivery board, the phone's auth-proxy tokens `phone-auth-*`), root application (argocd-apps chart): slo-platform's when `slo_platform` is set, else the manifests repo's `root_path` |
| `tofu/kind` | Local kind cluster (NodePorts 30080–30083 → localhost 18080–18083) + platform; kubeconfig `~/.kube/kind-gitops.yaml` |
| `tofu/laptop` | Platform on the laptop's k3s (kubeconfig `~/.kube/laptop.yaml` from Ansible); root: slo-platform, cluster `laptop` |
| `tofu/lab` | The lab cluster: platform on xiaoxin's k3s (`~/.kube/xiaoxin.yaml` from Ansible, group `lab`), where the fault experiments run; root: slo-platform, cluster `lab`; small (no Kyverno, no Grafana); secrets: `kind.sops.yaml` (throwaway, nothing shared with the laptop); api-factory dev only |
| `tofu/demo` | The demo anyone can run: kind + platform, throwaway secrets, public applications only (gitops-manifests `clusters/demo`) |
| `ansible/` | `site.yml`: the laptop (backup disk → k3s → SeaweedFS (S3, outside the cluster) → kubeconfig → GitHub Actions runner); the lab (xiaoxin); the phone (off-site target, `gitops_watch`, `phone_dashboards`, `detection_alerting`). Plays, tags and checks: [What runs where](#what-runs-where) |
| `secrets/` | `kind.sops.yaml` (kind and the lab), `laptop.sops.yaml`: S3 keys, database passwords, API tokens, Grafana admin; laptop also: off-site backup (`offsite`), delivery board (`delivery_board`); both: the phone's auth-proxy tokens (`phone_auth`) |
| `scripts/` | Operations only: drills (restore / failover / rebuild: kind only), `ui.sh`, `status.sh`, `wait-synced.sh` (`env.sh`: `TARGET=kind\|laptop\|demo`; there is no `lab` target) |

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

# laptop: host layer, then platform (site.yml without --limit runs every host: laptop, lab and phone)
(cd ansible && ansible-galaxy collection install -r requirements.yml \
  && ansible-playbook site.yml --limit laptop [--check --diff])
tofu -chdir=tofu/laptop init && tofu -chdir=tofu/laptop apply
#   at home without Tailscale: TF_VAR_kubeconfig=~/.kube/laptop-lan.yaml TF_VAR_kube_context=laptop-lan

# lab (xiaoxin, where the fault experiments run): host layer, then platform
(cd ansible && ansible-playbook site.yml --limit lab)
tofu -chdir=tofu/lab init && tofu -chdir=tofu/lab apply

# the phone (off-site target, watcher, dashboards, detection alerting)
(cd ansible && ansible-playbook site.yml --limit offsite)

# secrets: edit (decrypts in $EDITOR, re-encrypts on save), then apply (tofu: Kubernetes secrets; ansible: host)
sops secrets/laptop.sops.yaml
```

Requirements: docker, kubectl, gh, `brew install opentofu ansible sops age`. The k3s.orchestration server role restarts
k3s on every playbook run that includes the k3s play or the lab play (~30 s without API; pods keep running; not with
`--check`).

A new cluster: `phone-auth-logs` (namespace `log-shipping`) and `phone-auth-traces` (`phone_traces_namespaces`) go into
namespaces that Argo CD creates, so the first `tofu apply` reports them as errors; run `tofu apply` again once the
Applications have synced.

| Endpoint | URL |
|---|---|
| sample-app dev / prod | `http://localhost:18082/hello`, `http://localhost:18083/hello` (laptop: `<laptop>:30082/30083`) |
| api-factory dev / prod | `http://localhost:18080`, `:18081` (Connect; `Authorization: Bearer $(cat .secrets/kind/api-factory-dev.token)`) |

UIs: `scripts/ui.sh` (Argo CD / Grafana / Prometheus / Rollouts; passwords in `.secrets/<cluster>/`, written by OpenTofu).

## What runs where

`ansible/site.yml`, one play per row, in this order. Inventory: `ansible/inventory.yml`; variables:
`ansible/group_vars/<group>.yml`. Run one part with `--limit <host or group>` and/or `--tags <tag>`.

| Host (group) | Play | Tag | What it does |
|---|---|---|---|
| laptop (`server`) | Backup disk | `disk` | mounts the HDD (`backup_disk_uuid`) on `/srv/backups`, `nofail` |
| laptop (`server`) | k3s | `k3s` | k3s install script; containerd's AppArmor profile (`files/cri-containerd.apparmor.d`, Ubuntu 26.04 / AppArmor 5: containers may signal their own processes); API audit policy (`files/k8s-audit-policy.yaml` → `/etc/rancher/k3s/audit-policy.yaml`, log `/var/lib/rancher/k3s/server/logs/audit.log`, flags in `group_vars/server.yml`); k3s `k3s_version` (**restarts k3s**) |
| laptop (`server`) | Object storage | `seaweedfs` | SeaweedFS `seaweedfs_version` as a systemd service on the k3s bridge (`seaweedfs_bind`), S3 identity from SOPS, bucket `cnpg` |
| laptop (`server`) | Kubeconfig | `kubeconfig` | `~/.kube/laptop.yaml` on the workstation, names `laptop` |
| laptop (`server`) | GitHub Actions runner | `runner` | runner `gh_runner_version` for the private `gh_runner_repo` only (refuses a public one); needs `gh` logged in on the workstation |
| xiaoxin (`lab`) | Lab cluster | `lab` | inotify limits, the same AppArmor profile, key-only sshd (`/etc/ssh/sshd_config.d/10-key-only.conf`, validated), the same audit policy, k3s (`group_vars/lab.yml`: own `server_group`, node labels, memory reservation; **restarts k3s**), kubeconfig `~/.kube/xiaoxin.yaml` |
| phone (`offsite`) | Off-site backup target | `offsite` | `~/backups/gitops` and an sftp-only key for the laptop cluster's off-site CronJob |
| phone (`offsite`) | Watcher | `watch` | `gitops_watch` (`roles/gitops_watch/files/watch.py`): checks in `gitops_watch_config` (laptop, its Watchdog, xiaoxin, the lab API and its Watchdog, Gatus, winpc and its prober), `POST /notify` (Gatus), `POST /alertmanager` (detection pages); speaks on the other machine; `:9195` (`/status`, `/metrics`) |
| phone (`offsite`) | Dashboards | `dashboards` | the phone Grafana's dashboards → ConfigMaps `phone-dashboard-*` in the laptop's `monitoring` (server-side apply from the workstation; needs kubectl and `~/.kube/laptop.yaml`) |
| phone (`offsite`) | Detection alerting | `detection` | Alertmanager `alertmanager_version` (checksum-verified) on `127.0.0.1:9093`, Loki's ruler (managed block in `~/loki/loki.yaml`, verified before use, Loki restarted), the detection rules from `detection_rules_file`; `severity=page` → the watcher (`detection_page_webhook`), the lab recorded only |

Not managed here: the phone's Loki, Tempo, Prometheus servers, Grafana, Gatus, the auth proxy and `~/services.sh` are
installed by hand on the phone; `detection_alerting` expects `~/loki` (binary + `loki.yaml`) and `~/services.sh`.
`detection_rules_file` defaults to a file rendered by security-platform in the operator's private data directory (it
names accounts, so it is never committed): without it the `detection` play fails; point it elsewhere with
`-e detection_rules_file=<path>`. The phone's processes are started by Termux:Boot (`~/.termux/boot/30-gitops-watch`,
`31-detection`) and brought back every 15 min by JobScheduler (job ids `gitops_watch_job_id` 30, `detection_job_id` 31).
The laptop's key-only sshd settings are its own drop-in, also not managed here (the lab's is).

```sh
cd ansible
ansible-playbook site.yml --limit laptop --check --diff          # dry run first (no k3s restart in check mode)
ansible-playbook site.yml --limit laptop --tags seaweedfs         # one part
ansible-playbook site.yml --limit lab                             # the lab
ansible-playbook site.yml --limit offsite --tags watch,detection  # the phone, some parts
```

Verify:

| What | How |
|---|---|
| clusters | `kubectl --kubeconfig ~/.kube/laptop.yaml --context laptop get nodes` (lab: `~/.kube/xiaoxin.yaml`, `xiaoxin`); platform: `TARGET=laptop scripts/wait-synced.sh --healthy` |
| audit log | `ssh <host> sudo tail -n1 /var/lib/rancher/k3s/server/logs/audit.log` |
| AppArmor profile | `ssh <host> sudo aa-status \| grep cri-containerd` |
| key-only ssh (lab) | `ssh xiaoxin sudo sshd -T \| grep -E '^(passwordauthentication\|permitrootlogin)'` |
| SeaweedFS | `ssh laptop systemctl is-active seaweedfs` |
| runner | `gh api repos/<gh_runner_repo>/actions/runners --jq '.runners[] \| {name, status}'` |
| watcher | `ssh phone curl -s 127.0.0.1:9195/status` |
| detection Alertmanager | `ssh phone curl -sf 127.0.0.1:9093/-/ready`; alerts: `ssh phone curl -s 127.0.0.1:9093/api/v2/alerts` |
| dashboards | `kubectl --kubeconfig ~/.kube/laptop.yaml --context laptop -n monitoring get cm -l gitops-platform/source=phone` |

Roll back: revert the change in Git and rerun the same `--limit`/`--tags` (OpenTofu: revert and `tofu apply`; the
platform's root: `slo_platform = null`, above). Ansible does not delete what a reverted task had created; remove those
by hand:

- audit log: the `kube-apiserver-arg` lines in `group_vars/<group>.yml` (rerun restarts k3s); the policy file may stay.
- sshd drop-in (lab): delete `/etc/ssh/sshd_config.d/10-key-only.conf`, `systemctl reload ssh`.
- detection alerting: remove the managed ruler block from `~/loki/loki.yaml` (`blockinfile` keeps a dated backup next
  to it) and restart Loki; stop Alertmanager (`kill $(cat ~/detection/alertmanager.pid)`), delete
  `~/.termux/boot/31-detection`, `termux-job-scheduler --cancel --job-id 31`.
- watcher: the same with `~/gitops-watch/watch.pid`, `~/.termux/boot/30-gitops-watch`, job id 30.
- dashboards: `kubectl -n monitoring delete cm -l gitops-platform/source=phone` (no Argo CD Application owns them).
- runner: see the comment at the top of `roles/gh_runner/tasks/main.yml`.

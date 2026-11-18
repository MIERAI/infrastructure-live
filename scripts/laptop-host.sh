#!/usr/bin/env bash
# Host layer of the laptop cluster ("the cloud"), run from the workstation over ssh. Idempotent.
#   LAPTOP_SSH=laptop BACKUP_UUID=<ext4 uuid> scripts/laptop-host.sh
# 1. backup disk mounted on /srv/backups (fstab by UUID, nofail) — optional: without BACKUP_UUID the root disk is used
# 2. k3s (pinned), traefik off (apps use NodePorts), API certificate valid for the LAN / Tailscale address
# 3. SeaweedFS (S3) as a systemd service OUTSIDE the cluster: data on /srv/backups, bound to the k3s bridge
#    10.42.0.1 (reachable from Pods, not from the LAN); credentials from .secrets/laptop; bucket "cnpg"
# 4. kubeconfig → ~/.kube/laptop.yaml (separate file: ~/.kube/config is never touched)
# Then: TARGET=laptop scripts/up.sh
# shellcheck disable=SC2029  # values are expanded on this side on purpose and sent to the host
set -euo pipefail
cd "$(dirname "$0")/.."
export TARGET=laptop
# shellcheck source=scripts/env.sh
. scripts/env.sh
SSH=${LAPTOP_SSH:-laptop}
K3S_VERSION=v1.36.5+k3s1
WEED_VERSION=4.51
mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
[ -f "$SECRETS/s3-access-key" ] || { openssl rand -hex 24 > "$SECRETS/s3-access-key"; openssl rand -hex 24 > "$SECRETS/s3-secret-key"; }

echo "━━ backup disk"
if [ -n "${BACKUP_UUID:-}" ]; then
  ssh "$SSH" "sudo mkdir -p /srv/backups
    grep -q $BACKUP_UUID /etc/fstab || echo 'UUID=$BACKUP_UUID /srv/backups ext4 defaults,nofail,noatime 0 2' | sudo tee -a /etc/fstab >/dev/null
    sudo systemctl daemon-reload; mountpoint -q /srv/backups || sudo mount /srv/backups; df -h /srv/backups | tail -1"
else
  ssh "$SSH" 'sudo mkdir -p /srv/backups; echo "(no BACKUP_UUID: /srv/backups on the root disk)"'
fi

echo "━━ k3s $K3S_VERSION"
LAN=$(ssh -G "$SSH" | awk '/^hostname /{print $2}')
ssh -T "$SSH" "set -e
  sudo mkdir -p /etc/rancher/k3s
  printf '%s\n' 'disable: [traefik]' 'write-kubeconfig-mode: \"0644\"' 'tls-san: [$HOST, $LAN, $SSH]' | sudo tee /etc/rancher/k3s/config.yaml.new >/dev/null
  changed=0; sudo cmp -s /etc/rancher/k3s/config.yaml.new /etc/rancher/k3s/config.yaml || changed=1
  sudo mv /etc/rancher/k3s/config.yaml.new /etc/rancher/k3s/config.yaml
  if [ \"\$(k3s --version 2>/dev/null | head -1 | awk '{print \$3}')\" != '$K3S_VERSION' ]; then
    curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && INSTALL_K3S_VERSION='$K3S_VERSION' sh /tmp/k3s-install.sh >/dev/null
  elif [ \$changed = 1 ]; then
    sudo systemctl restart k3s; echo 'k3s config changed: restarted'
  fi
  for i in \$(seq 1 60); do sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && ip -4 addr show cni0 >/dev/null 2>&1 && break; sleep 3; done
  k3s --version | head -1"

echo "━━ object storage (SeaweedFS $WEED_VERSION, outside the cluster)"
printf '{"identities":[{"name":"cnpg","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' \
  "$(cat "$SECRETS/s3-access-key")" "$(cat "$SECRETS/s3-secret-key")" |
  ssh "$SSH" 'sudo install -d -m 700 /etc/seaweedfs && sudo tee /etc/seaweedfs/s3.json.new >/dev/null && sudo chmod 600 /etc/seaweedfs/s3.json.new
    if sudo cmp -s /etc/seaweedfs/s3.json.new /etc/seaweedfs/s3.json; then sudo rm /etc/seaweedfs/s3.json.new; else sudo mv /etc/seaweedfs/s3.json.new /etc/seaweedfs/s3.json; sudo systemctl try-restart seaweedfs; fi'
ssh -T "$SSH" "set -e
  if ! /usr/local/bin/weed version 2>/dev/null | grep -q ' $WEED_VERSION '; then
    cd /tmp && curl -fsSL -o weed.tgz https://github.com/seaweedfs/seaweedfs/releases/download/$WEED_VERSION/linux_amd64.tar.gz
    tar xzf weed.tgz weed && sudo install -m 755 weed /usr/local/bin/weed && rm -f weed weed.tgz
  fi
  sudo install -d -m 700 /srv/backups/gitops-objects
  sudo tee /etc/systemd/system/seaweedfs.service >/dev/null <<'UNIT'
[Unit]
Description=SeaweedFS S3 for cluster backups (outside the k3s cluster; data on /srv/backups)
After=k3s.service network-online.target
Wants=network-online.target
RequiresMountsFor=/srv/backups

[Service]
# Bound to the k3s bridge (cni0): reachable from Pods, not from the LAN. Restarts until cni0 exists after boot.
ExecStart=/usr/local/bin/weed server -dir=/srv/backups/gitops-objects -ip=10.42.0.1 -ip.bind=10.42.0.1 -volume.max=0 -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload && sudo systemctl enable --now seaweedfs >/dev/null 2>&1
  ws() { echo \"\$1\" | weed shell -master=10.42.0.1:9333 2>&1; }
  for i in \$(seq 1 30); do ws s3.bucket.list | grep -q 'cannot connect' || break; sleep 2; done
  ws s3.bucket.list | grep -qE '^\s*cnpg\s' || ws 's3.bucket.create -name cnpg' >/dev/null
  ws s3.bucket.list | grep -E '^\s*cnpg\s' | sed 's/^/bucket: /'"

echo "━━ kubeconfig → $KUBECONFIG"
ssh "$SSH" 'sudo cat /etc/rancher/k3s/k3s.yaml' |
  sed -e "s#https://127.0.0.1:6443#https://$HOST:6443#" -e 's/: default$/: laptop/' > "$KUBECONFIG.new"
chmod 600 "$KUBECONFIG.new" && mv "$KUBECONFIG.new" "$KUBECONFIG"
kubectl get nodes --no-headers

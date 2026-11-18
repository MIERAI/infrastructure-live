#!/usr/bin/env bash
# GitHub Actions self-hosted runner on the laptop, for the PRIVATE repo MIERAI/api-factory only (spec review +
# generation with winpc's model, which only machines in the tailnet can reach). Run from the workstation. Idempotent.
#   scripts/laptop-runner.sh
# What it changes on the laptop:
#   - apt: git, docker.io, nodejs, npm (docker: the factory's acceptance tests start a Postgres container)
#   - user `ghrunner` (no sudo) in group docker — NOTE: docker group = root on that machine; acceptable only because the
#     runner serves a private repo that only the owner can push to. Never register it on a public repository
#     (a fork's pull request could run arbitrary code here).
#   - Claude Code CLI in ghrunner's home (~/.npm-global), used as the harness for the `local` model (winpc's Ollama)
#   - actions-runner (pinned) in /home/ghrunner/actions-runner, labels laptop, as a systemd service
# Undo: sudo /home/ghrunner/actions-runner/svc.sh uninstall; remove the runner in the repo settings; sudo userdel -r ghrunner
set -euo pipefail
SSH=${LAPTOP_SSH:-laptop}
REPO=MIERAI/api-factory
RUNNER_VERSION=2.338.2
GH_TOKEN=$(gh auth token --user "${GH_USER:-MIERAI}"); export GH_TOKEN
[ "$(gh api "repos/$REPO" --jq .private)" = true ] || { echo "✗ $REPO is not private: refusing to attach a self-hosted runner"; exit 1; }

echo "━━ packages + user"
ssh -T "$SSH" 'set -e
  for p in git docker.io nodejs npm; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
  [ -z "${need:-}" ] || { sudo apt-get update -qq >/dev/null; sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need >/dev/null; }
  sudo systemctl enable --now docker >/dev/null 2>&1
  id ghrunner >/dev/null 2>&1 || sudo useradd -m -s /bin/bash ghrunner
  id -nG ghrunner | grep -qw docker || sudo usermod -aG docker ghrunner
  echo "git $(git --version | cut -d" " -f3), docker $(docker --version | cut -d" " -f3 | tr -d ,), node $(node --version)"'

echo "━━ Claude Code CLI (ghrunner)"
ssh -T "$SSH" 'sudo -u ghrunner -H bash -c "set -e
  npm config set prefix ~/.npm-global
  [ -x ~/.npm-global/bin/claude ] || npm install -g --silent @anthropic-ai/claude-code >/dev/null
  ~/.npm-global/bin/claude --version"'

echo "━━ runner $RUNNER_VERSION → $REPO"
if ssh -T "$SSH" 'sudo test -f /home/ghrunner/actions-runner/.runner'; then
  echo "already registered"
else
  token=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
  printf %s "$token" | ssh -T "$SSH" "set -e; tok=\$(cat)
    sudo -u ghrunner -H bash -c 'set -e; mkdir -p ~/actions-runner && cd ~/actions-runner
      [ -x ./config.sh ] || curl -fsSL https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz | tar xz
      ./config.sh --unattended --replace --url https://github.com/$REPO --token \"\$0\" --name laptop --labels laptop --work _work >/dev/null
      echo \"\$PATH:/home/ghrunner/.npm-global/bin\" > .path' \"\$tok\""
fi
# service: its own step (a re-run after a failed install must still install it); svc.sh needs root and the runner dir
ssh -T "$SSH" 'systemctl list-unit-files --no-legend "actions.runner.*" | grep -q . ||
  sudo bash -c "cd /home/ghrunner/actions-runner && ./svc.sh install ghrunner >/dev/null && ./svc.sh start >/dev/null"'
ssh -T "$SSH" 'systemctl list-units --no-legend "actions.runner.*" | awk "{print \$1, \$3, \$4}"'
gh api "repos/$REPO/actions/runners" --jq '.runners[] | "\(.name) \(.status) labels=\([.labels[].name] | join(","))"'

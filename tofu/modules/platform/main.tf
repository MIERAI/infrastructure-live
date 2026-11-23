# The platform on any Kubernetes cluster: Argo CD (Helm) → runtime secrets (from SOPS) → root application.
# Everything after that comes from gitops-manifests (Argo CD reconciles it).
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm" }
    kubernetes = { source = "hashicorp/kubernetes" }
    local      = { source = "hashicorp/local" }
  }
}

locals {
  # api-factory's environments on this cluster: those of the secrets, or the ones var.api_factory_envs names
  api_factory_envs = [for e in nonsensitive(keys(var.secrets.api_factory)) : e if var.api_factory_envs == null || contains(coalesce(var.api_factory_envs, []), e)]

  # applications registered by an app.yaml (gitops-manifests, e.g. storefront) are not listed: Argo CD creates their
  # namespaces and Kyverno clones the pull secret into them from gitops-platform/ghcr-pull
  db_envs        = { for e in local.api_factory_envs : "api-factory-${e}" => var.secrets.api_factory[e] } # none in the demo
  app_namespaces = keys(local.db_envs)                                                                    # only for the runtime secrets written below
  backup_envs    = toset(concat(local.app_namespaces, var.backup_namespaces))                             # backup-s3 only: their login is the operator's
  offsite        = nonsensitive(var.secrets.offsite != null)                                              # only whether the section exists
  board          = nonsensitive(var.secrets.delivery_board != null)
  namespaces     = toset(concat(local.app_namespaces, var.backup_namespaces, ["monitoring", "gitops-platform"], var.in_cluster_object_storage ? ["object-storage"] : [], local.offsite ? ["backup-offsite"] : [], local.board ? ["delivery-board"] : []))
}

# ── Argo CD ──────────────────────────────────────────────────────────────────────────────────────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true
  timeout          = 600
  values = concat([yamlencode({
    fullnameOverride = "argocd" # same object names as the upstream install manifests (argocd-server, …)
    configs = {
      cm     = { "timeout.reconciliation" = "30s" } # no webhook locally: poll Git every 30s
      params = { "server.insecure" = true }         # UI via port-forward, no TLS
    }
    # Argo CD's own NetworkPolicies stay off: kindnet drops all ingress of selected pods in this environment
    global = { networkPolicy = { create = false } }
    })], var.small ? [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
  })] : [])
}

# ── Runtime secrets ─────────────────────────────────────────────────────────────────────────────────────────────────
# The public gitops-manifests only reference them (secretKeyRef). Values: secrets/<cluster>.sops.yaml.
# Namespaces are created here (the secrets must exist before the first sync); Argo CD adds its labels later.
resource "kubernetes_namespace_v1" "ns" {
  for_each = local.namespaces
  metadata { name = each.key }
  lifecycle { ignore_changes = [metadata[0].labels, metadata[0].annotations] }
}

resource "kubernetes_secret_v1" "ghcr_pull" {
  # gitops-platform: the source Kyverno clones into every application namespace (gitops-manifests
  # platform/policies/ghcr-pull.yaml); delivery-board: its own image (a platform namespace, not an application)
  # no token (the demo): no pull secret at all; public images are pulled anonymously
  # pull_secret_in_app_namespaces (no Kyverno to clone it, the lab): the private applications' namespaces too
  for_each = nonsensitive(var.ghcr_token) == "" ? toset([]) : toset(concat(["gitops-platform"], local.board ? ["delivery-board"] : [], var.pull_secret_in_app_namespaces ? local.app_namespaces : []))
  metadata {
    name      = "ghcr-pull"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({ auths = { "ghcr.io" = {
      username = var.ghcr_user
      password = var.ghcr_token
      auth     = base64encode("${var.ghcr_user}:${var.ghcr_token}")
    } } })
  }
  lifecycle { ignore_changes = [data] } # the GitHub token rotates on the workstation; refresh with -replace
}

resource "kubernetes_secret_v1" "seaweedfs_s3" {
  count = var.in_cluster_object_storage ? 1 : 0
  metadata {
    name      = "seaweedfs-s3"
    namespace = kubernetes_namespace_v1.ns["object-storage"].metadata[0].name
  }
  data = {
    "s3.json" = jsonencode({ identities = [{
      name        = "cnpg"
      credentials = [{ accessKey = var.secrets.s3.access_key, secretKey = var.secrets.s3.secret_key }]
      actions     = ["Admin", "Read", "Write", "List", "Tagging"]
    }] })
  }
}

resource "kubernetes_secret_v1" "backup_s3" {
  for_each = local.backup_envs
  metadata {
    name      = "backup-s3"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  data = { ACCESS_KEY_ID = var.secrets.s3.access_key, ACCESS_SECRET_KEY = var.secrets.s3.secret_key }
}

resource "kubernetes_secret_v1" "postgres_app" {
  for_each = local.db_envs
  metadata {
    name      = "postgres-app"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  type = "kubernetes.io/basic-auth"
  data = { username = "factory", password = each.value.db_password }
}

resource "kubernetes_secret_v1" "api_factory" {
  for_each = local.db_envs
  metadata {
    name      = "api-factory"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  # pool_max_conns: 8 per database and pod (pgx default = CPU count: 2 pods x 3 databases x 12 = 72 backends
  # OOM-killed the 512Mi primary in the first load test)
  data = {
    DATABASE_URL      = "postgres://factory:${each.value.db_password}@postgres-rw:5432/factory?sslmode=disable&pool_max_conns=8"
    FACTORY_SHARDS    = "1-2=postgres://factory:${each.value.db_password}@postgres-rw:5432/shard_a?sslmode=disable&pool_max_conns=8;*=postgres://factory:${each.value.db_password}@postgres-rw:5432/shard_b?sslmode=disable&pool_max_conns=8"
    PAGE_TOKEN_KEY    = each.value.page_token_key
    AUTH_TOKEN_SHA256 = sha256(each.value.api_token) # the server only knows the hash
  }
}

# synthetic traffic / load tests need the plain token
resource "kubernetes_secret_v1" "api_token" {
  for_each = local.db_envs
  metadata {
    name      = "api-token"
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }
  data = { token = each.value.api_token }
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.ns["monitoring"].metadata[0].name
  }
  data = { "admin-user" = "admin", "admin-password" = var.secrets.grafana_admin_password }
}

# off-site copy (gitops-manifests platform/offsite-backup): object store → phone, encrypted by rclone crypt
resource "kubernetes_secret_v1" "offsite" {
  count = local.offsite ? 1 : 0
  metadata {
    name      = "offsite-backup"
    namespace = kubernetes_namespace_v1.ns["backup-offsite"].metadata[0].name
  }
  data = {
    S3_ACCESS_KEY   = var.secrets.s3.access_key
    S3_SECRET_KEY   = var.secrets.s3.secret_key
    CRYPT_PASSWORD  = var.secrets.offsite.crypt_password
    CRYPT_SALT      = var.secrets.offsite.crypt_salt
    ssh_private_key = var.secrets.offsite.ssh_private_key
  }
}

# delivery board (MIERAI/delivery-board, deployed by gitops-manifests platform/delivery-board): reads PRs / workflow runs;
# promote_token (optional): starts the promote workflow from the board's button (Actions read/write on gitops-manifests)
resource "kubernetes_secret_v1" "delivery_board" {
  count = local.board ? 1 : 0
  metadata {
    name      = "delivery-board-github"
    namespace = kubernetes_namespace_v1.ns["delivery-board"].metadata[0].name
  }
  data = {
    token         = var.secrets.delivery_board.github_token
    dev_token     = var.secrets.api_factory["dev"].api_token # "try it": live calls of the cases on dev only (read API)
    promote_token = var.secrets.delivery_board.promote_token == null ? "" : var.secrets.delivery_board.promote_token
  }
}

# ── slo-platform as a private repository (private = true; the public product needs none): token for Argo CD + lab ─
resource "kubernetes_secret_v1" "slo_platform_repo" {
  count = var.slo_platform == null ? 0 : (var.slo_platform.private ? 1 : 0)
  metadata {
    name      = "repo-slo-platform"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = { type = "git", url = var.slo_platform.repo, username = "x-access-token", password = var.ghcr_token }
  lifecycle { ignore_changes = [data] } # the GitHub token rotates on the workstation; refresh with -replace
  depends_on = [helm_release.argocd]
}

resource "kubernetes_secret_v1" "slo_platform_git" {
  count = var.slo_platform == null ? 0 : (var.slo_platform.lab && var.slo_platform.private ? 1 : 0)
  metadata {
    name      = "git-credentials"
    namespace = "slo-experiments" # exists on the lab (the regression's namespace)
  }
  data = { token = var.ghcr_token }
  lifecycle { ignore_changes = [data] }
}

# ── Root application (app of apps) ──────────────────────────────────────────────────────────────────────────────────
resource "helm_release" "root" {
  name       = "root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  # slo_platform: the product's root Application (exactly its contract: the product's root chart renders the same object
  # and owns it after the first sync — the release only creates it). Switching from the old root deletes the
  # Application "root" (no finalizer: nothing it managed is deleted); the new root adopts the same-named children.
  values = [var.slo_platform == null ? yamlencode({ applications = { root = {
    namespace   = "argocd"
    project     = "default"
    source      = { repoURL = var.manifests_repo, targetRevision = var.manifests_revision, path = var.root_path }
    destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
    syncPolicy  = { automated = { prune = true, selfHeal = true } }
    } } }) : yamlencode({ applications = { "slo-platform" = {
    namespace = "argocd"
    project   = "default"
    sources = [
      { repoURL = var.slo_platform.repo, targetRevision = var.slo_platform.version, path = "platform/root",
      helm = { valueFiles = ["$instance/platform.yaml"], parameters = [{ name = "cluster", value = var.slo_platform.cluster }] } },
      { repoURL = var.slo_platform.instance_repo, targetRevision = var.slo_platform.instance_revision, ref = "instance" },
    ]
    destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
    syncPolicy  = { automated = { prune = true, selfHeal = true } }
  } } })]
  depends_on = [helm_release.argocd, kubernetes_secret_v1.slo_platform_repo, kubernetes_secret_v1.api_factory, kubernetes_secret_v1.backup_s3,
  kubernetes_secret_v1.ghcr_pull, kubernetes_secret_v1.grafana_admin, kubernetes_secret_v1.seaweedfs_s3, kubernetes_secret_v1.offsite, kubernetes_secret_v1.delivery_board]
}

# ── Local copies for the operator (.secrets/<cluster>/, gitignored): API tokens for callers, UI passwords ────────────
resource "local_sensitive_file" "token" {
  for_each        = local.db_envs
  filename        = "${var.local_secrets_dir}/${each.key}.token"
  content         = each.value.api_token
  file_permission = "0600"
}

resource "local_sensitive_file" "grafana" {
  filename        = "${var.local_secrets_dir}/grafana-admin.password"
  content         = var.secrets.grafana_admin_password
  file_permission = "0600"
}

data "kubernetes_secret_v1" "argocd_admin" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }
  depends_on = [helm_release.argocd]
}

resource "local_sensitive_file" "argocd" {
  filename        = "${var.local_secrets_dir}/argocd-admin.password"
  content         = try(data.kubernetes_secret_v1.argocd_admin.data.password, "")
  file_permission = "0600"
}

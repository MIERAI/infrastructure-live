variable "secrets" {
  description = "Decrypted secrets/<cluster>.sops.yaml (s3, grafana_admin_password, api_factory.{dev,prod})"
  sensitive   = true
  type = object({
    s3                     = object({ access_key = string, secret_key = string })
    grafana_admin_password = string
    api_factory            = map(object({ api_token = string, db_password = string, page_token_key = string })) # {} = none
    # off-site copy of the backups (laptop only): sftp key for the phone, rclone crypt password + salt
    offsite = optional(object({ ssh_private_key = string, crypt_password = string, crypt_salt = string }))
    # delivery board (laptop only): read-only fine-grained GitHub token (api-factory + gitops-manifests)
    delivery_board = optional(object({ github_token = string, promote_token = optional(string) }))
  })
}
variable "ghcr_user" {
  type    = string
  default = "MIERAI"
}
variable "ghcr_token" {
  description = "GHCR pull token (read:packages): TF_VAR_ghcr_token=$(gh auth token --user MIERAI); \"\" = public images only"
  type        = string
  sensitive   = true
  default     = ""
}
variable "root_path" {
  description = "Path of the root application in gitops-manifests (apps | clusters/<name>)"
  type        = string
}
variable "in_cluster_object_storage" {
  description = "true: SeaweedFS runs in the cluster (needs its credentials secret); false: it runs on the host"
  type        = bool
}
variable "local_secrets_dir" {
  type = string
}
variable "manifests_repo" {
  type    = string
  default = "https://github.com/MIERAI/gitops-manifests.git"
}
variable "manifests_revision" {
  type    = string
  default = "main"
}
variable "argocd_chart_version" {
  type    = string
  default = "10.11.6" # Argo CD v3.5.6
}
variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.8"
}
variable "small" {
  description = "A small cluster (the lab, 7 GB): Argo CD without Dex and notifications (unused: admin login, no notifications)"
  type        = bool
  default     = false
}
variable "backup_namespaces" {
  description = <<-EOT
    Application namespaces (registered by an app.yaml in gitops-manifests, e.g. catalog-dev) whose CloudNativePG
    cluster backs up to the object store: created here like api-factory's (the Secret must exist before the first
    sync; Argo CD adds its labels later) and given backup-s3 (var.secrets.s3), nothing else. An existing namespace:
    tofu import 'module.platform.kubernetes_namespace_v1.ns["<name>"]' <name> once, before the apply. Removing a
    name later deletes its namespace (as for api-factory's): move the state out first (tofu state rm).
  EOT
  type        = list(string)
  default     = []
}
variable "pull_secret_in_app_namespaces" {
  description = "Write the GHCR pull secret into the private applications' namespaces (a cluster without Kyverno, which otherwise clones it)"
  type        = bool
  default     = false
}
variable "slo_platform" {
  description = <<-EOT
    Run the platform from slo-platform (the product) instead of the manifests repository's root path: the root
    Application becomes the product's (gitops-manifests is its instance: platform.yaml there). null = the old root.
    private = true (the product repository was private until 2026-11-21): Argo CD reads it with the GHCR token's
    owner (var.ghcr_token, scope repo), and on a lab the daily regression clones it with that token
    (slo-experiments/git-credentials). Public product and instance: no credentials at all.
  EOT
  type = object({
    repo              = optional(string, "https://github.com/MIERAI/slo-platform.git")
    version           = string
    cluster           = string
    lab               = optional(bool, false)
    private           = optional(bool, false)
    instance_repo     = optional(string, "https://github.com/MIERAI/gitops-manifests.git")
    instance_revision = optional(string, "main")
  })
  default = null
}

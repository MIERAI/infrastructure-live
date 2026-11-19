variable "secrets" {
  description = "Decrypted secrets/<cluster>.sops.yaml (s3, grafana_admin_password, api_factory.{dev,prod})"
  sensitive   = true
  type = object({
    s3                     = object({ access_key = string, secret_key = string })
    grafana_admin_password = string
    api_factory            = map(object({ api_token = string, db_password = string, page_token_key = string }))
    # off-site copy of the backups (laptop only): sftp key for the phone, rclone crypt password + salt
    offsite = optional(object({ ssh_private_key = string, crypt_password = string, crypt_salt = string }))
    # delivery board (laptop only): read-only fine-grained GitHub token (api-factory + gitops-manifests)
    delivery_board = optional(object({ github_token = string }))
  })
}
variable "ghcr_user" {
  type    = string
  default = "MIERAI"
}
variable "ghcr_token" {
  description = "GHCR pull token (read:packages): TF_VAR_ghcr_token=$(gh auth token --user MIERAI)"
  type        = string
  sensitive   = true
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
variable "argocd_chart_version" {
  type    = string
  default = "10.11.6" # Argo CD v3.5.6
}
variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.8"
}

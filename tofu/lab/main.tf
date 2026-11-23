# The lab cluster (k3s on xiaoxin from ansible/, group lab): the fault experiments run here, never on the laptop.
# tofu -chdir=tofu/lab apply
# Small (7 GB): gitops-manifests clusters/lab leaves out Kyverno and Grafana; Argo CD without Dex and notifications.
variable "kubeconfig" {
  type    = string
  default = "~/.kube/xiaoxin.yaml" # written by ansible (playbook site.yml, play "Lab cluster")
}
variable "kube_context" {
  type    = string
  default = "xiaoxin"
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}

# The lab's secrets are kind's (secrets/kind.sops.yaml): the same lab, throwaway values, nothing shared with the laptop
data "sops_file" "secrets" {
  source_file = "${path.module}/../../secrets/kind.sops.yaml"
}

module "platform" {
  source                    = "../modules/platform"
  secrets                   = yamldecode(data.sops_file.secrets.raw)
  ghcr_token                = var.ghcr_token
  root_path                 = "clusters/lab"
  in_cluster_object_storage = true
  local_secrets_dir         = "${path.module}/../../.secrets/lab"
  backup_namespaces         = ["catalog-dev", "catalog-staging", "catalog-prod"] # storefront v2 catalog (gitops-manifests catalog/): its database backs up like api-factory's
  # the platform from slo-platform; this cluster is "lab" in gitops-manifests/platform.yaml
  slo_platform                  = { version = "v0.1.1", cluster = "lab", lab = true }
  small                         = true
  pull_secret_in_app_namespaces = true # no Kyverno here to clone it
}

variable "ghcr_token" {
  description = "TF_VAR_ghcr_token=$(gh auth token --user MIERAI)"
  type        = string
  sensitive   = true
}

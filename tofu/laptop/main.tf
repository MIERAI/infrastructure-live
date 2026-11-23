# The always-on laptop (k3s from ansible/): platform only. tofu -chdir=tofu/laptop apply
# Reach the cluster over Tailscale (default) or, at home, over the LAN:
#   TF_VAR_kubeconfig=~/.kube/laptop-lan.yaml TF_VAR_kube_context=laptop-lan tofu -chdir=tofu/laptop apply
variable "kubeconfig" {
  type    = string
  default = "~/.kube/laptop.yaml" # written by ansible (playbook site.yml)
}
variable "kube_context" {
  type    = string
  default = "laptop"
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

data "sops_file" "secrets" {
  source_file = "${path.module}/../../secrets/laptop.sops.yaml"
}

module "platform" {
  source                    = "../modules/platform"
  secrets                   = yamldecode(data.sops_file.secrets.raw)
  ghcr_token                = var.ghcr_token
  root_path                 = "clusters/laptop"
  in_cluster_object_storage = false # SeaweedFS is a systemd service on the host (ansible role seaweedfs)
  local_secrets_dir         = "${path.module}/../../.secrets/laptop"
  backup_namespaces         = ["catalog-dev", "catalog-staging"] # storefront v2 catalog (gitops-manifests catalog/): its database backs up like api-factory's
  # the platform from slo-platform; this cluster is "laptop" in gitops-manifests/platform.yaml
  slo_platform = { version = "v0.1.1", cluster = "laptop", lab = false }
}

variable "ghcr_token" {
  description = "TF_VAR_ghcr_token=$(gh auth token --user MIERAI)"
  type        = string
  sensitive   = true
}

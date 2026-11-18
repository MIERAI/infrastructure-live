# The always-on laptop (k3s from ansible/): platform only. tofu -chdir=tofu/laptop apply
locals {
  kubeconfig = pathexpand("~/.kube/laptop.yaml") # written by ansible (playbook site.yml)
}

provider "kubernetes" {
  config_path    = local.kubeconfig
  config_context = "laptop"
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig
    config_context = "laptop"
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
}

variable "ghcr_token" {
  description = "TF_VAR_ghcr_token=$(gh auth token --user MIERAI)"
  type        = string
  sensitive   = true
}

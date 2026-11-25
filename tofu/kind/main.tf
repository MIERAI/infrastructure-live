# Local kind cluster (stand-in for a cloud cluster): cluster → platform. tofu -chdir=tofu/kind apply
locals {
  kubeconfig = pathexpand("~/.kube/kind-gitops.yaml") # own file: ~/.kube/config (company contexts) is never touched
}

resource "kind_cluster" "this" {
  name            = "gitops"
  node_image      = "kindest/node:v1.36.1"
  kubeconfig_path = local.kubeconfig
  wait_for_ready  = true
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role = "control-plane"
      # NodePorts 30080-30083 → localhost:18080-18083 (api-factory dev/prod, sample-app dev/prod)
      dynamic "extra_port_mappings" {
        for_each = [0, 1, 2, 3]
        content {
          container_port = 30080 + extra_port_mappings.value
          host_port      = 18080 + extra_port_mappings.value
        }
      }
    }
  }
}

provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.this.endpoint
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
  }
}

# Secrets: secrets/kind.sops.yaml (age key on the workstation), or secrets_json (throwaway values, for a run without the
# age key; CI no longer applies this root: its end-to-end test is tofu/demo).
data "sops_file" "secrets" {
  count       = var.secrets_json == "" ? 1 : 0
  source_file = "${path.module}/../../secrets/kind.sops.yaml"
}

module "platform" {
  source                    = "../modules/platform"
  secrets                   = var.secrets_json != "" ? jsondecode(var.secrets_json) : yamldecode(data.sops_file.secrets[0].raw)
  ghcr_token                = var.ghcr_token
  root_path                 = "apps"
  in_cluster_object_storage = true
  local_secrets_dir         = "${path.module}/../../.secrets/kind"
}

variable "ghcr_token" {
  description = "TF_VAR_ghcr_token=$(gh auth token --user MIERAI)"
  type        = string
  sensitive   = true
}

variable "secrets_json" {
  description = "Same structure as secrets/kind.sops.yaml, as JSON (throwaway values, a run without the age key)"
  type        = string
  default     = ""
  sensitive   = true
}

# The demo: the whole platform on a local kind cluster, for anyone — no keys, no tokens, no accounts. Argo CD syncs
# gitops-manifests clusters/demo: the platform (Kyverno policies, Argo Rollouts, CNPG, monitoring, object storage) and
# every public application (sample-app, storefront). Secrets are generated here (throwaway).
#   tofu -chdir=tofu/demo init && tofu -chdir=tofu/demo apply      (see README.md next to this file)

variable "cluster_name" {
  type    = string
  default = "gitops-demo"
}
variable "host_port_base" {
  description = "NodePorts 30080-30083 are published on localhost:<base>..<base+3> (sample-app dev / prod: base+2 / +3)"
  type        = number
  default     = 28080
}
variable "manifests_repo" {
  description = "Your fork of gitops-manifests (after its scripts/fork.sh), or ours"
  type        = string
  default     = "https://github.com/MIERAI/gitops-manifests.git"
}
variable "manifests_revision" {
  type    = string
  default = "main"
}

locals {
  kubeconfig = pathexpand("~/.kube/${var.cluster_name}.yaml") # its own file: ~/.kube/config is never touched
}

resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = "kindest/node:v1.36.1"
  kubeconfig_path = local.kubeconfig
  wait_for_ready  = true
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role = "control-plane"
      dynamic "extra_port_mappings" {
        for_each = [0, 1, 2, 3]
        content {
          container_port = 30080 + extra_port_mappings.value
          host_port      = var.host_port_base + extra_port_mappings.value
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

resource "random_password" "s" {
  for_each = toset(["s3_access", "s3_secret", "grafana"])
  length   = 24
  special  = false
}

module "platform" {
  source = "../modules/platform"
  secrets = {
    s3                     = { access_key = random_password.s["s3_access"].result, secret_key = random_password.s["s3_secret"].result }
    grafana_admin_password = random_password.s["grafana"].result
    api_factory            = {} # private application: not in the demo
  }
  root_path                 = "clusters/demo"
  manifests_repo            = var.manifests_repo
  manifests_revision        = var.manifests_revision
  in_cluster_object_storage = true
  local_secrets_dir         = "${path.module}/../../.secrets/${var.cluster_name}"
}

output "next" {
  value = <<-EOT
    export KUBECONFIG=${local.kubeconfig}
    kubectl -n argocd get applications            # 16, all Synced / Healthy after ~3-5 min
    curl localhost:${var.host_port_base + 2}/hello            # sample-app dev
    Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8080:80 → http://localhost:8080
                admin / $(cat .secrets/${var.cluster_name}/argocd-admin.password)
  EOT
}

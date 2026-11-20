terraform {
  required_version = ">= 1.10"
  # State: local, next to this file (gitignored). It holds only throwaway values generated for the demo.
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 3.1" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    local      = { source = "hashicorp/local", version = "~> 2.5" }
    random     = { source = "hashicorp/random", version = "~> 3.7" }
    kind       = { source = "tehcyx/kind", version = "~> 0.11" }
  }
}

terraform {
  required_version = ">= 1.10"
  # State: outside this public repository, encrypted by OpenTofu (it holds the decrypted secrets).
  # Passphrase: ~/Library/Application Support/gitops/tofu-state.passphrase (back it up with the age key)
  backend "local" {
    path = pathexpand("~/Library/Application Support/gitops/tofu/lab.tfstate")
  }
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = trimspace(file(pathexpand("~/Library/Application Support/gitops/tofu-state.passphrase")))
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method   = method.aes_gcm.main
      enforced = true
    }
    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 3.1" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    local      = { source = "hashicorp/local", version = "~> 2.5" }
    sops       = { source = "carlpett/sops", version = "~> 1.3" }
  }
}

# Infrastructure Provisioning and Lifecycle Management

> Parent Project: [Enterprise GitOps Platform Blueprint](../gitops-platform-blueprint)

## Overview
This repository manages the lifecycle of the underlying cloud infrastructure using Terraform. It defines the foundational resources required to host containerized workloads with a focus on security, high availability, and network isolation.

## Managed Resources
- **Networking**: VPC, Subnets, Cloud NAT, and Firewall Rules.
- **Computing**: Google Kubernetes Engine (GKE) clusters with optimized node pools.
- **Security & Data**: Cloud SQL (PostgreSQL), Secret Manager, and Identity & Access Management (IAM) policies.

## Usage
Infrastructure changes are executed through a structured Terraform workflow (Plan/Apply), ensuring all modifications are reviewed and versioned.

---
**Component**: Infrastructure Layer  
**Status**: Reference Implementation
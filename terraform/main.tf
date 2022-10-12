terraform {
  required_version = ">= 0.15"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
  backend "gcs" {
    bucket = "terraform-backend-<project-id>"
    prefix = "argocd-terraform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.location
}

resource "google_service_account" "main" {
  account_id   = "${var.cluster_name}-sa"
  display_name = "GKE Cluster ${var.cluster_name} Service Account"
}

resource "google_container_cluster" "main" {
  provider = google-beta

  name     = var.cluster_name
  location = var.location

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
  
  cluster_autoscaling {
    enabled = true
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }
}

resource "google_container_node_pool" "main_spot_nodes" {
  name     = "${var.cluster_name}-nodepool"
  location = var.location
  cluster  = google_container_cluster.main.name

  initial_node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    preemptible  = true
    machine_type = "e2-highmem-2"

    service_account = google_service_account.main.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "google_container_node_pool" "gpu_spot_nodes" {
  name     = "${var.cluster_name}-nodepool-gpu"
  location = var.location
  cluster  = google_container_cluster.main.name

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    preemptible  = true
    machine_type = "n2-highcpu-2"

    guest_accelerator {
      type = "nvidia-tesla-t4"
      count = 1
    }

    service_account = google_service_account.main.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "time_sleep" "wait_30_seconds" {
  depends_on      = [google_container_cluster.main]
  create_duration = "30s"
}

module "gke_auth" {
  depends_on           = [time_sleep.wait_30_seconds]
  source               = "terraform-google-modules/kubernetes-engine/google//modules/auth"
  project_id           = var.project_id
  cluster_name         = google_container_cluster.main.name
  location             = var.location
  use_private_endpoint = false
}

provider "kubectl" {
  host                   = module.gke_auth.host
  cluster_ca_certificate = module.gke_auth.cluster_ca_certificate
  token                  = module.gke_auth.token
  load_config_file       = false
}

data "kubectl_file_documents" "namespaces" {
  content = file("../manifests/namespaces.yaml")
}

data "kubectl_file_documents" "argocd" {
  content = file("../manifests/install-argocd.yaml")
}

resource "kubectl_manifest" "namespaces" {
  count     = length(data.kubectl_file_documents.namespaces.documents)
  yaml_body = element(data.kubectl_file_documents.namespaces.documents, count.index)
}

data "kubectl_file_documents" "certmanager" {
  content = file("../manifests/cert-manager-v1.9.1.yaml")
}

resource "kubectl_manifest" "certmanager" {
  count     = length(data.kubectl_file_documents.certmanager.documents)
  yaml_body = element(data.kubectl_file_documents.certmanager.documents, count.index)
}

data "kubectl_file_documents" "cert_issuer" {
  content = file("../manifests/issuer.yaml")
}

resource "kubectl_manifest" "cert_issuer" {
  count              = length(data.kubectl_file_documents.cert_issuer.documents)
  yaml_body          = element(data.kubectl_file_documents.cert_issuer.documents, count.index)
}

data "kubectl_file_documents" "nginx" {
  content = file("../manifests/ingress-nginx-v1.4.0.yaml")
}

resource "kubectl_manifest" "nginx" {
  count     = length(data.kubectl_file_documents.nginx.documents)
  yaml_body = element(data.kubectl_file_documents.nginx.documents, count.index)
}

resource "kubectl_manifest" "argocd" {
  depends_on = [
    kubectl_manifest.namespaces,
    kubectl_manifest.nginx
  ]
  count              = length(data.kubectl_file_documents.argocd.documents)
  yaml_body          = element(data.kubectl_file_documents.argocd.documents, count.index)
  override_namespace = "argocd"
}

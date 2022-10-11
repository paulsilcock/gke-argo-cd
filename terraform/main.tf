terraform {
  required_version = ">= 0.13"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
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
  name     = var.cluster_name
  location = var.location

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "main_spot_nodes" {
  name     = "${var.cluster_name}-nodepool"
  location = var.location
  cluster  = google_container_cluster.main.name

  initial_node_count = 2

  autoscaling {
    min_node_count = 2
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

data "kubectl_file_documents" "google_cas_issuer" {
  content = file("../manifests/google-cas-issuer-v0.6.0-alpha.1.yaml")
}

resource "kubectl_manifest" "google_cas_issuer" {
  count              = length(data.kubectl_file_documents.google_cas_issuer.documents)
  yaml_body          = element(data.kubectl_file_documents.google_cas_issuer.documents, count.index)
  override_namespace = "cert-manager"
}

resource "google_service_account" "ca-issuer" {
  depends_on = [
    kubectl_manifest.google_cas_issuer
  ]
  account_id   = "sa-google-cas-issuer"
  display_name = "Service Account For Workload Identity"
}
resource "google_project_iam_member" "storage-role" {
  role = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.ca-issuer.email}"
}
resource "google_project_iam_member" "workload_identity-role" {
  role   = "roles/iam.workloadIdentityUser"
  member = "serviceAccount:${var.project}.svc.id.goog[cert-manager/cert-manager-google-cas-issuer]"
}

resource "google_privateca_ca_pool_iam_binding" "binding" {
  ca_pool  = "projects/${var.project_id}/locations/${var.region}/caPools/ca-pool"
  project  = var.project_id
  location = var.region
  role     = "roles/privateca.certificateManager"
  members = [
    "serviceAccount:${google_service_account.ca-issuer.email}",
  ]
}

resource "kubectl_manifest" "certIssuer" {
  yaml_body = <<YAML
apiVersion: cas-issuer.jetstack.io/v1beta1
kind: GoogleCASClusterIssuer
metadata:
  name: googlecasclusterissuer
spec:
  project: ${var.project_id}
  location: ${var.region}
  caPoolId: ca-pool
YAML
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

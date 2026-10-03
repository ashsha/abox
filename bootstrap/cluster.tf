# ==========================================
# Construct KinD cluster
# ==========================================
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
  # null keeps the provider default (merge into the user's kubeconfig), see
  # var.kubeconfig_path for why a dedicated file is sometimes preferable.
  kubeconfig_path = var.kubeconfig_path != "" ? pathexpand(var.kubeconfig_path) : null
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role = "control-plane"
    }
    node {
      role = "worker"
    }
    node {
      role = "worker"
    }
    networking {
      kube_proxy_mode = "ipvs"
    }
  }
}


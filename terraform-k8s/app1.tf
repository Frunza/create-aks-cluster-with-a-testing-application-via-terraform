# Host via nip.io

resource "kubernetes_namespace" "app1" {
  metadata {
    name = "app1"
  }
}

resource "kubernetes_manifest" "app1Deployment" {
  manifest = {
    "apiVersion" = "apps/v1"
    "kind"       = "Deployment"
    "metadata" = {
      "name"      = "app1"
      "namespace" = kubernetes_namespace.app1.metadata[0].name
      "labels"    = { "app" = "app1" }
    }
    "spec" = {
      "replicas" = 1
      "selector" = {
        "matchLabels" = { "app" = "app1" }
      }
      "template" = {
        "metadata" = { "labels" = { "app" = "app1" } }
        "spec" = {
          "containers" = [{
            "name"  = "nginx"
            "image" = "nginx"
            "ports" = [{ "containerPort" = 80 }]
          }]
        }
      }
    }
  }
}

resource "kubernetes_manifest" "app1Service" {
  manifest = {
    "apiVersion" = "v1"
    "kind"       = "Service"
    "metadata" = {
      "name"      = "app1-service"
      "namespace" = kubernetes_namespace.app1.metadata[0].name
    }
    "spec" = {
      "selector" = { "app" = "app1" }
      "ports"    = [{ "port" = 80, "targetPort" = 80 }]
      "type"     = "ClusterIP"
    }
  }
}

resource "kubernetes_manifest" "app1Ingress" {
  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "Ingress"
    "metadata" = {
      "name"      = "app1-ingress"
      "namespace" = kubernetes_namespace.app1.metadata[0].name
      "annotations" = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    "spec" = {
      "rules" = [{
        "host" = "app1.${data.kubernetes_service.ingressService.status[0].load_balancer[0].ingress[0].ip}.nip.io"
        "http" = {
          "paths" = [{
            "path"     = "/"
            "pathType" = "Prefix"
            "backend"  = {
              "service" = {
                "name" = "app1-service"
                "port" = { "number" = 80 }
              }
            }
          }]
        }
      }]
    }
  }
}

output "app1Host" {
  value = kubernetes_manifest.app1Ingress.manifest.spec.rules[0].host
}

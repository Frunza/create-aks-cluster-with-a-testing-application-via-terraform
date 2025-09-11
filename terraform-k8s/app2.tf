# Host via domain and certificate secret

variable "app2Host" {
  description = "Public host for app2"
  type        = string
  default     = "app2.cluster1.mycompany.com"
}

resource "kubernetes_namespace" "app2Namespace" {
  metadata {
    name = "app2"
  }
}

resource "kubernetes_manifest" "app2Deployment" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "app2"
      namespace = kubernetes_namespace.app2Namespace.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = {
          app = "app2"
        }
      }
      replicas = 2
      template = {
        metadata = {
          labels = {
            app = "app2"
          }
        }
        spec = {
          containers = [{
            name  = "app2"
            image = "frunzahincu/write_headers"
            ports = [{
              containerPort = 8000
            }]
          }]
        }
      }
    }
  }
}

resource "kubernetes_manifest" "app2Service" {
  manifest = {
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "app2"
      namespace = kubernetes_namespace.app2Namespace.metadata[0].name
    }
    spec = {
      ports = [{
        port       = 80
        targetPort = 8000
      }]
      selector = {
        app = "app2"
      }
    }
  }
}

resource "kubernetes_manifest" "app2Ingress" {
  manifest = {
    "apiVersion" = "networking.k8s.io/v1"
    "kind"       = "Ingress"
    "metadata" = {
      "name"      = "app2-ingress"
      "namespace" = kubernetes_namespace.app2Namespace.metadata[0].name
      "annotations" = {
        "kubernetes.io/ingress.class" = "nginx"
      }
    }
    "spec" = {
      "rules" = [{
        "host" = "${var.app2Host}"
        "http" = {
          "paths" = [{
            "path"     = "/"
            "pathType" = "Prefix"
            "backend" = {
              "service" = {
                "name" = "app2"
                "port" = {
                  "number" = 80
                }
              }
            }
          }]
        }
      }]
      "tls" = [{
        "hosts"      = ["${var.app2Host}"]
        "secretName" = "app2-ingress-tls-crt"
      }]
    }
  }
}

resource "kubernetes_manifest" "app2TlsSecret" {
  manifest = {
    "apiVersion" = "v1"
    "kind"       = "Secret"
    "metadata" = {
      "name"      = "app2-ingress-tls-crt"
      "namespace" = kubernetes_namespace.app2Namespace.metadata[0].name
    }
    "type" = "kubernetes.io/tls"
    "data" = {
      # base64 fullchain1.pem | tr -d '\n' on MacOS. On Linux, use base64 -w 0 fullchain1.pem
      "tls.crt" = "DUMMYCRT"
      # base64 privkey1.pem | tr -d '\n' on MacOS. On Linux, use base64 -w 0 privkey1.pem
      "tls.key" = "DUMMYKEY"
    }
  }
}

output "app2Host" {
  value = kubernetes_manifest.app2Ingress.manifest.spec.rules[0].host
}

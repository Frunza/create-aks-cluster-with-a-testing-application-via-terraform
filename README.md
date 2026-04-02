# Create AKS cluster with a testing application via Terraform

## Motivation

I want to create an `AKS` cluster fully automated with `Terraform`. I also want to call some url to access some application running in the cluster.

## Prerequisites

A Linux or MacOS machine for local development. If you are running Windows, you first need to set up the *Windows Subsystem for Linux (WSL)* environment.

You need `docker cli` on your machine for testing purposes, and/or on the machines that run your pipeline.
You can verify this by running the following command:
```sh
docker --version
```

For `Azure` access you need the following:
- ARM_CLIENT_ID
- ARM_CLIENT_SECRET
- ARM_TENANT_ID
- ARM_SUBSCRIPTION_ID

## Implementation

The idea is to use a container with all necessary tools, give it credentials via environment variables, and run everything via the container to update or destroy the infrastructure.

We will need 2 `Terraform` projects, one for setting up the `AKS` cluster, and the other one to add stuff in `k8s`. The reason we need a second `Terraform` project is because it needs the *kubeconfig* of the cluster, which is available only after the first `Terraform` project runs. This cannot be set as a dependency, because the *kubeconfig* needs to be available during the initialization phase of the `Terraform` project.

With this in mind, let's create the dockerfile. Because we have 2 `Terraform` projects, we will add both of them in the *dockerfile*:
 ```sh
FROM hashicorp/terraform:1.5.0

RUN apk add --no-cache \
    curl \
    bash \
    python3 \
    py3-pip \
    gcc \
    musl-dev \
    libffi-dev \
    openssl-dev \
    make \
    linux-headers \
    python3-dev

# Install Azure CLI
RUN pip3 install azure-cli

COPY ./terraform /app
COPY ./terraform-k8s /app/terraform-k8s
WORKDIR /app
```

Now let's create a docker compose file with 2 servces that either create/update the infrastructure, or destroy it. This is the place where you provide all environment variables you intend to use: for our case the environment variables related to `Azure` access.

In the update service, we want to apply the first `Terraform` project, which at the very end will apply the second `Terraform` project, so in the docker compose service, we only need to apply the first `Terraform` project:
```sh
terraform init && terraform apply -auto-approve
```

The more complicated logic is in the service that destroys the infrastructure. The reason for this is because the second `Terraform` project requires the *kubeconfig* to run. This means that we have to apply the first `Terraform` project to retrieve the *kubeconfig*, afterwards we need to destroy the second `Terraform` project, and at the end destroy the first `Terraform` project.

One question you might have is why do we actually need to destroy the second `Terraform` project, since all of its stuff will go away either way when we destroy the `AKS` cluster. The reason for it is because the `Terraform` state files. If you do not clean up the `Terraform` state files for `k8s`, the next time you create the infrastructure, `Terraform` will try to add your previous `k8s` resources, even if your current ones are different. This can cause unexpected `k8s` resources to be deployed, messing up your cluster and creating large overhead for debugging, so it is a very good idea to clean up everything.

Since the first `Terraform` project is needed in the destroy step just to generate the *kubeconfig*, it should not apply the second `Terraform` project that applies the `k8s` resources because they will be deleted either way. We can give here a flag that we can name as *runTerraformK8s* to use it in the implementation of the first `Terraform` project to skip the apply of the second `Terraform` project when needed.

with all of this in mind, the destroy service should run the following:
```sh
      "terraform init && terraform apply -var=\"runTerraformK8s=false\" -auto-approve && \
      cd terraform-k8s && terraform init && terraform destroy -auto-approve && \
      cd .. && terraform destroy -auto-approve"
```

Let's now build the docker compose file:
```sh
services:
  update:
    image: test-aks-with-testing-application
    network_mode: host
    working_dir: /app
    environment:
      - ARM_CLIENT_ID=${ARM_CLIENT_ID}
      - ARM_CLIENT_SECRET=${ARM_CLIENT_SECRET}
      - ARM_TENANT_ID=${ARM_TENANT_ID}
      - ARM_SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}
    entrypoint: ["sh", "-c"]
    command: [
      "terraform init && terraform apply -auto-approve"
    ]
  destroy:
    image: test-aks-with-testing-application
    network_mode: host
    working_dir: /app
    environment:
      - ARM_CLIENT_ID=${ARM_CLIENT_ID}
      - ARM_CLIENT_SECRET=${ARM_CLIENT_SECRET}
      - ARM_TENANT_ID=${ARM_TENANT_ID}
      - ARM_SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}
    entrypoint: ["sh", "-c"]
    command: [
      "terraform init && terraform apply -var=\"runTerraformK8s=false\" -auto-approve && \
      cd terraform-k8s && terraform init && terraform destroy -auto-approve && \
      cd .. && terraform destroy -auto-approve"
    ]
```

## AKS Terraform project

First of all, let's configure the `Azure` provider:
```sh
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.36.0"
    }
  }
}

# Configure the Azure Provider
# Credentials can be provided by using the ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID and ARM_SUBSCRIPTION_ID environment variables. (https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```
Note that the environment variables we provided in the docker compose file match with what the provider expects.

We can define some variables for our project also:
```sh
variable "location" {
  default = "Germany West Central"
}

variable "tag" {
  default = "my-test" # tag must be shorter because it is or might be used in various places with maximum length
}

variable "nodeCount" {
  default = 2
}

variable "vmSize" {
  default = "Standard_D2_v2"
}

locals {
  resourceGroupName = "${var.tag}-rg"
}

variable "runTerraformK8s" {
  default = true
}
```

Now that the configuration stuff is taken care of, let's start by creating a resource group:
```sh
resource "azurerm_resource_group" "clusterResourceGroup" {
  name     = local.resourceGroupName
  location = var.location

  tags = {
    Environment = var.tag
  }
}
```

Let's set up some networking configuration also. For this scenario, we want the cluster to be publicly available, so we will set up the networking to work in that matter. In other environments you usually have some restrictions instead:
```sh
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.tag}-aks-nsg"
  location            = azurerm_resource_group.clusterResourceGroup.location
  resource_group_name = azurerm_resource_group.clusterResourceGroup.name

  security_rule {
    name                       = "allow-http"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    destination_port_range     = "80"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "allow-https"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    destination_port_range     = "443"
    source_port_range          = "*"
  }

  tags = {
    Environment = var.tag
  }
}

resource "azurerm_virtual_network" "aksVnet" {
  name                = "aks-vnet"
  location            = azurerm_resource_group.clusterResourceGroup.location
  resource_group_name = azurerm_resource_group.clusterResourceGroup.name
  address_space       = ["10.224.0.0/16"]

  tags = {
    Environment = var.tag
  }
}

resource "azurerm_subnet" "aksSubnet" {
  name                 = "${var.tag}-aks-subnet"
  resource_group_name  = azurerm_resource_group.clusterResourceGroup.name
  virtual_network_name = azurerm_virtual_network.aksVnet.name
  address_prefixes     = ["10.224.0.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_subnet_network_security_group_association" "aksSubnetNsgAssociation" {
  subnet_id                 = azurerm_subnet.aksSubnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
```

We can create the cluster with the folowing resource:
```sh
resource "azurerm_kubernetes_cluster" "cluster" {
  name                = "${var.tag}-aks"
  location            = azurerm_resource_group.clusterResourceGroup.location
  resource_group_name = azurerm_resource_group.clusterResourceGroup.name
  node_resource_group = "${var.tag}-node-rg"
  dns_prefix          = "${var.tag}-dns-prefix-aks"

  default_node_pool {
    name           = "default"
    node_count     = var.nodeCount
    vm_size        = var.vmSize
    vnet_subnet_id = azurerm_subnet.aksSubnet.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aksIdentity.id]
  }

  tags = {
    Environment = var.tag
  }
}

resource "azurerm_user_assigned_identity" "aksIdentity" {
  location            = var.location
  name                = "my-subcription-prod-aks-${var.tag}-identity"
  resource_group_name = azurerm_resource_group.clusterResourceGroup.name

  tags = {
    Environment = var.tag
  }
}
```

For all of this to work we must do some extra role assignments:
```sh
# ---------------- Role Assignments ----------------
resource "azurerm_role_assignment" "aksNetworkContributor" {
  scope                = azurerm_virtual_network.aksVnet.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aksIdentity.principal_id
}

resource "azurerm_role_assignment" "aksNsgContributor" {
  scope                = azurerm_network_security_group.nsg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aksIdentity.principal_id
}
```

With this we have an empty `AKS` cluster. It is time to run the `k8s Terraform` project. Since that the `k8s Terraform` project works directly with `k8s`, and therefore it needs a *kubeconfig* file. Let's save it somewhere in the container:
```sh
resource "local_file" "kubeconfig" {
  content  = azurerm_kubernetes_cluster.cluster.kube_config_raw
  filename = "/app/.kube/config"
}
```

Now we have everything we need to run the `k8s Terraform` project:
```sh
resource "null_resource" "runTerraformK8s" {
  count = var.runTerraformK8s ? 1 : 0
  depends_on = [ local_file.kubeconfig ]

  triggers = {
    always_run = "${timestamp()}" # This will force the resource to run every time
  }

  provisioner "local-exec" {
    command = <<EOT
cd /app/terraform-k8s
terraform init
terraform apply -auto-approve
EOT
  }
  
}
```
Note the usage of the *runTerraformK8s* flag thatv was explained previously.

## K8s Terraform project

First of all, let's configure the providers:
```sh
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.9"
    }
  }
}

provider "kubernetes" {
  config_path = "/app/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "/app/.kube/config"
  }
}
```
Note that the path of the cubeconfig file must match with was previously set in the container.

Now we can add some infrastructure for the cluster:
```sh
resource "kubernetes_namespace" "ingressNginxNamespace" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "nginxIngress" {
  name       = "nginx-ingress"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingressNginxNamespace.metadata[0].name
  version    = "4.12.0"

  values = [
    <<-EOF
    controller:
      service:
        type: LoadBalancer
        externalTrafficPolicy: Local
    EOF
  ]
}

data "kubernetes_service" "ingressService" {
  metadata {
    name      = "nginx-ingress-ingress-nginx-controller" # Default name for the NGINX ingress controller service
    namespace = kubernetes_namespace.ingressNginxNamespace.metadata[0].name
  }

  depends_on = [helm_release.nginxIngress] # Ensure the ingress controller is deployed first
}
```
Here we set up *ingress-nginx* via `helm`.

Let's add 2 applications also.

The first application will use an *nginx* image and will get a host from [nip.io](nip.io):
```sh
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
```

The second application will use an *write_headers* image and will get a dummy company host, with dummy ssl certificate:
```sh
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
```
For this tutorial, there's no need to add better logic for the certificate secret, since it is not the focus.

## Usage

From the repository root run:
```sh
sh update.sh
```
to run the script that creates and/or updates the infrastructure.

Run:
```sh
sh update.sh
```
to run the script that destroys the infrastructure.

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 1.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      # Pinned to the 3.x line rather than the plan's ">= 2.23.0". The pod and PVC schemas differ
      # between 2.x and 3.x - wait_for_rollout, wait_for_delete and wait_for_bound are 2.x-only -
      # and a range whose lower bound has a different schema than its upper bound is a template
      # that validates today and breaks when the resolver moves. 3.x is what `>= 2.23.0` already
      # resolves to.
      version = "~> 3.3"
    }
  }
}

# No host, no credentials: the kubernetes provider falls back to the in-cluster config of the
# pod running this terraform, which is the coder server pod, whose ServiceAccount is bound to
# the Role in apply/50-apps/coder/workspaces.yaml. That Role is the fence - it grants pods and
# persistentvolumeclaims in coder-workspaces and nothing else, so a template cannot reach
# databases or auth no matter what is written here.
provider "coder" {}
provider "kubernetes" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# 40 Gi on the Retain class. This is the resource the spec's whole accepted-risk argument sits
# on: it is not backed up (spec C2), and Retain is what stands between a wrong `kubectl delete
# pvc` and a lost home directory. Task 9 proves the provisioner honours it.
resource "kubernetes_persistent_volume_claim_v1" "home" {
  # `wait_until_bound`, not `wait_for_bound` - the plan had the latter and `tofu validate` rejected
  # it outright. Read out of the provider schema (tofu providers schema -json), not from memory.
  wait_until_bound = true
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = "coder-workspaces"
    labels = {
      creator = data.coder_workspace_owner.me.name
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path-retain"
    resources {
      requests = { storage = "40Gi" }
    }
  }
}

resource "coder_agent" "dev" {
  # `arch` is required by the coder provider schema and the plan omitted it, which fails the push.
  # amd64 is not a guess: the sole node reports status.nodeInfo.architecture=amd64.
  os   = "linux"
  arch = "amd64"

  # interval and timeout are SECONDS in the coder provider schema, not milliseconds - checked
  # in provider/agent.go: "The interval in seconds at which to refresh this metadata item".
  # The plan had 10000 for both, which is a 2.8-hour refresh and a 2.8-hour allowance for a
  # command that prints a number: the panel would have looked frozen and nothing would have
  # errored. `coder stat cpu` exists (cli/stat.go) and returns in milliseconds.
  metadata {
    display_name = "cpu"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 5
  }

  metadata {
    display_name = "memory"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 5
  }
}

resource "kubernetes_pod_v1" "dev" {
  # No wait_for_rollout / wait_for_delete: 3.x dropped both (its only top-level attributes are
  # `id` and `target_state`, read from the provider schema). The plan carried them from 2.x and
  # `tofu validate` rejected them. coder's own agent connection is what waits for the workspace to
  # be usable, so nothing here was relying on the removed blocking behaviour.
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = "coder-workspaces"
    labels = {
      app     = "coder-workspace"
      coder   = "true"
      creator = data.coder_workspace_owner.me.name
    }
  }
  spec {
    container {
      name  = "dev"
      image = "alpine:3.20"

      command     = ["sh", "-c", "while true; do sleep 3600; done"]
      working_dir = "/home/coder"

      # Requests equal limits, at the per-workspace budget from spec §9.1. Two of these against
      # the namespace quota of 8 CPU / 16 Gi is the whole design: the third workspace is meant to
      # sit Pending. Requests are what the quota charges, so leaving them unset would have made
      # the quota decorative - see the LimitRange in workspaces.yaml for the same argument.
      resources {
        requests = { cpu = "4000m", memory = "8Gi" }
        limits   = { cpu = "4000m", memory = "8Gi" }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.dev.token
      }
    }

    # No securityContext, deliberately, and it is worth knowing why rather than it being an
    # oversight. coder-workspaces carries pod-security warn: restricted, and this pod will be
    # flagged: alpine declares no USER, so it runs as root. Setting runAsNonRoot: true would not
    # fix that - it would make the pod refuse to start, because runAsNonRoot needs the image to
    # name a non-root user or an explicit runAsUser. The real fix is an image that declares a
    # user; when that happens the home directory is already writable, because the provisioner's
    # own setup script creates each volume 0777 (read from cm/kube-system/local-path-config).
    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }
  }
}

resource "coder_metadata" "home" {
  resource_id = kubernetes_persistent_volume_claim_v1.home.id
  item {
    key   = "storage class"
    value = "local-path-retain (Retain: a deleted PVC keeps its bytes, and it is not backed up)"
  }
}

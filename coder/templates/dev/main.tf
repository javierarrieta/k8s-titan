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
  # false, and it is not a loosening. local-path-retain is volumeBindingMode:
  # WaitForFirstConsumer (read from the StorageClass), so the PVC cannot bind until a pod that uses
  # it is scheduled — and that pod is the very next resource in this graph. With wait_until_bound =
  # true, terraform blocks on the PVC forever, the pod is never created, and coder's 5-minute build
  # deadline kills it. The live failure did not even look like this: the provider surfaced it as
  #   client rate limiter Wait returned an error: context deadline exceeded
  # on the PVC block, because the attribute's whole job is polling the API until it binds and the
  # polling is what ran out of time. The PVC event said the actual reason the whole time:
  #   WaitForFirstConsumer  waiting for first consumer to be created before binding
  # Binding is still enforced, just by the kubelet: the pod will not reach Running until the volume
  # is attached and mounted, and coder's own agent connection is what gates workspace readiness.
  wait_until_bound = false
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

# The image is a parameter rather than a literal because the whole point of a baked workspace image
# is that software ships by rebuilding it; pinning it in source would mean a git commit per image bump
# and a template push is already that. Default is 0.0.11, read from the GHCR tag list
# (`/v2/.../tags/list`, highest semver) rather than copied from coder-templates, which still pins
# 0.0.7. The repo is public-readable — verified with an anonymous pull token — so no imagePullSecret.
data "coder_parameter" "workspace_image" {
  name         = "workspace_image"
  display_name = "Workspace image"
  description  = "Workspace container image (registry/repo:tag)"
  type         = "string"
  default      = "ghcr.io/javierarrieta/coder-workspaces-nix:0.0.11"
  mutable      = true
}

resource "coder_agent" "dev" {
  # `arch` is required by the coder provider schema and the plan omitted it, which fails the push.
  # amd64 is not a guess: the sole node reports status.nodeInfo.architecture=amd64.
  os   = "linux"
  arch = "amd64"

  # Matches the image's WorkingDir and the PVC mount. Without it the agent picks a default that is
  # not on the persistent volume, and anything it drops there dies with the pod.
  #
  # `tofu validate` warns that dir is deprecated. It stays because the pinned coder provider's own
  # schema lists no replacement — coder_agent exposes dir and nothing like working_folder, read out
  # of `tofu providers schema -json`. A warning with no available alternative is information, not
  # debt; when the provider ships a successor field, this is a one-line change.
  dir = "/home/coder"

  # Config-only home-manager, same contract as the podman template: software comes from the image,
  # home-manager ships dotfiles and program settings and installs nothing. It still has to *build*
  # its generation into the nix store, which is why the container boots as root and hands uid 1000
  # write access to /nix before the agent ever runs (see the pod command).
  #
  # Failure is logged rather than fatal: a broken flake should leave a usable workspace, not a
  # workspace that never reaches connected.
  startup_script = <<-EOT
    #!/bin/bash
    set -uo pipefail
    if ! home-manager switch -b pre-hm --flake github:javierarrieta/nixos-configurations#coder-workspace >> /home/coder/.hm-switch.log 2>&1; then
      echo "hm-switch failed $(date -u +%FT%TZ)" >> /home/coder/.hm-switch.log
    fi
  EOT

  env = {
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    NIX_PATH            = "nixpkgs=https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz"
  }

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
  # The pod is the compute, so it must exist only while the workspace is started. Without this the
  # pod survives `coder stop` entirely — which is what happened on the live cluster: coder reported
  # "stopped", the pod stayed Running, and 4 CPU / 8Gi stayed charged against the namespace quota
  # forever. The PVC deliberately has no count (it is the persistent half); the pod must have it.
  count = data.coder_workspace.me.start_count
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
    # snake_case, not the API's camelCase — the provider schema for kubernetes_pod_v1 lists
    # automount_service_account_token under spec, and the camelCase form fails `tofu validate`.
    # The workspace pod has no business talking to the API server, and the coder server's own
    # ServiceAccount is what terraform runs as — not something a workspace should inherit by default.
    automount_service_account_token = false

    container {
      name  = "dev"
      image = data.coder_parameter.workspace_image.value

      # Boots as root, grants uid 1000 the nix store, drops, then runs the agent. This is the podman
      # template's approach and it is not cargo-culted: an initContainer cannot do this, because a
      # container's filesystem writes are invisible to its siblings — only volumes are shared — so
      # the chown has to happen in the same filesystem the agent will run in.
      #
      # The chowns are top-level on purpose. `chmod u+rwx /nix/store` lets uid 1000 add store paths,
      # which is what `nix-shell -p` and `home-manager switch` need; existing paths stay root-owned
      # and read-only, as they should be. A recursive chown of /nix/store is both slow and wrong.
      # /home/coder is chowned top-level only too — coder-templates learned that a recursive chown of
      # a home volume blocks agent start for minutes.
      #
      # The init script goes through a file because coder-templates found an inline version crashing
      # container creation during their live spike.
      command = ["sh", "-c", <<-EOS
        cat > /tmp/agent-init.sh <<'AGENTINIT'
        ${coder_agent.dev.init_script}
        AGENTINIT
        chmod +x /tmp/agent-init.sh
        chown 1000:1000 /nix /nix/store || echo 'store setup failed'
        chmod u+rwx /nix/store || true
        mkdir -p /nix/var/nix
        chown -R 1000:1000 /nix/var /nix/var/nix
        chown 1000:1000 /home/coder
        exec setpriv --reuid=1000 --regid=1000 --init-groups /tmp/agent-init.sh
      EOS
      ]
      working_dir = "/home/coder"

      # runAsUser 0 overrides the image's declared `User: 1000:1000` (read from the image config:
      # User=1000:1000, Cmd=/bin/sh, WorkingDir=/home/coder). setpriv then drops to 1000.
      #
      # This is why the pod will keep failing PodSecurity `restricted` and always will: restricted
      # demands runAsNonRoot *and* capabilities drop:[ALL], and setpriv --reuid needs CAP_SETUID.
      # You cannot drop a capability you are about to use. coder-workspaces is warn-only, so it
      # schedules; if that namespace is ever moved to enforce, this pod needs a different design —
      # an image that ships /nix owned by 1000, which coder-workspaces could not do at build time
      # because the CI builder's /nix/store is a read-only virtiofs share.
      security_context {
        run_as_user  = 0
        run_as_group = 0
      }

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

    # No securityContext on the container beyond runAsUser, deliberately. See the comment above for
    # why capabilities drop:[ALL] is not available to a container that must setpriv down.
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

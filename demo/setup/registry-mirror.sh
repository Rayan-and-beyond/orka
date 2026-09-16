#!/usr/bin/env bash
# Let ordinary Pods on the Substrate-built demo cluster pull the ACP runtime
# images.
#
# The conformance installer addresses those images by the shared registry's
# kind-network IP (172.18.x.x:5000), because gVisor Actors pull that way. The
# node's containerd only knows the registry as localhost:5001, so a plain Pod
# (an Agent Sandbox, or a non-workspace RuntimePool) fails with ErrImagePull.
# Register the IP form as a plain-HTTP mirror too. Idempotent.
set -euo pipefail
cluster=${KIND_CLUSTER:-orka-demos}
ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' kind-registry)
[[ -n $ip ]] || { echo "kind-registry is not on the kind network" >&2; exit 1; }
for node in $(kind get nodes --name "$cluster"); do
  docker exec "$node" sh -c "mkdir -p /etc/containerd/certs.d/$ip:5000 && cat > /etc/containerd/certs.d/$ip:5000/hosts.toml" <<TOML
server = "http://$ip:5000"

[host."http://$ip:5000"]
  capabilities = ["pull", "resolve"]
TOML
  echo "$node: $ip:5000 registered"
done

#!/usr/bin/env bash
# Deploy the clean-room Workspace/Publisher and the SCM egress proxy onto the
# Substrate-built demo cluster.
#
# The conformance installer deliberately leaves both out (it validates the
# workspace provider, not publication). The demos open real pull requests, so
# they need them: the Publisher is the only component that ever holds a Git
# credential, and the egress proxy is the only path it may push through.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
: "${KUBECONFIG:?scoped kubeconfig of the demo cluster}"
publisher_image=${WORKSPACE_PUBLISHER_IMG:-localhost:5001/orka/workspace-publisher:demo}

# The proxy binary ships in the controller image; use the digest the cluster runs.
controller_image=$(kubectl -n orka-system get deployment orka-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}')
[[ -n $controller_image ]] || { echo "controller image not found" >&2; exit 1; }
docker push "$publisher_image" >/dev/null 2>&1 || true
publisher_ref=$(docker inspect --format '{{index .RepoDigests 0}}' "$publisher_image")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R config "$tmp/config"
mkdir -p "$tmp/config/demo-publisher"
cat >"$tmp/config/demo-publisher/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: orka-system
namePrefix: orka-
resources:
  - ../publisher
  - ../scm-egress-proxy
images:
  - name: docker.io/sozercan/orka-workspace-publisher
    newName: ${publisher_ref%@*}
    digest: ${publisher_ref##*@}
  - name: ghcr.io/orka-agents/orka
    newName: ${controller_image%@*}
    digest: ${controller_image##*@}
YAML
make kustomize >/dev/null
bin/kustomize build "$tmp/config/demo-publisher" | kubectl apply -f -
kubectl -n orka-system rollout status deployment/orka-scm-egress-proxy --timeout=3m
kubectl -n orka-system rollout status deployment/orka-workspace-publisher --timeout=3m

# The conformance installer renders the manager container without the
# Publisher URL (it never publishes). Without it every repository Task fails
# closed with "clean-room Workspace/Publisher and artifact authorization are
# required". The token and capability mounts are already present.
kubectl -n orka-system set env deployment/orka-controller-manager -c manager \
  ORKA_WORKSPACE_PUBLISHER_URL=http://orka-workspace-publisher.orka-system.svc:8080
kubectl -n orka-system rollout status deployment/orka-controller-manager --timeout=5m

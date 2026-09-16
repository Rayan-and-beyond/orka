#!/usr/bin/env bash
# Build and pin the immutable ACP runtime images the demos use, on the
# Substrate-flavored demo cluster.
#
# The conformance installer pins only the Codex runtime. The demos also use
# the Claude runtime (the reviewer Agent), so build it the same way: push to
# the shared kind registry, take the digest, and address it by the registry's
# kind-network IP, which is what both gVisor Actors and ordinary Pods on this
# cluster pull from. The controller reads the refs from the acp-runtime-images
# ConfigMap; restart it so the new value applies.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
: "${KUBECONFIG:?scoped kubeconfig of the demo cluster}"
port=${KIND_REGISTRY_PORT:-5001}
runtimes=${*:-claude}

registry_ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' kind-registry)
[[ -n $registry_ip ]] || { echo "kind-registry is not on the kind network" >&2; exit 1; }

for runtime in $runtimes; do
  image="localhost:${port}/orka/acp-${runtime}-runtime:demo"
  var=$(printf 'ACP_%s_RUNTIME_IMG' "$(tr '[:lower:]' '[:upper:]' <<<"$runtime")")
  echo "==> building $image"
  make "docker-build-acp-${runtime}-runtime" "${var}=${image}" >/dev/null
  docker push "$image" >/dev/null
  ref=$(docker inspect --format '{{index .RepoDigests 0}}' "$image")
  ref=${ref/localhost:${port}/${registry_ip}:5000}
  key=$(printf 'ORKA_ACP_%s_RUNTIME_IMAGE' "$(tr '[:lower:]' '[:upper:]' <<<"$runtime")")
  echo "==> pinning $key=$ref"
  kubectl -n orka-system patch configmap acp-runtime-images --type=merge -p "{\"data\":{\"$key\":\"$ref\"}}"
done
kubectl -n orka-system rollout restart deployment/orka-controller-manager
kubectl -n orka-system rollout status deployment/orka-controller-manager --timeout=5m

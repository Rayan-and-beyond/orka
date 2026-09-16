#!/usr/bin/env bash
# Build the one kind cluster every demo records against.
#
# Layers, in order:
#   1. Agent Substrate on a gVisor kind cluster, plus Orka wired to it
#      (hack/demos/cluster/install-substrate.sh, which runs the same
#      conformance suite CI does and keeps the cluster).
#   2. A real model proxy (vekil) seeded from an already-authenticated cluster,
#      replacing the fixture the conformance suite installed.
#   3. The Provider, worker images, and Git Secret (install-demo-model.sh).
#   4. kubernetes-sigs Agent Sandbox and its runtime image (install-agent-sandbox.sh).
#   5. The demo's own Agents, workspace classes, and client identity.
#
# Idempotent where the underlying installers are. Takes about an hour.
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

export KIND_CLUSTER=${KIND_CLUSTER:-orka-demos}
export SUBSTRATE_E2E_RUN_DIR=${SUBSTRATE_E2E_RUN_DIR:-$repo_root/bin/substrate-eval}
# Private Go caches: a shared build box may prune the default ones mid-build.
export GOMODCACHE=${GOMODCACHE:-$repo_root/.gocache/mod}
export GOCACHE=${GOCACHE:-$repo_root/.gocache/build}
mkdir -p "$GOMODCACHE" "$GOCACHE"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "1/5 Agent Substrate + Orka (conformance suite, cluster kept)"
if kind get clusters | grep -qx "$KIND_CLUSTER"; then
  DEMO_CLUSTER_REUSE=reuse bash hack/demos/cluster/install-substrate.sh
else
  bash hack/demos/cluster/install-substrate.sh
fi
export KUBECONFIG=$SUBSTRATE_E2E_RUN_DIR/kubeconfig

step "2/5 real model proxy"
: "${SOURCE_KUBECONFIG:?kubeconfig of a cluster whose vekil is already logged in}"
kubectl -n vekil-system delete deployment vekil --ignore-not-found
kubectl -n vekil-system delete service vekil --ignore-not-found
SOURCE_KUBECONFIG=$SOURCE_KUBECONFIG bash demo/setup/vekil-auth.sh

step "3/5 Provider, worker images, Git Secret"
ORKA_DEMO_CLUSTER=$KIND_CLUSTER DEMO_PROVIDER_REF=copilot DEMO_PROVIDER_SECRET_REF=copilot-key \
  DEMO_AI_MODEL=claude-opus-5 DEMO_RUNTIME_SECRET_REF=copilot-runtime-key \
  bash hack/demos/cluster/install-demo-model.sh

step "4/5 Agent Sandbox"
ORKA_DEMO_CLUSTER=$KIND_CLUSTER ORKA_SANDBOX_CLEANUP_POLICY=delete AGENTIC=1 \
  bash hack/demos/cluster/install-agent-sandbox.sh

step "5/5 demo resources"
kubectl apply -f demo/setup/resources/client-rbac.yaml
kubectl apply -f demo/setup/resources/agents.yaml
kubectl apply -f demo/setup/resources/workspace-classes.yaml
cp "$SUBSTRATE_E2E_RUN_DIR/kubectl-ate" demo/setup/state/kubectl-ate 2>/dev/null || true
printf 'cluster ready; KUBECONFIG=%s\n' "$KUBECONFIG"

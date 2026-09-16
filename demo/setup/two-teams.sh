#!/usr/bin/env bash
# Two namespace-scoped Orka installations plus the shared compatibility
# router from PR #604, for demo 05.
#
# Requires a controller image that contains /compat-router (built from a
# checkout that includes the PR) and the demo cluster's general worker image.
#
#   CONTROLLER_IMAGE=localhost:5001/orka/controller@sha256:... demo/setup/two-teams.sh
set -euo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
: "${KUBECONFIG:?scoped kubeconfig of the demo cluster}"
: "${CONTROLLER_IMAGE:?controller image containing /compat-router}"
worker_image=${WORKER_IMAGE:-$(kubectl -n orka-system get deploy orka-controller-manager -o json |
  jq -r '.spec.template.spec.containers[0].args[] | select(startswith("--general-worker-image=")) | sub("^--general-worker-image=";"")')}
router_src=${ROUTER_MANIFEST:-config/compat-router/router.yaml}
[[ -f $router_src ]] || { echo "router manifest $router_src not found (checkout must include PR #604)" >&2; exit 1; }

# Worker Pods need a ClusterRole to exist under this name; it grants nothing.
kubectl apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: compat-worker
rules: []
YAML

team() {
  local ns=$1 provider=$2 model=$3 developer=$4
  sed -e "s#CONTROLLER_IMAGE#$CONTROLLER_IMAGE#g" -e "s#WORKER_IMAGE#$worker_image#g" \
      -e "s/TEAM-runtimes/$ns-runtimes/g" -e "s/compat-TEAM/compat-$ns/g" -e "s/TEAM/$ns/g" \
      -e "s/PROVIDER/$provider/g" -e "s/MODEL/$model/g" -e "s/DEVELOPER/$developer/g" \
      demo/05-two-teams/setup/team.yaml | kubectl apply -f -
  # The snapshot key is per installation and never printed.
  if ! kubectl -n "$ns" get secret snapshot-key >/dev/null 2>&1; then
    umask 077; local key; key=$(mktemp); openssl rand 32 >"$key"
    kubectl -n "$ns" create secret generic snapshot-key --from-file=key="$key"; rm -f "$key"
  fi
  kubectl -n "$ns" create secret generic provider-key --from-literal=api-key=proxy-placeholder \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" rollout status deployment/orka-controller --timeout=5m
}
team team-payments approved-models claude-opus-4.7 alice
team team-inventory openai gpt-5.5 bob

# The cluster keeps one platform-owned admission webhook. It only lets
# registered controller identities write Task status, so each team's
# controller is registered with it; that is the platform team's one shared
# decision per team.
echo "==> registering team controllers with the shared admission webhook"
kubectl -n orka-system get deploy orka-admission -o json |
  jq --arg add "system:serviceaccount:team-payments:controller,system:serviceaccount:team-inventory:controller" '
    .spec.template.spec.containers[0].args |= map(
      if (startswith("--controller-usernames=") or startswith("--task-provenance-trusted-users=")) and (contains("team-payments") | not)
      then . + "," + $add else . end)' |
  kubectl apply -f - >/dev/null
kubectl -n orka-system rollout status deploy/orka-admission --timeout=3m

echo "==> router"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 - "$router_src" "$CONTROLLER_IMAGE" >"$tmp/router.yaml" <<'PY'
import sys, re
src, image = sys.argv[1], sys.argv[2]
text = open(src).read()
text = text.replace("image: controller:latest", f"image: {image}")
text = re.sub(r"namespaces:\n(?:      .*\n)+",
              "namespaces:\n      team-payments: http://orka-api.team-payments.svc:8080\n      team-inventory: http://orka-api.team-inventory.svc:8080\n",
              text)
sys.stdout.write(text)
PY
kubectl apply -f "$tmp/router.yaml"
kubectl -n orka-router-system rollout status deployment/orka-compat-router --timeout=3m
echo "==> two teams ready"

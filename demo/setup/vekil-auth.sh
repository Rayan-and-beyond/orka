#!/usr/bin/env bash
# Copy an already-authenticated vekil token cache from one cluster's PVC into
# the demo cluster, then deploy vekil on top of it. Lets a demo cluster reuse
# a GitHub Copilot login that a person completed elsewhere, without anyone
# reading or printing the token.
#
#   SOURCE_KUBECONFIG=~/.kube/kind/other.kubeconfig KUBECONFIG=... demo/setup/vekil-auth.sh
set -euo pipefail
: "${SOURCE_KUBECONFIG:?path to the kubeconfig of the cluster that has an authenticated vekil}"
: "${KUBECONFIG:?path to the demo cluster kubeconfig}"
ns=${VEKIL_NAMESPACE:-vekil-system}
pvc=${VEKIL_PVC:-vekil-auth}
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

reader() {
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: {name: vekil-auth-copy, namespace: $ns}
spec:
  restartPolicy: Never
  securityContext: {fsGroup: 65532}
  containers:
    - name: c
      image: busybox:1.36
      command: [sleep, "600"]
      volumeMounts: [{name: cache, mountPath: /cache}]
  volumes:
    - name: cache
      persistentVolumeClaim: {claimName: $pvc}
YAML
}

echo "==> reading the token cache from the source cluster"
kubectl --kubeconfig "$SOURCE_KUBECONFIG" -n "$ns" delete pod vekil-auth-copy --ignore-not-found >/dev/null
reader | kubectl --kubeconfig "$SOURCE_KUBECONFIG" apply -f - >/dev/null
kubectl --kubeconfig "$SOURCE_KUBECONFIG" -n "$ns" wait --for=condition=Ready pod/vekil-auth-copy --timeout=120s >/dev/null
kubectl --kubeconfig "$SOURCE_KUBECONFIG" -n "$ns" exec vekil-auth-copy -- tar -C /cache -cf - . >"$work/cache.tar"
kubectl --kubeconfig "$SOURCE_KUBECONFIG" -n "$ns" delete pod vekil-auth-copy --wait=false >/dev/null

echo "==> seeding the demo cluster's $pvc"
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
YAML
kubectl -n "$ns" delete pod vekil-auth-copy --ignore-not-found >/dev/null
reader | kubectl apply -f - >/dev/null
kubectl -n "$ns" wait --for=condition=Ready pod/vekil-auth-copy --timeout=120s >/dev/null
kubectl -n "$ns" exec -i vekil-auth-copy -- tar -C /cache -xf - <"$work/cache.tar"
kubectl -n "$ns" exec vekil-auth-copy -- chown -R 65532:65532 /cache
kubectl -n "$ns" delete pod vekil-auth-copy --wait=true >/dev/null

echo "==> deploying vekil on the seeded volume"
bash "$repo_root/.claude/skills/vekil-reverse-proxy-deploy/scripts/deploy_vekil_reverse_proxy.sh" \
  --context "$(kubectl config current-context)" --namespace "$ns" --token-pvc "$pvc" --skip-wait
# Orka's provider-proxy NetworkPolicies (and the Substrate worker policy)
# admit the model endpoint by label. The fixture the conformance suite installs
# carries app.kubernetes.io/component=responses-fixture; give the real proxy
# the same label so the existing policies keep applying.
kubectl -n "$ns" patch deploy vekil --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"app.kubernetes.io/component":"responses-fixture"}}}}}'
kubectl -n "$ns" rollout status deploy/vekil --timeout=180s
echo "==> ready:"
kubectl -n "$ns" port-forward svc/vekil 19337:1337 >/dev/null 2>&1 &
pf=$!
sleep 3
curl -fsS -m 10 http://127.0.0.1:19337/readyz; echo
kill $pf

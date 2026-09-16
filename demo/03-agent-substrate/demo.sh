#!/usr/bin/env bash
# Orka — an agent that is not a Pod
# Codex runs as a gVisor Actor on Agent Substrate. Suspend keeps data only; a checkpoint survives deletion.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/03-agent-substrate
atespace=orka-system
: "${ATE_BIN:=$demo_root/setup/state/kubectl-ate}"
[[ -x $ATE_BIN ]] || ATE_BIN=$repo_root/bin/substrate-eval/kubectl-ate
export ATE_BIN
# `kubectl ate` is Substrate's kubectl plugin. The demo types it that way; the
# function resolves the plugin binary the setup built.
kubectl() {
  if [[ ${1:-} == ate ]]; then
    shift
    "$ATE_BIN" "$@"
  else
    command kubectl "$@"
  fi
}

branch=orka/security-audit
ensure_port_forward
orka_connect
peq "orka session delete inventory-audit"
peq "kubectl -n $ORKA_NAMESPACE delete tasks -l demo.orka.ai/name=03-agent-substrate --wait=true"
peq "git ls-remote --exit-code $DEMO_REPO refs/heads/$branch && git push $DEMO_REPO --delete $branch"
peq "kubectl -n $ORKA_NAMESPACE delete executionworkspacecheckpoints -l demo.orka.ai/name=03-agent-substrate --wait=true"
peq "kubectl -n $ORKA_NAMESPACE delete executionworkspaces -l demo.orka.ai/name=03-agent-substrate --wait=true"

workspace_of() {
  kubectl -n "$ORKA_NAMESPACE" get task "$1" \
    -o jsonpath='{.metadata.labels.acp\.workspace\.orka\.ai/execution-workspace}' 2>/dev/null
}
actor_count() {
  kubectl ate get actors -a "$atespace" -o json 2>/dev/null | jq '.actors | length'
}
actor_uid() {
  kubectl ate get actors -a "$atespace" -o json 2>/dev/null | jq -r '.actors[0].metadata.uid // empty'
}
ws_state() {
  kubectl -n "$ORKA_NAMESPACE" get executionworkspace "$1" -o jsonpath='{.status.state}' 2>/dev/null
}

banner "Orka — an agent that is not a Pod" \
  "Codex runs as a gVisor Actor on Agent Substrate. Suspend keeps data only. A checkpoint survives deletion."

chapter "Actors, not Pods"

say "Agent Substrate runs each agent as an Actor: a gVisor sandbox with its own"
say "kernel, started and stopped in milliseconds. Actors live in an Atespace."
say "kubectl get pods will never show you one."
pe "kubectl ate get actors -a $atespace"
say "Orka's class for this provider: one Actor per Session, keep only data on"
say "detach, and allow checkpoints."
pe "kubectl -n orka-system get executionworkspaceclass substrate-session -o jsonpath='{.spec.lifecycle}' | jq"

chapter "Turn 1 — audit the code inside an Actor"

pe "sed -n '12,36p' $here/manifests/turn-1-audit.yaml"
pe "orka task create -f $here/manifests/turn-1-audit.yaml"
wait_for "an Actor to boot" "(( \$(actor_count) >= 1 ))" 600
pe "kubectl ate get actors -a $atespace"
first_actor=$(actor_uid)
say "That Actor is the agent's whole world: a fresh kernel, a durable volume,"
say "and a network path only to the model proxy. No Git credential rides along."
wait_task audit-write 1200
pe "orka task result audit-write"
say "The Actor never pushed. Orka's Publisher verified the tree and published"
say "the branch; the receipt is on the Task."
pe "orka task status audit-write | grep -E 'Delivery|Publication|Verified'"
pe "git ls-remote $DEMO_REPO refs/heads/$branch"
ok "AUDIT.md is on the Actor's durable volume and on a published branch."

chapter "Suspend keeps the data, not the process"

ws=$(workspace_of audit-write)
say "On detach the class says DataOnly: the Actor's data is captured and the"
say "Actor itself goes away. Nothing keeps running while nobody is asking."
wait_for "the workspace to suspend" "[[ \$(ws_state $ws) == Suspended ]]" 600
pe "kubectl -n orka-system get executionworkspace $ws"
pe "kubectl ate get actors -a $atespace"
ok "Zero Actors. Zero compute. The data is kept."

chapter "Turn 2 — a fresh Actor boots from the kept data"

say "A read-only turn in the same Session: print what is on disk."
pe "orka task create -f $here/manifests/turn-2-read.yaml"
wait_for "a new Actor to boot" "(( \$(actor_count) >= 1 ))" 600
pe "kubectl ate get actors -a $atespace"
second_actor=$(actor_uid)
[[ -n $second_actor && $second_actor != "$first_actor" ]] ||
  { bad "expected a new Actor, got ${second_actor:-none}"; exit 1; }
ok "A different Actor UID: cold boot from data, not a thawed process."
wait_task audit-read 1200
pe "orka task result audit-read"
say "The audit written by the first Actor was there for the second. Nothing"
say "was re-cloned: the working tree came from the kept data."

chapter "Export a checkpoint"

wait_for "the workspace to suspend again" "[[ \$(ws_state $ws) == Suspended ]]" 600
ws_uid=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspace "$ws" -o jsonpath='{.metadata.uid}')
sed "s/WORKSPACE_NAME/$ws/; s/WORKSPACE_UID/$ws_uid/" "$here/manifests/checkpoint.yaml" >"$demo_root/setup/state/03-checkpoint.yaml"
say "A checkpoint is an object of its own, bound to the exact workspace UID."
pe "cat $demo_root/setup/state/03-checkpoint.yaml"
pe "kubectl apply -f $demo_root/setup/state/03-checkpoint.yaml"
wait_for "the checkpoint to be Ready" \
  "[[ \$(kubectl -n $ORKA_NAMESPACE get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.status.phase}') == Ready ]]" 600
pe "kubectl -n orka-system get executionworkspacecheckpoint audit-checkpoint -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,DIGEST:.status.digest"

chapter "Delete everything, then restore"

say "Delete the Session's workspace. The Actor data it kept is gone with it."
pe "kubectl -n orka-system delete executionworkspace $ws --wait=false"
wait_for "the workspace to disappear" "! kubectl -n $ORKA_NAMESPACE get executionworkspace $ws >/dev/null 2>&1" 600
pe "kubectl -n orka-system get executionworkspaces"
say "A brand-new Task restores from the checkpoint. It names the checkpoint's"
say "UID and digest, so a swapped checkpoint is refused."
cp_uid=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.metadata.uid}')
cp_digest=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.status.digest}')
sed "s/CHECKPOINT_UID/$cp_uid/; s/CHECKPOINT_DIGEST/$cp_digest/" "$here/manifests/turn-3-restore.yaml" >"$demo_root/setup/state/03-restore.yaml"
pe "sed -n '14,25p' $demo_root/setup/state/03-restore.yaml"
pe "orka task create -f $demo_root/setup/state/03-restore.yaml"
wait_task audit-restore 1200
pe "orka task result audit-restore"
ok "The file written by an Actor that no longer exists, in a workspace that was deleted, came back byte for byte."

chapter "Clean up"

pe "kubectl -n orka-system delete executionworkspacecheckpoint audit-checkpoint"
peq "git push $DEMO_REPO --delete $branch"
wait_for "the restored workspace to be collected" \
  "[[ -z \$(kubectl -n $ORKA_NAMESPACE get executionworkspaces -l demo.orka.ai/name=03-agent-substrate --no-headers 2>/dev/null) ]]" 600 || true
pe "kubectl ate get actors -a $atespace"
printf '\n'

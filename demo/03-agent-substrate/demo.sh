#!/usr/bin/env bash
# Orka — a save point for an agent
# An audit runs in a gVisor sandbox on Agent Substrate. Pause it, resume it, save a copy, restore the copy.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/03-agent-substrate
atespace=orka-system
pool_ns=${SUBSTRATE_POOL_NAMESPACE:-ate-demo}
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
# Session names are unique per run: a Session that is still archiving from
# the previous recording cannot be reused, and a fresh name reads better than
# a wait. The rendered manifests are what the viewer sees.
run_id=$(date -u +%H%M)
session=audit-$run_id
rendered=$demo_root/setup/state/03-agent-substrate
mkdir -p "$rendered"
for m in $here/manifests/*.yaml; do
  sed "s/SESSION_NAME/$session/" "$m" >"$rendered/$(basename "$m")"
done
ensure_port_forward
orka_connect
delete_demo_objects 03-agent-substrate
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch"
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch-restored"

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
# One line per Actor: name, state, and the worker Pod hosting it.
actors="kubectl ate get actors -a $atespace -o json | jq -r '(.actors // [])[] | [.metadata.name, (.status.state | sub(\"ACTOR_STATE_\"; \"\")), (.status.workerAssignment.workerPod // \"-\")] | @tsv' | column -t | grep . || echo 'no Actors'"

banner "Orka — a save point for an agent" \
  "An audit runs in a gVisor sandbox on Agent Substrate. Pause it, resume it, save a copy, restore the copy."

chapter "The scenario"

say "The security team wants the inventory service audited for input"
say "validation gaps. An audit is not a single request: someone starts it,"
say "someone else picks it up later, and the findings need to be kept."
say ""
say "That raises three problems. Nothing should keep running, or cost money,"
say "while nobody is working. The next person needs to find the files where"
say "the last one left them. And the state should survive even if the"
say "workspace is deleted. This demo shows all three."

chapter "Actors and workers"

say "Agent Substrate is a different kind of host for an agent. Instead of one"
say "Pod per agent, it keeps a small pool of worker Pods running all the time."
pe "kubectl -n $pool_ns get workerpools"
pe "kubectl ate get workers"
say "Each agent runs in an Actor: a sandbox with its own kernel, from gVisor,"
say "that any free worker can host. An Actor can be frozen to storage and"
say "thawed later on whichever worker is free. Right now there are none."
pe "$actors"
say "Orka's class for this host says: one Actor per Session, suspend when the"
say "agent stops, and remove everything when the workspace is deleted."
pe "kubectl -n orka-system get executionworkspaceclass substrate-session -o jsonpath='{.spec.lifecycle}' | jq"
note "Data, not memory. The next request boots a fresh Actor from the kept files. The Actor's name will change; the files will not."

chapter "The first request"

say "The request is a Task. It opens a Session, asks for the substrate-session"
say "class, and points at the repository."
pe "sed -n '13,23p' $rendered/first-request.yaml"
pe "sed -n '37,42p' $rendered/first-request.yaml"
pe "orka task create -f $rendered/first-request.yaml"
pe "orka session list"
say "Orka creates an Actor for the Session and Substrate places it on a worker."
wait_for "an Actor to boot" "(( \$(actor_count) >= 1 ))" 600
pe "$actors"
pe "kubectl ate get workers"
first_actor=$(actor_uid)
say "That Actor is the agent's whole world: a fresh kernel, a durable volume,"
say "and a network path only to Orka's model proxy. No Git credential rides"
say "along; the Publisher holds that, outside the sandbox."
wait_task audit-start 1200
pe "orka task result audit-start"
say "The Publisher verified the tree and published the audit as a branch."
say "The receipt is on the Task."
pe "orka task status audit-start | grep -E 'Delivery|Publication|Verified'"
pe "git ls-remote $DEMO_REPO refs/heads/$branch"

chapter "The workspace sleeps"

ws=$(workspace_of audit-start)
say "The agent is done and the Session is idle. The class said Suspend, so"
say "Orka has Substrate capture the Actor's data to storage, then removes the"
say "Actor and retires the worker Pod that hosted it. The pool replaces that"
say "Pod with a clean one, so the next agent never inherits a used worker."
wait_for "the workspace to suspend" "[[ \$(ws_state $ws) == Suspended ]]" 600
pe "kubectl -n orka-system get executionworkspace $ws"
pe "$actors"
pe "kubectl ate get workers"
ok "Zero Actors, three free workers, one of them brand new. The audit's files are kept in storage."

chapter "A follow-up in the same Session"

say "A colleague picks the audit up. Their request names the same Session and"
say "asks to read what is there."
pe "sed -n '14,18p;37,39p' $rendered/follow-up-request.yaml"
pe "orka task create -f $rendered/follow-up-request.yaml"
wait_for "a new Actor to boot" "(( \$(actor_count) >= 1 ))" 600
pe "$actors"
second_actor=$(actor_uid)
[[ -n $second_actor && $second_actor != "$first_actor" ]] ||
  { bad "expected a new Actor, got ${second_actor:-none}"; exit 1; }
ok "A different Actor, on whichever worker was free, booted from the kept data."
wait_task audit-follow-up 1200
pe "orka task result audit-follow-up"
say "AUDIT.md was written by an Actor that no longer exists, and the new one"
say "found it. Nothing was re-cloned: the working tree came from the kept data."

chapter "Save a checkpoint"

wait_for "the workspace to suspend again" "[[ \$(ws_state $ws) == Suspended ]]" 600
ws_uid=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspace "$ws" -o jsonpath='{.metadata.uid}')
sed "s/WORKSPACE_NAME/$ws/; s/WORKSPACE_UID/$ws_uid/" "$rendered/checkpoint.yaml" >"$demo_root/setup/state/03-checkpoint.yaml"
say "A checkpoint is a copy of the workspace's data that Orka keeps as an"
say "object of its own, with a digest. It points at the exact workspace by"
say "UID, and it survives that workspace being deleted."
pe "cat $demo_root/setup/state/03-checkpoint.yaml"
pe "kubectl apply -f $demo_root/setup/state/03-checkpoint.yaml"
wait_for "the checkpoint to be Ready" \
  "[[ \$(kubectl -n $ORKA_NAMESPACE get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.status.phase}') == Ready ]]" 600
pe "kubectl -n orka-system get executionworkspacecheckpoint audit-checkpoint -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,DIGEST:.status.digest"

chapter "Delete the original, restore the copy"

say "Now the worst case: the Session's workspace is deleted, and with it the"
say "data Substrate kept for it."
pe "kubectl -n orka-system delete executionworkspace $ws --wait=false"
wait_for "the workspace to disappear" "! kubectl -n $ORKA_NAMESPACE get executionworkspace $ws >/dev/null 2>&1" 600
pe "kubectl -n orka-system get executionworkspaces"
say "A brand-new Task, outside the old Session, restores from the checkpoint."
say "It names the checkpoint's UID and digest, so a swapped or tampered"
say "checkpoint is refused."
cp_uid=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.metadata.uid}')
cp_digest=$(kubectl -n "$ORKA_NAMESPACE" get executionworkspacecheckpoint audit-checkpoint -o jsonpath='{.status.digest}')
sed "s/CHECKPOINT_UID/$cp_uid/; s/CHECKPOINT_DIGEST/$cp_digest/" "$rendered/restore-request.yaml" >"$demo_root/setup/state/03-restore.yaml"
pe "sed -n '17,25p' $demo_root/setup/state/03-restore.yaml"
pe "orka task create -f $demo_root/setup/state/03-restore.yaml"
wait_task audit-restore 1200
pe "orka task result audit-restore"
ok "The audit came back byte for byte: from a deleted workspace, written by an Actor that is long gone."
say "The restored tree is a real workspace again, so Orka verified it and"
say "published it to its own branch."
pe "orka task status audit-restore | grep -E 'Delivery|Publication'"

chapter "Clean up"

pe "kubectl -n orka-system delete executionworkspacecheckpoint audit-checkpoint"
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch"
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch-restored"
wait_for "the restored workspace to be collected" \
  "[[ -z \$(kubectl -n $ORKA_NAMESPACE get executionworkspaces -l demo.orka.ai/name=03-agent-substrate --no-headers 2>/dev/null) ]]" 600 || true
pe "$actors"
pe "kubectl ate get workers"

chapter "What you saw"

say "One Session, two requests, two Actors, one set of files. Between the"
say "requests nothing ran and every worker was free."
say "A checkpoint outlived the workspace it came from, and a new Task"
say "restored it. Substrate did the freezing and thawing; Orka decided when,"
say "and kept the receipts."
printf '\n'

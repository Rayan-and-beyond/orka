#!/usr/bin/env bash
# Orka — a workspace that sleeps
# An agent gets a place to work, keeps it between requests, and costs nothing while it waits.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/02-agent-sandbox
runtime_ns=${ORKA_RUNTIME_NAMESPACE:-orka-runtimes}
branch=orka/healthz-from-sandbox
export runtime_ns

# Session names are unique per run: a Session that is still archiving from
# the previous recording cannot be reused, and a fresh name reads better than
# a wait. The rendered manifests are what the viewer sees.
run_id=$(date -u +%H%M)
session=inventory-$run_id
rendered=$demo_root/setup/state/02-agent-sandbox
mkdir -p "$rendered"
for m in $here/manifests/*.yaml; do
  sed "s/SESSION_NAME/$session/" "$m" >"$rendered/$(basename "$m")"
done
ensure_port_forward
orka_connect
delete_demo_objects 02-agent-sandbox
peq "gh pr list --repo sozercan/orka-demo-inventory --head $branch --json number --jq '.[].number' | xargs -I{} gh pr close {} --repo sozercan/orka-demo-inventory --delete-branch"
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch"

workspace_of() {
  kubectl -n "$ORKA_NAMESPACE" get task "$1" \
    -o jsonpath='{.metadata.labels.acp\.workspace\.orka\.ai/execution-workspace}' 2>/dev/null
}
# The Sandbox that belongs to this Session's runtime pool, not any that lingers.
sandbox_name() {
  local pool
  pool=$(kubectl -n "$ORKA_NAMESPACE" get task healthz-implement -o jsonpath='{.status.execution.runtimePoolName}' 2>/dev/null)
  [[ -n $pool ]] || return 0
  kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io -o json 2>/dev/null |
    jq -r --arg pool "$pool" '[.items[] | select(.metadata.name | startswith($pool))][0].metadata.name // empty'
}
sandbox_mode() {
  kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$1" -o jsonpath='{.spec.operatingMode}' 2>/dev/null
}
sandbox_cols=NAME:.metadata.name,MODE:.spec.operatingMode,UID:.metadata.uid

banner "Orka — a workspace that sleeps" \
  "An agent gets a place to work, keeps it between requests, and costs nothing while it waits."

chapter "The scenario"

say "A small team runs an inventory service. It has no health check, so a"
say "developer is going to ask an agent to add one today and to check on the"
say "work tomorrow."
say ""
say "An agent needs a place to work: a checkout of the repository and a process"
say "to run in. On Kubernetes that is a Pod, and a Pod leaves two bad options."
say "Keep it running and pay for an idle agent, or delete it and lose"
say "everything it did. This demo shows the third option."

chapter "Three words"

say "Session: a conversation Orka remembers. Every request in a Session shares"
say "one workspace, so a follow-up finds what the previous request left behind."
say ""
say "Sandbox: a small Kubernetes object from the kubernetes-sigs Agent Sandbox"
say "project. It owns a Pod and a disk, and the disk outlives the Pod."
say ""
say "Workspace class: the platform team's menu. A Task asks for a class by"
say "name; the class says who hosts the workspace and what happens to it when"
say "the agent stops."
pe "kubectl -n orka-system get executionworkspaceclasses"
pe "kubectl -n orka-system get executionworkspaceclass sandbox-session -o jsonpath='{.spec.lifecycle}' | jq"
note "defaultOnDetach: Suspend. When the agent finishes, put the Sandbox to sleep and keep its disk."
say "Before the first request, nothing is running for this team."
pe "kubectl -n $runtime_ns get sandboxes,pods,pvc"

chapter "The first request"

say "A request to Orka is a Task. Three parts matter here: the Session it opens,"
say "the class it asks for, and the repository it works on. It never names a"
say "template, a claim, or a Pod."
pe "sed -n '13,23p' $rendered/first-request.yaml"
say "The rest of the spec is the repository, the branch to publish, and the ask."
pe "sed -n '41,46p' $rendered/first-request.yaml"
pe "orka task create -f $rendered/first-request.yaml"
say "The Session now exists. Later requests will name it."
pe "orka session list"
say "Orka asks Agent Sandbox for a Sandbox built from the platform team's"
say "template. Watch the objects appear."
wait_for "the Sandbox to exist" "[[ -n \$(sandbox_name) ]]" 300
sb=$(sandbox_name)
pod=$sb
wait_for "the Sandbox Pod" "kubectl -n $runtime_ns get pod $pod --no-headers 2>/dev/null | grep -q Running" 300
pe "kubectl -n $runtime_ns get sandboxes,pods,pvc"
sb_uid=$(kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$sb" -o jsonpath='{.metadata.uid}')
say "One Sandbox, one Pod, one small disk. The Pod runs the coding agent and"
say "nothing else: no Git token and no model key are mounted or exported."
pe "kubectl -n $runtime_ns exec $pod -- env | grep -E '^(GH_TOKEN|GITHUB_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)=' || echo 'no provider or Git credential in the environment'"
say "Its network is closed by default. Orka adds the few paths it needs: DNS,"
say "the model proxy that holds the key, and the controller. Not GitHub."
pool_key=$(kubectl -n "$runtime_ns" get pod "$pod" -o jsonpath='{.metadata.labels.orka\.ai/runtime-pool-key}')
pe "kubectl -n $runtime_ns get networkpolicies -l orka.ai/runtime-pool-key=$pool_key -o json | jq -r '.items[].metadata.name | sub(\"^acp-ws-[^-]+-[0-9a-f]+-[0-9a-f]+-\"; \"\")'"
say "Now the agent works. Orka records what it does as execution events."
wait_task healthz-implement 1800
pe "orka task events healthz-implement | grep ModelMessage | tail -n 2 | cut -c1-300"
pe "orka task result healthz-implement | tail -n 20"
say "The agent changed files but never pushed. Orka's Publisher, a separate"
say "component that does hold a Git token, verified the tree, published the"
say "branch, and opened the pull request. The receipt is on the Task."
pe "orka task status healthz-implement"
pr=$(gh pr list --repo sozercan/orka-demo-inventory --head "$branch" --json url --jq '.[0].url')
assert_pr "$pr"
pe "gh pr view $pr --json title,url,headRefName --jq '{title,url,branch:.headRefName}'"

chapter "The workspace sleeps"

ws=$(workspace_of healthz-implement)
say "The agent is done and the Session is idle. The class said Suspend, so"
say "Orka asks Agent Sandbox to switch the Sandbox to Suspended: the Pod goes"
say "away, the disk stays."
wait_for "the workspace to suspend" \
  "[[ \$(kubectl -n $ORKA_NAMESPACE get executionworkspace $ws -o jsonpath='{.status.state}') == Suspended ]]" 600
pe "kubectl -n orka-system get executionworkspace $ws"
pe "kubectl -n $runtime_ns get sandbox $sb -o custom-columns=$sandbox_cols"
pe "kubectl -n $runtime_ns get pods -o name | grep sandbox || echo 'no Sandbox Pod'"
pe "kubectl -n $runtime_ns get pvc -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.status.capacity.storage"
ok "No Pod, so no CPU or memory bill. The disk with the agent's work is Bound and waiting."
say "operatingMode is the field a platform team would flip by hand to sleep a"
say "Sandbox. Orka flipped it because the class told it to."

chapter "A follow-up in the same Session"

say "Tomorrow the developer asks what changed. The follow-up names the same"
say "Session, and that is the only thing that ties it to yesterday's work."
pe "sed -n '13,17p;40,42p' $rendered/follow-up-request.yaml"
pe "orka task create -f $rendered/follow-up-request.yaml"
wait_for "the Sandbox to wake" "[[ \$(sandbox_mode $sb) == Running ]]" 600
pe "kubectl -n $runtime_ns get sandbox $sb -o custom-columns=$sandbox_cols"
[[ $(kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$sb" -o jsonpath='{.metadata.uid}') == "$sb_uid" ]] ||
  { bad "the resumed Sandbox is not the one the first request used"; exit 1; }
ok "Same Sandbox, same UID. Agent Sandbox switched it back to Running and a new Pod started on the kept disk."
wait_task healthz-follow-up 1200
pe "orka task result healthz-follow-up"
pe "orka task status healthz-follow-up | grep -E 'Delivery|Phase'"
ok "The endpoint from the first request is still on disk. Nothing was re-cloned, and an unchanged tree publishes nothing."

chapter "Clean up"

say "When the Session is over, deleting the workspace removes the Sandbox and"
say "its disk. The Task records and the pull request stay."
pe "kubectl -n orka-system delete executionworkspace $ws --wait=false"
wait_for "provider cleanup" "[[ -z \$(kubectl -n $runtime_ns get sandboxes.agents.x-k8s.io,pvc --no-headers 2>/dev/null) ]]" 600
pe "kubectl -n $runtime_ns get sandboxes,pvc"
pe "gh pr view $pr --json url,state --jq '{url,state}'"

chapter "What you saw"

say "One Session, two requests, one Sandbox. Between the requests the Sandbox"
say "was asleep: no Pod, only a disk."
say "The developer wrote two Tasks. The platform team wrote one class. Agent"
say "Sandbox did the sleeping and waking, and Orka decided when."
printf '\n'

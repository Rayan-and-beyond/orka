#!/usr/bin/env bash
# Orka — an agent workspace that outlives the agent
# Codex works across two turns in one kubernetes-sigs Agent Sandbox. Between them, the Sandbox sleeps.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/02-agent-sandbox
runtime_ns=${ORKA_RUNTIME_NAMESPACE:-orka-runtimes}
branch=orka/healthz-from-sandbox
export runtime_ns

ensure_port_forward
orka_connect
peq "orka session delete inventory-sandbox"
wait_for "the previous Session to archive" "session_gone inventory-sandbox" 300
peq "kubectl -n $ORKA_NAMESPACE delete tasks -l demo.orka.ai/name=02-agent-sandbox --wait=true"
peq "kubectl -n $ORKA_NAMESPACE delete executionworkspaces -l demo.orka.ai/name=02-agent-sandbox --wait=true"
peq "gh pr list --repo sozercan/orka-demo-inventory --head $branch --json number --jq '.[].number' | xargs -I{} gh pr close {} --repo sozercan/orka-demo-inventory --delete-branch"
peq "gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/heads/$branch"

workspace_of() {
  kubectl -n "$ORKA_NAMESPACE" get task "$1" \
    -o jsonpath='{.metadata.labels.acp\.workspace\.orka\.ai/execution-workspace}' 2>/dev/null
}
sandbox_name() {
  kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io -o json 2>/dev/null |
    jq -r '.items[0].metadata.name // empty'
}
sandbox_mode() {
  kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$1" -o jsonpath='{.spec.operatingMode}' 2>/dev/null
}

banner "Orka — an agent workspace that outlives the agent" \
  "Codex works across two turns in one Agent Sandbox. Between them the Sandbox sleeps; its disk does not."

chapter "A class, not a provider"

say "Where does an agent's process and filesystem live? In Orka that is a"
say "platform decision, expressed as an ExecutionWorkspaceClass. This one puts"
say "each Session in a kubernetes-sigs Agent Sandbox and keeps its data on detach."
pe "kubectl -n orka-system get executionworkspaceclasses"
pe "kubectl -n orka-system get executionworkspaceclass sandbox-session -o jsonpath='{.spec.lifecycle}' | jq"
say "A Task asks for the class by name. It never sees a SandboxTemplate, a claim,"
say "or a Pod."

chapter "Turn 1 — implement the change inside a Sandbox"

pe "sed -n '12,36p' $here/manifests/turn-1-implement.yaml"
pe "orka task create -f $here/manifests/turn-1-implement.yaml"
say "The provider's objects appear as Orka binds a dedicated, single-session"
say "runtime pool to a Sandbox."
wait_for "the Sandbox to exist" "[[ -n \$(sandbox_name) ]]" 300
sb=$(sandbox_name)
wait_for "the Sandbox Pod" "kubectl -n $runtime_ns get pods --no-headers 2>/dev/null | grep -q Running" 300
pe "kubectl -n $runtime_ns get sandboxclaims,sandboxes,pods"
sb_uid=$(kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$sb" -o jsonpath='{.metadata.uid}')
pod=$(kubectl -n "$runtime_ns" get pods -o name | grep sandbox-claim | head -n1 | cut -d/ -f2)
say "The Sandbox Pod holds the agent runtime and nothing else. No Git token,"
say "no model key: the provider proxy and the Publisher hold those."
pe "kubectl -n $runtime_ns get pod $pod -o jsonpath='{.spec.volumes[*].secret.secretName}' | wc -w"
pe "kubectl -n $runtime_ns exec $pod -- env | grep -E '^(GH_TOKEN|GITHUB_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)=' || echo 'no provider or Git credential in the environment'"
say "Now the agent works. Orka records what it does as execution events."
wait_task inventory-implement 1800
pe "orka task events inventory-implement | grep -E 'ToolCall|AgentRuntime|Workspace' | tail -n 8"
pe "orka task result inventory-implement | tail -n 20"
say "The agent never pushed. Orka's Publisher verified the tree, published the"
say "branch, and opened the pull request. The receipt lives on the Task."
pe "orka task status inventory-implement"
pr=$(gh pr list --repo sozercan/orka-demo-inventory --head "$branch" --json url --jq '.[0].url')
assert_pr "$pr"
pe "gh pr view $pr --json title,url --jq '{title,url}'"

chapter "The Sandbox sleeps"

ws=$(workspace_of inventory-implement)
say "The Session detached, so the class policy applies: suspend. Orka asks the"
say "provider to suspend the exact Sandbox and keeps its data volume."
wait_for "the workspace to suspend" \
  "[[ \$(kubectl -n $ORKA_NAMESPACE get executionworkspace $ws -o jsonpath='{.status.state}') == Suspended ]]" 600
pe "kubectl -n orka-system get executionworkspace $ws"
pe "kubectl -n $runtime_ns get sandbox $sb -o custom-columns=NAME:.metadata.name,MODE:.spec.operatingMode,UID:.metadata.uid"
pe "kubectl -n $runtime_ns get pods,pvc"
ok "No agent Pod is running. The volume with the working tree is Bound and waiting."

chapter "Turn 2 — same Session, same disk"

say "A second Task in the same Session: a verification pass in the same"
say "Sandbox. The prompt only reads; an unchanged tree publishes nothing."
pe "sed -n '14,24p' $here/manifests/turn-2-verify.yaml"
pe "orka task create -f $here/manifests/turn-2-verify.yaml"
wait_for "the Sandbox to wake" "[[ \$(sandbox_mode $sb) == Running ]]" 600
pe "kubectl -n $runtime_ns get sandbox $sb -o custom-columns=NAME:.metadata.name,MODE:.spec.operatingMode,UID:.metadata.uid"
[[ $(kubectl -n "$runtime_ns" get sandboxes.agents.x-k8s.io "$sb" -o jsonpath='{.metadata.uid}') == "$sb_uid" ]] ||
  { bad "the resumed Sandbox is not the one turn 1 used"; exit 1; }
ok "Same Sandbox, same UID as turn 1. It cold-started from the kept volume."
wait_task inventory-verify 1200
pe "orka task result inventory-verify"
pe "orka task status inventory-verify | grep -E 'Delivery|Phase'"
ok "The implementation from turn 1 was still on disk. Nothing was re-cloned, nothing new was pushed."

chapter "Delete the workspace"

say "Deleting the ExecutionWorkspace removes the Sandbox, its claim, and the"
say "volume. The Task records and the pull request stay."
pe "kubectl -n orka-system delete executionworkspace $ws --wait=false"
wait_for "provider cleanup" "[[ -z \$(kubectl -n $runtime_ns get sandboxes.agents.x-k8s.io,pvc --no-headers 2>/dev/null) ]]" 600
pe "kubectl -n $runtime_ns get sandboxes,pvc"
pe "gh pr view $pr --json url,state --jq '{url,state}'"
printf '\n'

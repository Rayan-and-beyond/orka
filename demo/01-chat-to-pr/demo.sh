#!/usr/bin/env bash
# Orka — from a chat message to a reviewed pull request
# A developer asks Claude Code for a change. Orka runs the agents on Kubernetes.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/01-chat-to-pr
work=$demo_root/setup/state/01
mkdir -p "$work"

# Claude Code reads the presenter's own ~/.claude/settings.json, which may
# already pin a base URL or key. Give the demo a config dir of its own so the
# recorded environment variables are the ones that take effect.
export CLAUDE_CONFIG_DIR=$work/claude
mkdir -p "$CLAUDE_CONFIG_DIR"
# Claude Code also uses a small model for housekeeping calls; name one the
# Provider serves, or those calls fail noisily in the controller log.
printf '{"permissions":{"defaultMode":"bypassPermissions"},"env":{"ANTHROPIC_SMALL_FAST_MODEL":"copilot/claude-haiku-4.5"}}\n' >"$CLAUDE_CONFIG_DIR/settings.json"

# Quiet reset so the recording always starts from the same place. The demo
# repository exists for these recordings, so open pull requests and orka/*
# branches from earlier runs are cleared; the coordinator would otherwise
# find a pull request that already implements the request.
peq "kubectl -n $ORKA_NAMESPACE delete tasks -l orka.ai/source=anthropic-proxy --wait=false"
peq "kubectl -n $ORKA_NAMESPACE delete agents -l orka.ai/created-by=chat --wait=false"
peq "gh pr list --repo sozercan/orka-demo-inventory --state open --json number --jq '.[].number' | xargs -I{} gh pr close {} --repo sozercan/orka-demo-inventory"
peq "gh api repos/sozercan/orka-demo-inventory/git/matching-refs/heads/orka/ --jq '.[].ref' | sed 's#^refs/##' | xargs -I{} gh api -X DELETE repos/sozercan/orka-demo-inventory/git/refs/{}"
ensure_port_forward

banner "Orka — from a chat message to a pull request" \
  "A developer asks Claude Code for a change. Orka runs the agents on Kubernetes. The keys stay in the cluster."

chapter "The scenario"

say "A small team runs an inventory service on Kubernetes. It has three endpoints"
say "and no health check, so its readiness probe has nothing to call."
pe "curl -s https://raw.githubusercontent.com/sozercan/orka-demo-inventory/main/README.md | sed -n '13,19p'"
say "A developer is going to ask for that endpoint the way they would ask a"
say "colleague: in a chat window. Orka will do the rest on the cluster."

chapter "A cluster that runs agents"

say "Orka is a Kubernetes controller, installed with one Helm command."
pe "kubectl -n orka-system get pods -l control-plane=controller-manager"
say "The platform team registered one model Provider. Its API key is a Secret in"
say "the cluster; nobody on the team has it on a laptop."
pe "orka provider list"
say "And two Agents for this team: a Codex coder that edits and runs commands,"
say "and a Claude reviewer with read-only tools. A Task names an Agent and"
say "inherits its model, runtime, and permissions."
pe "orka agent list"

chapter "Connect as a developer"

say "A developer gets a ServiceAccount token, not a model key. The orka CLI and"
say "the dashboard both authenticate with it."
pe "orka config set-server $ORKA_API"
pe "orka config set-namespace orka-system"
pe "kubectl -n orka-system create token orka-client | orka config set-token --file -"
pe "orka status"

chapter "Point Claude Code at the cluster"

say "Orka speaks the Anthropic Messages API. Claude Code needs two environment"
say "variables: the cluster's endpoint, and that same ServiceAccount token."
pe "export ANTHROPIC_BASE_URL=$ORKA_API/anthropic"
pe "export ANTHROPIC_API_KEY=\$(kubectl -n orka-system create token orka-client)"
say "Which models does this developer get? Whatever the Provider allows."
pe "orka models list --compat anthropic | sed -n '1,5p'"

chapter "The request"

say "The change is small enough to read, and real enough to need tests, review,"
say "and CI. Nothing in it names an Agent, a Secret, or a runtime."
pe "cat $here/request.md"
say "Sent as an ordinary Claude Code prompt. Orka's coordinator mode replaces the"
say "client's tools with its own: create Agents and Tasks, wait, review, open a PR."
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
p "claude -p --model copilot/claude-opus-4.7 \"\$(cat $here/request.md)\" | tee $work/answer.md &"
claude -p --model copilot/claude-opus-4.7 --no-session-persistence "$(cat "$here/request.md")" \
  >"$work/answer.md" 2>"$work/claude.err" &
claude_pid=$!
nap 0.6

chapter "Orka turns the conversation into Tasks"

say "Claude Code is now waiting on the answer. Meanwhile the coordinator is"
say "creating Kubernetes Tasks. Each one is a Pod or a pooled agent runtime."
wait_for "the coordinator's first Task" \
  "kubectl -n $ORKA_NAMESPACE get tasks -l orka.ai/source=anthropic-proxy --no-headers 2>/dev/null | grep -q ." 600
pe "orka task list"
say "Tasks born from the chat endpoint are named proxy- plus a short id. Each"
say "one says what it is: an agent Task names its Agent and whether it may"
say "write; a container Task names its image."
say "The table below refreshes as the coordinator works. Read it as: the coder"
say "implements, a golang container validates, the reviewer reads, the coder"
say "fixes if asked. Quiet stretches are cut from the recording."
watch_tasks "! kill -0 $claude_pid" 12 orka.ai/source=anthropic-proxy \
  NAME:.metadata.name,AGENT:.spec.agentRef.name,IMAGE:.spec.image,INTENT:.spec.workspace.intent,PHASE:.status.phase
wait "$claude_pid" || {
  bad "claude exited with an error"
  cat "$work/claude.err" >&2
  exit 1
}
ok "The chat turn returned."

chapter "Look inside one Task"

coder=$(kubectl -n "$ORKA_NAMESPACE" get tasks -l orka.ai/source=anthropic-proxy \
  --sort-by=.metadata.creationTimestamp -o json |
  jq -r '[.items[] | select(.spec.type=="agent" and .spec.workspace.intent=="write")][0].metadata.name')
say "The coder ran as a Codex session in a pooled runtime, with the repository"
say "cloned into its workspace. Orka keeps its execution events; here is what"
say "the agent said as it worked."
pe "orka task events $coder | grep ModelMessage | tail -n 2 | cut -c1-300"
say "The agent never pushed. Orka's clean-room Publisher verified the tree and"
say "published the branch; the receipt lives on the Task."
pe "orka task status $coder"

chapter "The pull request"

pe "cat $work/answer.md"
pr=$(pr_url_from "$(cat "$work/answer.md")")
assert_pr "$pr"
pe "gh pr view $pr --json title,state,headRefName,statusCheckRollup --jq '{title,state,branch:.headRefName,checks:[.statusCheckRollup[]?|{name,conclusion}]}'"
pe "gh pr diff $pr --name-only"
ok "One chat message. One reviewed, CI-green pull request. No model key ever left the cluster."

chapter "What the developer never had"

say "No Anthropic key, no OpenAI key, no GitHub token in the agent's process."
say "The Provider, the Agents, and the Publisher's credentials are the platform"
say "team's Kubernetes objects. The developer had a ServiceAccount token and a"
say "chat window."
printf '\n'

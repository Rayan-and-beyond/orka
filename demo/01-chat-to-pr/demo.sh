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
printf '{"permissions":{"defaultMode":"bypassPermissions"}}\n' >"$CLAUDE_CONFIG_DIR/settings.json"

# Quiet reset so the recording always starts from the same place.
peq "kubectl -n $ORKA_NAMESPACE delete tasks -l orka.ai/source=anthropic-proxy --wait=false"
peq "kubectl -n $ORKA_NAMESPACE delete agents -l orka.ai/created-by=chat --wait=false"
ensure_port_forward

banner "Orka — from a chat message to a pull request" \
  "A developer asks Claude Code for a change. Orka runs the agents on Kubernetes. The keys stay in the cluster."

chapter "A cluster that runs agents"

say "Orka is a Kubernetes controller. It was installed with one Helm command, and"
say "everything it does is a Kubernetes object you can list, watch, and audit."
pe "kubectl -n orka-system get pods"
say "The platform team registered one model Provider. Its API key is a Secret in"
say "the cluster. Nobody on the team has it on a laptop."
pe "kubectl -n orka-system get providers,agents"
say "Two Agents are allowed: a Codex coder that can run shell and tests, and a"
say "Claude reviewer with read-only tools. Tasks can only point at these."

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
pe "orka models list --compat anthropic | head -5"

chapter "The request"

say "The change is small enough to read, and real enough to need tests, review,"
say "and CI. Nothing in it names an Agent, a Secret, or a runtime."
pe "cat $here/request.md"
say "Sent as an ordinary Claude Code prompt. Orka's coordinator mode replaces the"
say "client's tools with its own: create Agents and Tasks, wait, review, open a PR."
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
p "claude -p --model copilot/claude-opus-5 \"\$(cat $here/request.md)\" | tee $work/answer.md &"
claude -p --model copilot/claude-opus-5 --no-session-persistence "$(cat "$here/request.md")" \
  >"$work/answer.md" 2>"$work/claude.err" &
claude_pid=$!
nap 0.6

chapter "Orka turns the conversation into Tasks"

say "Claude Code is now waiting on the answer. Meanwhile the coordinator is"
say "creating Kubernetes Tasks. Each one is a Pod or a pooled agent runtime."
wait_for "the coordinator's first Task" \
  "kubectl -n $ORKA_NAMESPACE get tasks -l orka.ai/source=anthropic-proxy --no-headers 2>/dev/null | grep -q ." 600
pe "orka task list"
say "The task table below refreshes as the coordinator works: implement, validate"
say "in a container, review, open the PR, wait for CI. Quiet stretches are cut."
watch_tasks "! kill -0 $claude_pid" 12 orka.ai/source=anthropic-proxy
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
say "cloned into its workspace. Orka records what it did as execution events."
pe "orka task events $coder | tail -n 12"
say "The agent never pushed. Orka's clean-room Publisher verified the tree and"
say "published the branch; the receipt lives on the Task."
pe "orka task status $coder"

chapter "The pull request"

pe "cat $work/answer.md"
pr=$(pr_url_from "$(cat "$work/answer.md")")
assert_pr "$pr"
pe "gh pr view $pr --json title,state,headRefName,statusCheckRollup --jq '{title,state,branch:.headRefName,checks:[.statusCheckRollup[]?|{name,conclusion}]}'"
pe "gh pr diff $pr --stat"
ok "One chat message. One reviewed, CI-green pull request. No model key ever left the cluster."

chapter "What the developer never had"

say "No Anthropic key, no OpenAI key, no GitHub token in the agent's process."
say "The Provider, the Agents, and the Publisher's credentials are the platform"
say "team's Kubernetes objects. The developer had a ServiceAccount token and a"
say "chat window."
printf '\n'

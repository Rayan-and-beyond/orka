#!/usr/bin/env bash
# Orka — two teams, one endpoint
# Every tool at the company points at one AI URL. The caller's identity picks the team; the team's own Orka does the rest.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/05-two-teams
router_ns=orka-router-system
router_url=http://127.0.0.1:8090
work=$demo_root/setup/state/05
mkdir -p "$work"

# Claude Code reads the presenter's own settings; give each developer a
# config dir of their own so only the recorded environment applies.
claude_for() {
  local who=$1 small=$2
  mkdir -p "$work/$who"
  printf '{"permissions":{"defaultMode":"bypassPermissions"},"env":{"ANTHROPIC_SMALL_FAST_MODEL":"%s"}}\n' "$small" >"$work/$who/settings.json"
}
claude_for alice approved-models/claude-haiku-4.5
claude_for bob openai/gpt-5.5

# Quiet reset so the recording always starts from the same place.
for ns in team-payments team-inventory; do
  peq "kubectl -n $ns delete tasks --all --wait=false"
done
peq "pkill -f 'port-forward service/orka-compat-router 8090'"
kubectl -n "$router_ns" port-forward service/orka-compat-router 8090:8080 >/dev/null 2>&1 &
_router_pf=$!
trap 'kill $_router_pf 2>/dev/null; stop_port_forward' EXIT
wait_for "the router port-forward" "curl -fsS -m 2 $router_url/healthz" 60

# Claude Code resets terminal modes on exit when it owns a tty; a pipe keeps
# those escape codes out of the recording without changing its output.
claude() { command claude "$@" 2>&1 | cat; }

# Same-request helper: the sentence both developers send.
request="Run a container task that prints today's date and tell me what it printed."

banner "Orka — two teams, one endpoint" \
  "Every tool at the company points at one AI URL. The caller's identity picks the team. The team's own Orka does the rest."

chapter "The scenario"

say "The payments team and the inventory team both want AI agents on the"
say "cluster. They use different models, have different budgets, and must never"
say "see each other's work. The company wants exactly one AI base URL for every"
say "tool: Claude Code, editors, CI."
say "So the platform team gave each team its own namespace with its own Orka,"
say "and put one small router in front."

chapter "Two installations, one router"

say "Each team's namespace holds a complete Orka: its controller, its model"
say "Provider, its Agents, its Tasks. Nothing is shared but the door."
pe "kubectl get pods -n team-payments -l app=orka-controller"
pe "kubectl get pods -n team-inventory -l app=orka-controller"
say "Their Providers differ. Payments is on an approved Claude model; inventory"
say "uses GPT. Each key is a Secret in that team's namespace."
pe "kubectl -n team-payments get providers"
pe "kubectl -n team-inventory get providers"
say "The router validates the caller's Kubernetes token and forwards to that"
say "team's installation. It holds no keys and runs no models."
pe "kubectl -n $router_ns get configmap orka-compat-router -o jsonpath='{.data.routes\\.yaml}'"

chapter "Two developers, one URL"

say "Alice is on payments, Bob on inventory. Same base URL for both. The only"
say "thing that differs is the ServiceAccount token each one holds."
pe "export ANTHROPIC_BASE_URL=$router_url/anthropic"
pe "ALICE=\$(kubectl -n team-payments create token alice)"
pe "BOB=\$(kubectl -n team-inventory create token bob)"
ALICE=$(kubectl -n team-payments create token alice)
BOB=$(kubectl -n team-inventory create token bob)
say "Ask the same URL which models it offers, once as Alice and once as Bob."
pe "orka models list --compat anthropic --server $router_url --namespace team-payments --token \$ALICE"
pe "orka models list --compat anthropic --server $router_url --namespace team-inventory --token \$BOB"
ok "One URL, two answers. The token chose the namespace; nothing in the request did."

chapter "Same request, different homes"

say "Both developers ask Claude Code for the same small thing. Each request"
say "becomes a Task in its own team's namespace, run by that team's Orka."
pe "cat <<'TXT'
$request
TXT"
export CLAUDE_CONFIG_DIR=$work/alice
p "ANTHROPIC_API_KEY=\$ALICE claude -p --model approved-models/claude-opus-4.7 \"\$request\""
ANTHROPIC_API_KEY=$ALICE claude -p --model approved-models/claude-opus-4.7 --no-session-persistence "$request" 2>"$work/alice.err" | sed -n '1,6p'
nap 0.8
export CLAUDE_CONFIG_DIR=$work/bob
p "ANTHROPIC_API_KEY=\$BOB claude -p --model openai/gpt-5.5 \"\$request\""
ANTHROPIC_API_KEY=$BOB claude -p --model openai/gpt-5.5 --no-session-persistence "$request" 2>"$work/bob.err" | sed -n '1,6p'
nap 0.8
say "Where did the work run? In each team's own namespace, and nowhere else."
pe "kubectl get tasks -n team-payments -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase"
pe "kubectl get tasks -n team-inventory -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase"

chapter "The boundary"

say "Bob asks for the payments team's Provider by name, through the same URL."
export CLAUDE_CONFIG_DIR=$work/bob
pex "ANTHROPIC_API_KEY=\$BOB claude -p --model approved-models/claude-opus-4.7 --no-session-persistence 'Reply with OK'"
ok "Refused, with no fallback. The router does not even know what a Provider is; the inventory installation simply has no such thing."
say "And Bob knocking on the payments installation's own door, with his token:"
kubectl -n team-payments port-forward svc/orka-api 8091:8080 >/dev/null 2>&1 &
_pay_pf=$!
wait_for "the payments API port-forward" "curl -fsS -m 2 http://127.0.0.1:8091/healthz" 60
pex "orka task list --server http://127.0.0.1:8091 --namespace team-payments --token \$BOB"
kill $_pay_pf 2>/dev/null || true
ok "403. Identity is checked by every installation, not just at the router."

chapter "What the platform team got"

say "One URL to publish. Per-team keys, models, and budgets. Per-team Tasks,"
say "Sessions, and audit trail. A router that holds nothing and decides nothing"
say "except which door to knock on."
pe "kubectl get tasks -A | grep team-"
printf '\n'

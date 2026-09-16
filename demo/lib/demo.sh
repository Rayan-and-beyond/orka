# shellcheck shell=bash
#
# Shared helpers for the Orka asciinema demos.
#
# Sourced by each demo/NN-*/demo.sh. Provides typed-out commands, narrative
# lines, chapter markers that survive into the recorded .cast (so a viewer can
# skip a beat with a key press), and the small amount of cluster plumbing the
# demos need but the audience should not have to watch.
#
# Environment knobs:
#   TYPE_SPEED    characters per second while "typing" a command (default 34)
#   DEMO_AUTO     1 = never block for a key press (default; used for recording)
#   ORKA_DEMO_ENV path to the env file written by demo/setup (default:
#                 demo/setup/env.sh next to this file)

set -o errexit -o nounset -o pipefail

: "${TYPE_SPEED:=34}"
: "${DEMO_AUTO:=1}"

demo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(CDPATH='' cd -- "$demo_root/.." && pwd)
export demo_root repo_root

# demo/setup writes env.sh with KUBECONFIG, the Orka API URL, the demo
# namespace and the repositories the demos work against. Nothing in it is a
# secret: tokens are minted at run time from the cluster.
: "${ORKA_DEMO_ENV:=$demo_root/setup/env.sh}"
if [[ -f $ORKA_DEMO_ENV ]]; then
  # shellcheck disable=SC1090
  source "$ORKA_DEMO_ENV"
fi
: "${ORKA_NAMESPACE:=orka-system}"
: "${ORKA_API:=http://127.0.0.1:8080}"
: "${DEMO_REPO:=https://github.com/sozercan/orka-demo-inventory}"
: "${DEMO_REPO_BRANCH:=main}"
: "${DEMO_GIT_SECRET:=github-credentials}"
export ORKA_NAMESPACE ORKA_API DEMO_REPO DEMO_REPO_BRANCH DEMO_GIT_SECRET

# --- palette ------------------------------------------------------------
C_RESET=$'\e[0m'
C_DIM=$'\e[38;5;245m'
C_PROMPT=$'\e[38;5;75m'
C_CMD=$'\e[38;5;255m'
C_TITLE=$'\e[1;38;5;213m'
C_RULE=$'\e[38;5;60m'
C_OK=$'\e[38;5;114m'
C_BAD=$'\e[38;5;203m'
C_NOTE=$'\e[38;5;222m'

# --- marker sentinel ----------------------------------------------------
# Written into the stream as an OSC sequence. Terminals ignore it; the
# post-processor in demo/lib/markers.py turns it into an asciicast v3 marker
# event and strips it from the output.
marker() { printf '\e]1337;OrkaMarker=%s\a' "$1"; }

# --- primitives ---------------------------------------------------------
_type() {
  local text=$1 delay i
  delay=$(awk -v s="$TYPE_SPEED" 'BEGIN{printf "%.3f", 1/s}')
  for ((i = 0; i < ${#text}; i++)); do
    printf '%s' "${text:i:1}"
    sleep "$delay"
  done
}

nap() { [[ $DEMO_AUTO == 1 ]] && sleep "${1:-1}" || read -rsn1; }

# chapter "Label" — a skippable beat. Emits a marker plus a title card.
chapter() {
  printf '\n'
  marker "$1"
  printf '%s┌─ %s%s%s\n' "$C_RULE" "$C_TITLE" "$1" "$C_RESET"
  printf '%s└%s%s\n\n' "$C_RULE" "$(printf '─%.0s' $(seq 1 $((${#1} + 2))))" "$C_RESET"
  nap 0.8
}

# say "text" — narrative line, no prompt, no command.
say() {
  printf '%s%s%s\n' "$C_DIM" "$1" "$C_RESET"
  nap 0.9
}

# note "text" — a highlighted aside the audience should remember.
note() {
  printf '%s› %s%s\n' "$C_NOTE" "$1" "$C_RESET"
  nap 0.9
}

# p "cmd" — type a command at the prompt but do not run it.
p() {
  printf '%s$%s ' "$C_PROMPT" "$C_CMD"
  _type "$1"
  printf '%s\n' "$C_RESET"
}

# pe "cmd" — type it, then run it. A failure aborts the recording under
# errexit: the narration that follows would otherwise claim success against a
# cluster that did not do what was narrated.
pe() {
  p "$1"
  nap 0.4
  eval "$1"
  nap 1.2
}

# pex "cmd" — same, for the beats where Orka is supposed to refuse.
# Here success is the failure: it means the boundary did not hold.
pex() {
  p "$1"
  nap 0.4
  if eval "$1"; then
    printf '%s✖ demo error: expected a refusal, got success%s\n' "$C_BAD" "$C_RESET" >&2
    return 1
  fi
  nap 1.2
}

# peq "cmd" — run without echoing (setup plumbing the viewer shouldn't see).
# Best-effort by design: idempotent deletes and pkills that are expected to
# fail on a clean cluster. Anything whose success matters uses `pe` or
# `wait_for` instead.
peq() { eval "$1" >/dev/null 2>&1 || true; }

ok()  { printf '%s✔ %s%s\n' "$C_OK" "$1" "$C_RESET"; nap 0.8; }
bad() { printf '%s✖ %s%s\n' "$C_BAD" "$1" "$C_RESET"; nap 0.8; }

banner() {
  local title=$1 subtitle=$2
  printf '\n%s%s%s\n' "$C_TITLE" "$title" "$C_RESET"
  printf '%s%s%s\n\n' "$C_DIM" "$subtitle" "$C_RESET"
  nap 1.2
}

# show FILE — print a file the way a person would `cat` it, but typed as the
# command first. Long files are the enemy of a 28-row recording; keep the
# manifests the demos show short.
show() { pe "cat $1"; }

# wait_for "description" "command" [timeout_seconds]
# Polls quietly. Idle time is compressed by the recorder, so a long wait costs
# the viewer two seconds, not two minutes.
wait_for() {
  local what=$1 cmd=$2 timeout=${3:-300} elapsed=0
  while ! eval "$cmd" >/dev/null 2>&1; do
    sleep 3
    elapsed=$((elapsed + 3))
    if ((elapsed >= timeout)); then
      bad "timed out waiting for $what"
      return 1
    fi
  done
  return 0
}

# --- Orka plumbing ------------------------------------------------------
# The demos type plain `orka` and `kubectl`, because that is what a viewer
# would type. The scoped kubeconfig and the CLI config live in the demo's own
# directories so nothing here touches ~/.kube/config or ~/.orka.
: "${ORKA_CONFIG_DIR:=$demo_root/setup/state/orka-config}"
export ORKA_CONFIG_DIR
mkdir -p "$ORKA_CONFIG_DIR"
# The orka CLI reads ~/.orka/config.yaml; give it a HOME of its own so the
# recorded commands stay plain while the presenter's real config is untouched.
orka() {
  HOME="$ORKA_CONFIG_DIR" command orka "$@"
}
export -f orka 2>/dev/null || true

# orka_token — a short-lived API token for the demo client ServiceAccount.
orka_token() {
  kubectl -n "$ORKA_NAMESPACE" create token orka-client --duration=4h
}

# orka_connect — point the CLI at the port-forwarded API and mint a token.
# Silent; the hero demo shows the equivalent typed commands once.
orka_connect() {
  peq "orka config set-server $ORKA_API"
  peq "orka config set-namespace $ORKA_NAMESPACE"
  orka_token | orka config set-token --file - >/dev/null
}

# ensure_port_forward — the API is a ClusterIP Service; forward it once for
# the whole recording. Tracked by PID and torn down at exit.
_pf_pid=
ensure_port_forward() {
  local port=${ORKA_API##*:}
  if curl -fsS -m 2 "$ORKA_API/healthz" >/dev/null 2>&1; then
    return 0
  fi
  kubectl -n "$ORKA_NAMESPACE" port-forward "svc/${ORKA_API_SERVICE:-orka-api}" "${port}:8080" >/dev/null 2>&1 &
  _pf_pid=$!
  wait_for "the Orka API port-forward" "curl -fsS -m 2 $ORKA_API/healthz" 60
}
stop_port_forward() {
  [[ -n $_pf_pid ]] || return 0
  kill "$_pf_pid" 2>/dev/null || true
  wait "$_pf_pid" 2>/dev/null || true
  _pf_pid=
}
trap stop_port_forward EXIT

# session_gone NAME — true once the Session no longer exists. Session deletion
# archives asynchronously; a new Task naming the same Session while that runs
# is refused with a conflict, so callers wait on this after deleting.
session_gone() {
  ! orka session get "$1" >/dev/null 2>&1
}

# task_phase NAME — the Task's current phase, or empty.
task_phase() {
  kubectl -n "$ORKA_NAMESPACE" get task "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

# wait_task NAME [timeout] — wait for a Task to settle, fail on anything but
# Succeeded so the narration after it is honest.
wait_task() {
  local name=$1 timeout=${2:-1800}
  wait_for "task/$name to settle" \
    "[[ \$(task_phase $name) =~ ^(Succeeded|Failed|Cancelled)$ ]]" "$timeout"
  if [[ $(task_phase "$name") != Succeeded ]]; then
    bad "task/$name ended in phase $(task_phase "$name")"
    kubectl -n "$ORKA_NAMESPACE" get task "$name" -o jsonpath='{.status.message}' >&2 || true
    return 1
  fi
}

# watch_tasks "until-command" [interval] [label-selector]
# Prints the task table whenever it changes, until the condition holds. The
# recorder compresses the quiet stretches, so the viewer sees the workflow
# advance instead of a spinner.
watch_tasks() {
  local until=$1 interval=${2:-10} selector=${3:-} last="" now
  local cmd="kubectl -n $ORKA_NAMESPACE get tasks --no-headers -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase --sort-by=.metadata.creationTimestamp"
  [[ -n $selector ]] && cmd+=" -l $selector"
  while true; do
    now=$(eval "$cmd" 2>/dev/null || true)
    if [[ $now != "$last" ]]; then
      printf '%s── %s ──%s\n' "$C_DIM" "$(date -u +%H:%M:%S)" "$C_RESET"
      printf '%s\n' "$now"
      last=$now
    fi
    if eval "$until" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$interval"
  done
}

# pr_url_from TEXT — the first GitHub pull request URL in a blob of text.
pr_url_from() {
  grep -Eo 'https://github\.com/[^[:space:])"'"'"'<>]+/pull/[0-9]+' <<<"$1" | head -n1
}

# assert_pr URL — refuse to narrate a PR that GitHub cannot show us.
assert_pr() {
  local url=$1
  [[ -n $url ]] || { bad "no pull request URL in the result"; return 1; }
  gh pr view "$url" --json number,state,url >/dev/null 2>&1 || {
    bad "GitHub does not know $url"
    return 1
  }
}

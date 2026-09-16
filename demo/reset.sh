#!/usr/bin/env bash
# Remove the objects a demo creates, leaving the installation in place.
#
#   ./demo/reset.sh                 # every demo
#   ./demo/reset.sh 02-agent-sandbox
set -eu
demo_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
: "${ORKA_DEMO_ENV:=$demo_root/setup/env.sh}"
if [ -f "$ORKA_DEMO_ENV" ]; then
  # shellcheck disable=SC1090
  . "$ORKA_DEMO_ENV"
fi
ns=${ORKA_NAMESPACE:-orka-system}
api=${ORKA_API:-http://127.0.0.1:8080}
config_dir=${ORKA_CONFIG_DIR:-$demo_root/setup/state/orka-config}

# A Task bound to a Session keeps its cleanup authority until the Session is
# archived, so delete Sessions first or the Task deletions never finish.
delete_sessions() {
  local pf
  curl -fsS -m 2 "$api/healthz" >/dev/null 2>&1 || {
    kubectl -n "$ns" port-forward "svc/${ORKA_API_SERVICE:-orka-api}" "${api##*:}:8080" >/dev/null 2>&1 &
    pf=$!
    sleep 3
  }
  mkdir -p "$config_dir"
  HOME=$config_dir orka config set-server "$api" >/dev/null 2>&1 || true
  HOME=$config_dir orka config set-namespace "$ns" >/dev/null 2>&1 || true
  kubectl -n "$ns" create token orka-client --duration=1h 2>/dev/null | HOME=$config_dir orka config set-token --file - >/dev/null 2>&1 || true
  for session in "$@"; do
    HOME=$config_dir orka session delete "$session" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do
    local remaining=0
    for session in "$@"; do
      HOME=$config_dir orka session get "$session" >/dev/null 2>&1 && remaining=1
    done
    [ "$remaining" = 0 ] && break
    sleep 5
  done
  [ -n "${pf:-}" ] && kill "$pf" 2>/dev/null
  return 0
}

reset_01() {
  kubectl -n "$ns" delete tasks -l orka.ai/source=anthropic-proxy --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete agents -l orka.ai/created-by=chat --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
reset_02() {
  delete_sessions inventory-sandbox
  kubectl -n "$ns" delete tasks -l demo.orka.ai/name=02-agent-sandbox --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete executionworkspaces -l demo.orka.ai/name=02-agent-sandbox --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
reset_03() {
  delete_sessions inventory-audit
  kubectl -n "$ns" delete tasks -l demo.orka.ai/name=03-agent-substrate --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete executionworkspacecheckpoints -l demo.orka.ai/name=03-agent-substrate --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete executionworkspaces -l demo.orka.ai/name=03-agent-substrate --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
reset_04() {
  kubectl -n "$ns" delete repositoryscans -l demo.orka.ai/name=04-security-scan --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

case ${1:-all} in
  01-*) reset_01 ;;
  02-*) reset_02 ;;
  03-*) reset_03 ;;
  04-*) reset_04 ;;
  all) reset_01; reset_02; reset_03; reset_04 ;;
  *) echo "unknown demo: $1" >&2; exit 1 ;;
esac
echo "demo objects removed"

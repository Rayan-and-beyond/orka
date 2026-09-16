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

reset_01() {
  kubectl -n "$ns" delete tasks -l orka.ai/source=anthropic-proxy --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete agents -l orka.ai/created-by=chat --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
reset_02() {
  kubectl -n "$ns" delete tasks -l demo.orka.ai/name=02-agent-sandbox --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$ns" delete executionworkspaces -l demo.orka.ai/name=02-agent-sandbox --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
reset_03() {
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

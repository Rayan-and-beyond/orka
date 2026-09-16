#!/usr/bin/env bash
# Orka — find it, prove it, fix it
# A repository is scanned for vulnerabilities; a person picks one finding and Orka opens the fix.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/04-security-scan
repo=nodejs-goof

peq "orka security repo delete $repo"
peq "kubectl -n $ORKA_NAMESPACE delete repositoryscan $repo --wait=true"
ensure_port_forward
orka_connect


banner "Orka — find it, prove it, fix it" \
  "A known-vulnerable app is scanned. A person picks one finding. Orka validates it and opens the fix."

chapter "Register the repository"

say "nodejs-goof is a deliberately vulnerable todo app. We register it once;"
say "Orka scans on demand or on a schedule, and keeps the results as records."
pe "sed -n '6,20p' $here/manifests/repository-scan.yaml"
pe "orka security repo create -f $here/manifests/repository-scan.yaml"
pe "orka security repo list"

chapter "Scan"

say "A scan is an agent Task with a read-only clone of the repository. The"
say "reviewer writes a threat model, then reviews the code slice by slice."
pe "orka security scan run $repo"
watch_tasks "orka security scan list $repo -o json | jq -e '[.items[] | select(.phase == \"succeeded\")] | length > 0'" 20
if orka security scan list "$repo" -o json | jq -e '[.items[] | select(.phase == "failed")] | length > 0' >/dev/null; then
  bad "the scan run failed"; exit 1
fi
pe "orka security scan list $repo"
pe "orka security threat-model get $repo -o json | jq -r .content | head -n 20"

chapter "Findings, with evidence"

say "Every finding cites a file and line range inside the reviewed context."
say "Ones Orka could validate rank above the rest."
pe "orka security finding list $repo --recommended"
finding=$(orka security finding list "$repo" --recommended -o json | jq -r '.items[0].id // empty')
[[ -n $finding && $finding != null ]] || { bad "no recommended finding"; exit 1; }
pe "orka security finding get $finding -o json | jq '{title,severity,category,validationStatus,filePath,line,summary}'"

chapter "A person decides to fix it"

say "Remediation never happens by itself. A person asks for a patch; a coder"
say "agent works in a write-intent workspace; Orka's Publisher opens the PR."
pe "orka security finding patch $finding"
watch_tasks "orka security finding patches $finding -o json | jq -e '[.items[] | select(.status == \"pr_opened\" or (.status | test(\"failed|rejected\")))] | length > 0'" 20
if orka security finding patches "$finding" -o json | jq -e '[.items[] | select(.status | test("failed|rejected"))] | length > 0' >/dev/null; then
  bad "the patch proposal did not reach pr_opened"; orka security finding patches "$finding" -o json | jq '.items[] | {status,reason}' >&2; exit 1
fi
pe "orka security finding patches $finding -o json | jq '.items[0] | {status,branch,prURL}'"
pe "orka security finding pr $finding -o json"
pr=$(orka security finding pr "$finding" -o json | jq -r '.prURL // empty')
assert_pr "$pr"
pe "gh pr view $pr --json title,url --jq '{title,url}'"
pe "gh pr diff $pr --stat"
ok "Found, validated, and fixed, with a human decision in the middle."
printf '\n'

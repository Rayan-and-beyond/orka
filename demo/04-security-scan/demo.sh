#!/usr/bin/env bash
# Orka — findings that arrive as pull requests
# A legacy app is scanned. Every finding cites its evidence. A person picks one, and Orka opens the fix.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/demo.sh"
cd "$repo_root"

here=demo/04-security-scan
repo=nodejs-goof

peq "orka security repo delete $repo"
peq "kubectl -n $ORKA_NAMESPACE delete repositoryscan $repo --wait=true"
ensure_port_forward
orka_connect

banner "Orka — findings that arrive as pull requests" \
  "A legacy app is scanned. Every finding cites its evidence. A person picks one, and Orka opens the fix."

chapter "The scenario"

say "Every company has a service like nodejs-goof: an old Node.js app that"
say "still runs in production and that nobody wants to touch. It is a public"
say "app with known vulnerabilities, which makes it an honest stand-in."
say ""
say "The security team has two complaints about scanners. Scanners produce"
say "long lists of guesses that engineers learn to ignore, and even the real"
say "findings end up as tickets that wait for months."
say ""
say "They want two things instead: findings that were checked before anyone"
say "reads them, and fixes that arrive as pull requests. Orka does both,"
say "with a person deciding in the middle."

chapter "Register the repository"

say "The security team registers a repository once, as a RepositoryScan."
say "It names the repository, which agents do the work, and which credentials"
say "may touch it. Orka scans on demand or on a schedule, and keeps every"
say "result as a record you can query later."
pe "sed -n '6,30p' $here/manifests/repository-scan.yaml"
say "Four credential roles, four Secrets: clone, verify the target, push the"
say "exact branch, and talk to GitHub. Only Orka's Publisher ever holds them;"
say "the agents that read and patch the code never do."
pe "orka security repo create -f $here/manifests/repository-scan.yaml"
pe "orka security repo list"

chapter "Scan"

say "Registering the repository starts its first scan. A scan is an agent"
say "Task with a read-only clone. The reviewing agent first writes a threat"
say "model, a short description of what the app does and where an attacker"
say "would push, and then reviews the code slice by slice against it."
latest_scan() { orka security scan list "$repo" -o json | jq -r '.items | sort_by(.startedAt) | last | .phase // empty'; }
watch_tasks "[[ \$(latest_scan) =~ ^(succeeded|failed)$ ]]" 20 orka.ai/security-target=$repo
[[ $(latest_scan) == succeeded ]] || { bad "the scan run failed"; exit 1; }
say "The scan record counts what was reviewed and what was kept. Dropped"
say "findings are the guesses the reviewer could not support."
pe "orka security scan list $repo -o json | jq '.items[0] | {phase,sliceCount,reviewedSliceCount,acceptedFindings,droppedFindings,summary}'"
say "The threat model is a record too. It is the frame every finding is"
say "judged against."
pe "orka security threat-model get $repo -o json | jq -r .content | sed -n '1,14p' | cut -c1-96"

chapter "Findings, with evidence"

say "Every finding cites a file and a line range inside the code the reviewer"
say "actually read. Orka then tries to validate the likely ones: it reproduces"
say "the problem in an isolated worker instead of trusting the reviewer's word."
say "Validated findings rank above the rest."
pe "orka security finding list $repo --recommended -o json | jq -r '.items[] | [.severity, .validationStatus, .id, .title] | @tsv' | cut -c1-96 | sed -n '1,12p'"
finding=$(orka security finding list "$repo" --recommended -o json | jq -r '[.items[] | select(.validationStatus == "validated")][0].id // .items[0].id // empty')
[[ -n $finding && $finding != null ]] || { bad "no recommended finding"; exit 1; }
say "One finding, in full: where it is, how bad it is, and what was checked."
pe "orka security finding get $finding -o json | jq '{title,severity,category,validationStatus,filePath,line,summary}'"

chapter "A person decides to fix it"

say "Nothing is patched by itself. A person asks for a fix on one finding."
say "Orka then hands the finding to a coding agent in a write-intent"
say "workspace, and its Publisher opens the pull request with the credentials"
say "the agent never saw."
pe "orka security finding patch $finding"
watch_tasks "orka security finding patches $finding -o json | jq -e '[.items[] | select(.status == \"pr_opened\" or (.status | test(\"failed|rejected\")))] | length > 0'" 20 orka.ai/security-finding-id=$finding
if orka security finding patches "$finding" -o json | jq -e '[.items[] | select(.status | test("failed|rejected"))] | length > 0' >/dev/null; then
  bad "the patch proposal did not reach pr_opened"; orka security finding patches "$finding" -o json | jq '.items[] | {status,reason}' >&2; exit 1
fi
pe "orka security finding patches $finding -o json | jq '.items[0] | {status,branch,prURL}'"
pe "orka security finding pr $finding -o json"
pr=$(orka security finding pr "$finding" -o json | jq -r '.prURL // empty')
assert_pr "$pr"
pe "gh pr view $pr --json title,url --jq '{title,url}'"
pe "gh pr diff $pr --name-only"
ok "Found, validated, and fixed, with a human decision in the middle."

chapter "What you saw"

say "One registration. One scan that wrote a threat model, reviewed the code,"
say "and validated what it could. One person picking one finding. One pull"
say "request, opened by Orka, for the team to review like any other."
printf '\n'

# Orka demos

Recorded terminal sessions, each built around one scenario a viewer can follow
without knowing Orka first. Every demo opens with the situation, shows Orka
doing one legible thing, and ends on a payoff you can verify outside the
terminal: a pull request, an object that survived deletion, a refusal.

| | Demo | Shows |
|---|---|---|
| 1 | [`01-chat-to-pr`](01-chat-to-pr) | Claude Code pointed at the cluster instead of a vendor. One prompt becomes Agents, Tasks, a review, and a CI-green pull request. No model key leaves the cluster. |
| 2 | [`02-agent-sandbox`](02-agent-sandbox) | Two turns of Codex in one kubernetes-sigs Agent Sandbox. The Sandbox is suspended between turns and wakes with the same disk, then opens the PR. |
| 3 | [`03-agent-substrate`](03-agent-substrate) | Codex as a gVisor Actor on Agent Substrate. Data-only suspend, a cold boot into a new Actor, a checkpoint that restores after the workspace is deleted. |
| 4 | [`04-security-scan`](04-security-scan) | A vulnerable app scanned into findings with evidence. A person picks one; Orka validates it and opens the fix. |
| 5 | [`05-two-teams`](05-two-teams) | Two teams, two namespaces, two Orka installations, one shared AI URL. The caller's token picks the team; cross-team requests are refused. Uses the compatibility router from PR #604. |

The scripts are plain bash. `demo/lib/demo.sh` types commands the way a
person would, and every command the viewer sees is the command that ran.
Narration is in the script next to the command it explains, so re-recording
after a change keeps the two in sync.

## Watching

Each chapter is an asciicast v3 marker, so a demo can be stepped through
rather than sat through:

```sh
asciinema play --pause-on-markers demo/casts/01-chat-to-pr.cast
```

* `space` resumes from a marker
* `]` skips to the next chapter
* `.` steps one frame
* `ctrl+c` quits

`demo/casts/` is generated output and is not checked in.

## Re-recording

The demos run against one kind cluster that carries Orka, Agent Substrate on
gVisor, kubernetes-sigs Agent Sandbox, and a real model proxy. Build it once:

```sh
SOURCE_KUBECONFIG=~/.kube/kind/<cluster-with-an-authenticated-vekil>.kubeconfig \
  demo/setup/cluster-up.sh
cp demo/setup/env.sh.example demo/setup/env.sh   # then adjust paths
```

`cluster-up.sh` layers the existing installers under `hack/demos/cluster/`;
read its header for the order and why. `vekil-auth.sh` copies an existing
GitHub Copilot login between clusters so no demo needs an interactive login.

Demo 5 needs two more namespace-scoped installations and the router. Build a
controller image from a checkout that includes PR #604 (it ships
`/compat-router`), then:

```sh
CONTROLLER_IMAGE=<registry>/orka/controller@sha256:<digest> demo/setup/two-teams.sh
```

`two-teams.sh` also registers the team controllers with the cluster's shared
admission webhook; without that, their Task status updates are refused.

Then record:

```sh
demo/record.sh                     # every demo
demo/record.sh 02-agent-sandbox    # one
```

`record.sh` runs `demo/reset.sh` first, records at 100x28 with idle time
capped at two seconds, and converts the chapter sentinels into marker events.

The demos open real pull requests against
[`sozercan/orka-demo-inventory`](https://github.com/sozercan/orka-demo-inventory),
a small Go service that exists for this purpose, and scan the
[`sozercan/nodejs-goof`](https://github.com/sozercan/nodejs-goof) fork.

## Layout

```
demo/
  lib/demo.sh        typed-command helpers, chapters, colours, Orka plumbing
  lib/markers.py     sentinel -> asciicast v3 marker events
  setup/             cluster bootstrap, vekil auth copy, platform resources
  NN-*/demo.sh       the script that gets recorded
  NN-*/manifests/    what that demo applies
  casts/             recording output (gitignored)
```

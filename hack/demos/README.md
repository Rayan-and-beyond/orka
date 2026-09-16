# Demo cluster bootstrap

The recorded demos live in [`demo/`](../../demo) at the repository root; see
[`demo/README.md`](../../demo/README.md) for the scenarios and how to record
them.

This directory keeps the installers those demos build on:

| Path | Purpose |
| --- | --- |
| `cluster/install-substrate.sh` | Agent Substrate on a dedicated gVisor kind cluster, plus Orka, via the CI conformance suite (cluster kept) |
| `cluster/install-demo-model.sh` | The model Provider, worker images, and Git Secret |
| `cluster/install-agent-sandbox.sh` | kubernetes-sigs Agent Sandbox, its runtime image, and the sandbox router |
| `cluster/cluster-up.sh` / `cluster-down.sh` | A plain kind cluster with Orka, for the non-Substrate path |
| `cluster/templates/` | The SandboxTemplate the sandbox installer applies |
| `images/sandbox-runtime/` | The Agent Sandbox runtime image |

`demo/setup/cluster-up.sh` runs these in the order the demos need and adds
the pieces the conformance installer leaves out (real model proxy, Publisher,
extra runtime images).

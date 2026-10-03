# abox

> One command. Full AI infrastructure.

`make run` gives you a local Kubernetes cluster with everything an AI project needs: an AI-aware API gateway, an agent runtime, observability, distributed tracing, and an eval harness — ready to use.

## What's included

| Component | Role |
|---|---|
| **agentgateway v2.2.1** | AI-aware API gateway (Gateway API–native, MCP-aware) |
| **kagent 0.10.1** | Kubernetes-native AI agent framework |
| **Qdrant 1.19.1** | Vector database for retrieval |
| **Arize Phoenix 12.0.10** | LLM observability — tracing, evals, prompt playground |
| **Flux CD 2.x** | GitOps/GitLessOps operator — keeps the cluster in sync with OCI artifacts |
| **KinD** | Local Kubernetes (1 control-plane + 2 workers) - can be any k8s |
| **cloud-provider-kind** | LoadBalancer support so gateway gets a real IP for local development |

## Quickstart

```bash
make run
```

That's it. Installs OpenTofu and k9s, provisions the cluster, bootstraps Flux, and reconciles all components. When it finishes:

```bash
kubectl get gateway,httproute -A        # gateway is up
kubectl get agents -n kagent            # agent runtime is up
kubectl get svc -n agentgateway-system  # grab the LoadBalancer IP
```

Point your AI app at the gateway IP on port 80.

### Setup options

`scripts/setup.sh` skips any tool that is already on `PATH` (OpenTofu, kind, k9s, cloud-provider-kind), so machines provisioned with Homebrew or apt are left alone. Two environment variables tune the rest:

| Variable | Effect |
|---|---|
| `ABOX_KUBECONFIG=~/.kube/abox.config` | Write the cluster kubeconfig to a dedicated file instead of merging it into `~/.kube/config` and switching the current context. Export the same `KUBECONFIG` in any shell that talks to the cluster. |
| `ABOX_SKIP_ALIASES=1` | Do not touch shell rc files. By default the script asks before appending the `k`, `tf` and `kk` aliases and warns if they would shadow existing ones. |

On macOS with Docker Desktop, `cloud-provider-kind` needs root to install host routes; if LoadBalancer Services stay `<pending>`, re-launch it with `sudo` in its own terminal. OrbStack and Colima route to containers directly and usually do not need this.

## How it works

```
make run  →  scripts/setup.sh
  → tofu apply (bootstrap/)
      → KinD cluster
      → Flux Operator + FluxInstance   via the upstream flux-operator-bootstrap module
      → ResourceSetInputProvider   polls oci://ghcr.io/den-vasyliev/abox/releases
      → ResourceSet                creates OCIRepository + 2 Kustomizations
          → releases/crds/    gateway-api-crds, agentgateway-crds, kagent-crds
          → releases/         agentgateway (Gateway + GatewayClass)
                              kagent (agent runtime + HTTPRoute)
```

Everything after the cluster is **gitless GitOps via OCI**: no Git polling, no deploy keys. CI publishes `releases/` as an OCI artifact on every version tag. The cluster reconciles from that artifact automatically.

## Releasing

```bash
make push   # bumps patch version, tags, pushes → CI publishes OCI artifact → cluster reconciles
```

> **Note:** RSIP tag sorting is lexicographic. If the patch version would exceed 9, bump the minor instead: `git tag vX.Y+1.0`.

## Directory layout

| Path | Purpose |
|---|---|
| `bootstrap/` | OpenTofu: KinD + Flux bootstrap (operator, instance, RSIP, ResourceSet) |
| `bootstrap/flux-instance.yaml` | `FluxInstance` applied by the bootstrap Job |
| `releases/crds/` | CRD HelmReleases: gateway-api, agentgateway, kagent |
| `releases/` | App HelmReleases + Gateway + HTTPRoutes |
| `scripts/setup.sh` | Full setup script (`make run`) |
| `.github/workflows/flux-push.yaml` | CI: publish `releases/` as OCI artifact on `v*` tags |

## Adding components

1. Put CRD charts in `releases/crds/` as HelmReleases.
2. Put app charts in `releases/` as HelmReleases.
3. Run `make push` — the cluster reconciles automatically.

The CRD kustomization runs first (`wait: true`), apps run after (`dependsOn: releases-crds`). This ordering is enforced by Flux and must be preserved.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Apache 2.0 — see [LICENSE](./LICENSE).

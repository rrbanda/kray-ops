# kray-ops: Multi-Tenant KubeRay on RHOAI 2.25

Kustomize-based multi-tenant onboarding model for KubeRay workloads on Red Hat OpenShift AI 2.25.

## What This Provides

- **Namespace isolation** -- Each tenant gets a dedicated namespace with RBAC boundaries
- **Quota management** -- Per-tenant ResourceQuotas for CPU, memory, and GPU
- **Kueue integration** -- Fair scheduling via LocalQueue → ClusterQueue routing
- **Security** -- SCC bindings for Ray pods, mTLS between nodes, OAuth-protected dashboard
- **Self-service** -- Tenants create RayClusters/RayJobs without admin intervention

## Quick Start

### Prerequisites

| Component | Version | Channel |
|-----------|---------|---------|
| OpenShift | 4.16 - 4.19 | |
| RHOAI | 2.25 | `eus-2.25` |
| Kueue Operator | 1.2+ | `stable-v1.2` |

DSC configuration (`codeflare` and `ray` must be `Managed`):

```yaml
spec:
  components:
    codeflare:
      managementState: Managed
    ray:
      managementState: Managed
    kueue:
      managementState: Unmanaged
```

### 1. Apply Platform Resources

```bash
oc apply -k platform/
```

This creates the ClusterQueue (`gpu-pool`) and ResourceFlavors.

### 2. Onboard a Tenant

```bash
./scripts/onboard-tenant.sh tenant-overlays/tenant-a
```

Or apply directly:

```bash
oc apply -k tenant-overlays/tenant-a/
```

### 3. Validate

```bash
./scripts/validate-tenant.sh ds-team-alpha
```

## Repository Structure

```
kray-ops/
├── platform/                    # Cluster-scoped resources (OPS-managed)
│   ├── kustomization.yaml
│   ├── dsc.yaml                 # DataScienceCluster reference
│   ├── clusterqueue.yaml        # gpu-pool ClusterQueue
│   ├── resourceflavor-cpu.yaml
│   └── resourceflavor-gpu.yaml
├── tenant-base/                 # Kustomize base for all tenants
│   ├── kustomization.yaml
│   ├── namespace.yaml           # Labels: dashboard=true, kueue managed=true
│   ├── resource-quota.yaml      # CPU/memory/GPU caps
│   ├── limit-range.yaml         # Per-container defaults
│   ├── local-queue.yaml         # Routes to gpu-pool ClusterQueue
│   ├── role-ray-user.yaml       # Ray CRD CRUD + pod/svc read + Kueue read
│   ├── rolebinding.yaml         # Binds role to tenant group
│   ├── sa-rolebinding.yaml      # Binds role to service accounts
│   ├── scc-binding.yaml         # nonroot-v2 SCC for Ray pods
│   └── sa-ray.yaml              # ServiceAccount for Ray workloads
├── tenant-overlays/             # Per-tenant customizations
│   ├── tenant-a/                # ds-team-alpha (4 CPU, 1 GPU)
│   └── tenant-b/                # ds-team-beta  (8 CPU, 2 GPU)
├── scripts/
│   ├── onboard-tenant.sh        # Automated tenant provisioning
│   └── validate-tenant.sh       # RBAC + Kueue isolation tests
└── docs/
    ├── architecture.md          # Architecture diagrams and component roles
    ├── onboarding-guide.md      # Step-by-step for platform admins
    └── tenant-user-guide.md     # Self-service guide for data scientists
```

## Tenant Onboarding & Access Model

| Resource / Action | Tenant Access | Granted Via | Owner | Why |
|-------------------|--------------|-------------|-------|-----|
| rayclusters / rayjobs / rayservices (ray.io) | Yes -- own ns only | Namespaced Role + RoleBinding | Tenant self-serve | Their workloads |
| pods, pods/log, services, endpoints, configmaps | Yes -- own ns only | Same Role | Tenant self-serve | Ray runtime creates/needs these |
| Workbench / notebooks | Yes -- own ns only | RHOAI Dashboard project role | Tenant self-serve | Interactive dev + CodeFlare SDK |
| resourcequotas, limitranges | No | -- | GPUaaS / OPS | Wouldn't let tenants lift their own GPU/CPU caps |
| clusterroles, roles, rolebindings | No | -- | GPUaaS / OPS | Privilege escalation risk |
| SecurityContextConstraints (SCC) | No (bound for them by us) | Cluster-scoped binding | OPS / GPUaaS | Cluster-scoped; Ray pods need it but tenants can't self-grant |
| CRDs, operator config (DSC/DSCI), KubeRay operator | No | -- | OPS / GPUaaS | Platform layer -- single owner |

### What We Own vs. What Tenants Get

- **We provision per tenant:** a dedicated namespace, ResourceQuota + LimitRange (GPU/CPU caps), the namespaced Role + RoleBinding, SCC binding for the Ray service accounts, and image-pull access.
- **Tenants self-serve within their namespace:** create/manage their own RayClusters, RayJobs, RayServices, and workbenches -- but cannot alter quotas, RBAC, SCC, or reach other tenants' namespaces.

### RBAC Role Detail

Each tenant gets a `ray-tenant-user` Role with:

| API Group | Resources | Verbs |
|-----------|-----------|-------|
| `ray.io` | rayclusters, rayjobs, rayservices | Full CRUD |
| `""` (core) | pods, pods/log, services, endpoints, configmaps, events | Full CRUD |
| `""` (core) | secrets | Read-only |
| `kubeflow.org` | notebooks | Full CRUD |
| `kueue.x-k8s.io` | workloads, localqueues | Read-only |
| `""` (core) | persistentvolumeclaims | Full CRUD |

## Adding a New Tenant

1. Copy an existing overlay:
   ```bash
   cp -r tenant-overlays/tenant-a tenant-overlays/tenant-new
   ```
2. Edit the kustomization to set namespace, quotas, and group name
3. Apply:
   ```bash
   ./scripts/onboard-tenant.sh tenant-overlays/tenant-new
   ```

See [docs/onboarding-guide.md](docs/onboarding-guide.md) for details.

## Documentation

- [Architecture](docs/architecture.md) -- Component diagram, security model, quota flow
- [Onboarding Guide](docs/onboarding-guide.md) -- Platform admin procedures
- [Tenant User Guide](docs/tenant-user-guide.md) -- Data scientist self-service guide

## Tested On

- OpenShift 4.19.31
- RHOAI 2.25.8
- Kueue Operator 1.2.0
- KubeRay Operator (bundled with RHOAI 2.25)
- CodeFlare Operator (bundled with RHOAI 2.25)

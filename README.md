# kray-ops: Multi-Tenant KubeRay on RHOAI 2.25

Kustomize-based multi-tenant onboarding model for KubeRay workloads on Red Hat OpenShift AI 2.25.

> **Note:** This repo is a supplemental accelerator, not a replacement for the [RHOAI 2.25 product documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/). For the official documented path, see [RHOAI Product Documentation](#rhoai-product-documentation) below.

## What This Provides

This repo supplements RHOAI product docs with automation and governance that the platform does not provide out of the box:

- **Kustomize-based tenant provisioning** -- Repeatable base/overlay pattern for onboarding N tenants
- **Per-tenant ResourceQuotas + LimitRanges** -- GPU/CPU/memory caps not created by the RHOAI Dashboard
- **Custom RBAC Role** -- `ray-tenant-user` with Ray-specific permissions (more granular than Dashboard Admin/Contributor)
- **Automated onboarding + validation scripts** -- Pre-flight checks, apply, and 14-check isolation test suite
- **SCC binding** -- Grants `nonroot-v2` to `ray-service-account` for Ray pod security

> **Dashboard overlap:** The RHOAI Dashboard already handles namespace creation with `kueue.openshift.io/managed=true` labels, creates a default LocalQueue, and provides a Permissions tab for user/group assignment. This repo bypasses the Dashboard path with `oc apply -k`. Choose one approach -- see [docs/onboarding-guide.md](docs/onboarding-guide.md) for guidance.

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
│   └── validate-tenant.sh       # 14 isolation tests (RBAC, Kueue, infra)
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
| SecurityContextConstraints (SCC) | No (bound for them by us) | Namespaced RoleBinding for `ray-service-account` | OPS / GPUaaS | Ray pods need nonroot-v2 SCC; tenants can't self-grant |
| CRDs, operator config (DSC/DSCI), KubeRay operator | No | -- | OPS / GPUaaS | Platform layer -- single owner |

### What We Own vs. What Tenants Get

- **We provision per tenant:** a dedicated namespace, ResourceQuota + LimitRange (GPU/CPU caps), the namespaced Role + RoleBinding, SCC binding for `ray-service-account`, and image-pull access (image-pull secrets are not managed by this repo -- configure separately per your registry setup).
- **Tenants self-serve within their namespace:** create/manage their own RayClusters, RayJobs, RayServices (not yet product-supported), and workbenches -- but cannot alter quotas, RBAC, SCC, or reach other tenants' namespaces.
- **The RHOAI Dashboard also handles:** namespace labeling, default LocalQueue creation, and user/group permissions via its Permissions tab. If using Dashboard-created projects, this repo adds quotas, custom RBAC, and SCC on top.

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

## RHOAI Product Documentation

Most of what this repo automates is covered by the official RHOAI 2.25 documentation. Consult these chapters first:

| Topic | RHOAI Doc Chapter |
|-------|-------------------|
| Kueue setup (ClusterQueue, LocalQueue, ResourceFlavors, namespace labeling) | [Chapter 8 -- Managing workloads with Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) |
| Configuring quotas for distributed workloads, CodeFlare Operator config | [Chapter 9 -- Managing distributed workloads](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) |
| Running Ray workloads from notebooks/pipelines | [Chapter 3 -- Running Ray-based distributed workloads](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) |
| User/group permissions on projects (Dashboard Permissions tab) | [Chapter 5 -- Managing access to data science projects](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) |
| Managing users and admin groups | [Chapter 1 -- Managing users and groups](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) |

**What this repo adds beyond the docs:** per-tenant ResourceQuotas/LimitRanges, a custom `ray-tenant-user` RBAC Role, SCC bindings for Ray service accounts, Kustomize-based onboarding automation, and a 14-check validation script.

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

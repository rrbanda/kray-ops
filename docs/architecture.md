# Multi-Tenant KubeRay Architecture on RHOAI 2.25

## Overview

This document describes the architecture for running multi-tenant KubeRay workloads on Red Hat OpenShift AI (RHOAI) 2.25 with namespace-level isolation, RBAC, and Kueue-based quota management.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster (OCP 4.16-4.19)                │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    redhat-ods-applications                       │   │
│  │  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────┐   │   │
│  │  │ CodeFlare        │  │ KubeRay          │  │ RHOAI        │   │   │
│  │  │ Operator         │  │ Operator         │  │ Dashboard    │   │   │
│  │  │ (mTLS + OAuth)   │  │ (Ray CRDs)       │  │              │   │   │
│  │  └────────┬─────────┘  └────────┬─────────┘  └──────────────┘   │   │
│  └───────────┼─────────────────────┼────────────────────────────────┘   │
│              │                     │                                     │
│  ┌───────────┼─────────────────────┼────────────────────────────────┐   │
│  │           │     openshift-kueue-operator                         │   │
│  │           │  ┌──────────────────┴────────────────────┐           │   │
│  │           │  │ Kueue Controller Manager               │           │   │
│  │           │  │ (Admission, Scheduling, Preemption)    │           │   │
│  │           │  └──────────────────┬────────────────────┘           │   │
│  └───────────┼─────────────────────┼────────────────────────────────┘   │
│              │                     │                                     │
│  ────────────┼─────────────────────┼────────────────────────────────     │
│              │                     │                                     │
│  CLUSTER-SCOPED RESOURCES          │                                     │
│  ┌──────────────────────┐  ┌──────┴──────────────────┐                  │
│  │ ResourceFlavor:       │  │ ClusterQueue: gpu-pool   │                  │
│  │   cpu-flavor          │  │   CPU: 32 cores          │                  │
│  │   gpu-flavor          │  │   Mem: 128Gi             │                  │
│  │   (GPU toleration)    │  │   GPU: 4 nvidia.com/gpu  │                  │
│  └──────────────────────┘  └──────┬──────────────────┘                  │
│                                    │                                     │
│  ──────────────────────────────────┼─────────────────────────────────    │
│                                    │                                     │
│  TENANT NAMESPACES                 │                                     │
│  ┌────────────────────────┐  ┌────┴───────────────────┐                 │
│  │ ds-team-alpha           │  │ ds-team-beta            │                 │
│  │ ┌────────────────────┐  │  │ ┌────────────────────┐  │                 │
│  │ │ LocalQueue: default │  │  │ │ LocalQueue: default │  │                 │
│  │ │ → gpu-pool          │  │  │ │ → gpu-pool          │  │                 │
│  │ ├────────────────────┤  │  │ ├────────────────────┤  │                 │
│  │ │ ResourceQuota       │  │  │ │ ResourceQuota       │  │                 │
│  │ │ CPU: 4, GPU: 1      │  │  │ │ CPU: 8, GPU: 2      │  │                 │
│  │ ├────────────────────┤  │  │ ├────────────────────┤  │                 │
│  │ │ Role: ray-tenant    │  │  │ │ Role: ray-tenant    │  │                 │
│  │ │ RoleBinding: group  │  │  │ │ RoleBinding: group  │  │                 │
│  │ │ SCC: nonroot-v2     │  │  │ │ SCC: nonroot-v2     │  │                 │
│  │ ├────────────────────┤  │  │ ├────────────────────┤  │                 │
│  │ │ RayClusters         │  │  │ │ RayClusters         │  │                 │
│  │ │ RayJobs             │  │  │ │ RayJobs             │  │                 │
│  │ └────────────────────┘  │  │ └────────────────────┘  │                 │
│  └────────────────────────┘  └────────────────────────┘                 │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

### Platform Layer (OPS-managed)

| Component | Responsibility |
|-----------|---------------|
| **RHOAI Operator** | Lifecycle management of CodeFlare, KubeRay, Dashboard |
| **CodeFlare Operator** | Injects OAuth proxy sidecar + mTLS certificates into every RayCluster |
| **KubeRay Operator** | Manages RayCluster, RayJob, RayService CRDs |
| **Kueue Operator** | Admission control, quota enforcement, workload scheduling |
| **ClusterQueue** | Defines total resource pool shared across all tenants |
| **ResourceFlavors** | Maps to hardware variants (CPU-only nodes, GPU nodes with tolerations) |

### Tenant Layer (OPS-provisioned, Tenant-consumed)

| Resource | Purpose | Tenant can modify? |
|----------|---------|-------------------|
| **Namespace** | Isolation boundary | No |
| **ResourceQuota** | Hard caps on CPU, memory, GPU, pod count | No |
| **LimitRange** | Per-container defaults and maximums | No |
| **LocalQueue** | Routes workloads to ClusterQueue for admission | No |
| **Role** (`ray-tenant-user`) | Grants Ray CRD CRUD, pod/svc read, Kueue read | No |
| **RoleBinding** | Binds role to tenant group + service accounts | No |
| **SCC Binding** | Grants `nonroot-v2` SCC for Ray pod security | No |
| **ServiceAccount** | Identity for Ray pods | No |

### Tenant Self-Service

Tenants can create and manage within their namespace:
- **RayClusters** -- Long-running interactive clusters
- **RayJobs** -- Ephemeral or targeted job submissions
- **Workbenches** -- Jupyter notebooks via RHOAI Dashboard
- **CodeFlare SDK** -- Python-native cluster management from notebooks

## Security Model

### Authentication & Authorization Flow

```
User (OpenShift Identity)
    │
    ├─→ RHOAI Dashboard (OAuth)
    │       └─→ Workbench (Notebook)
    │               └─→ CodeFlare SDK
    │                       └─→ KubeRay API (RBAC-checked)
    │
    ├─→ oc CLI
    │       └─→ RayCluster/RayJob YAML
    │               └─→ KubeRay API (RBAC-checked)
    │
    └─→ Ray Dashboard (OAuth Proxy sidecar)
            └─→ OpenShift login required
```

### mTLS Between Ray Nodes

CodeFlare Operator on RHOAI 2.25 automatically:
1. Generates TLS certificates via `create-cert` init container
2. Mounts certs into Ray head and worker pods
3. Enables encrypted GCS communication between Ray nodes

### OAuth Proxy for Dashboard

CodeFlare Operator injects an `oauth-proxy` sidecar on the Ray head pod:
- Requires OpenShift login to access the Ray dashboard
- Creates an OpenShift Route with TLS termination
- Only authenticated users in the tenant namespace can access

## Quota & Scheduling Flow

```
Tenant submits RayCluster/RayJob
    │
    ▼
LocalQueue (namespace-scoped)
    │
    ▼
ClusterQueue: gpu-pool
    │
    ├─ Check ResourceQuota (namespace-level hard caps)
    ├─ Check ClusterQueue capacity (cluster-level pool)
    ├─ Apply scheduling strategy (BestEffortFIFO)
    │
    ▼
Admit or Queue workload
    │
    ├─ Admitted → KubeRay creates pods
    └─ Queued → Wait for capacity
```

## RHOAI 2.25 Specifics

### Differences from RHOAI 3.x

| Feature | RHOAI 2.25 | RHOAI 3.x |
|---------|-----------|-----------|
| DSC API | `v1` | `v2` |
| CodeFlare component | `codeflare: Managed` | Separate component |
| Dashboard access | OAuth proxy sidecar | Gateway API / HTTPRoute |
| mTLS | CodeFlare-managed `create-cert` | Cert-manager integration |
| Kueue install | Separate operator (Unmanaged in DSC) | Integrated (Managed in DSC) |

### CodeFlare Operator Config

The `codeflare-operator-config` ConfigMap in `redhat-ods-applications` controls:
- `mTLSEnabled: true` -- Mutual TLS between Ray nodes (default: true)
- `rayDashboardOAuthEnabled: true` -- OAuth proxy on dashboard (default: true)

## Directory Structure

```
kray-ops/
├── platform/                    # Cluster-scoped resources (OPS)
│   ├── kustomization.yaml
│   ├── dsc.yaml                 # DataScienceCluster reference
│   ├── clusterqueue.yaml        # gpu-pool ClusterQueue
│   ├── resourceflavor-cpu.yaml  # CPU-only nodes
│   └── resourceflavor-gpu.yaml  # GPU nodes with toleration
├── tenant-base/                 # Tenant template (Kustomize base)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── resource-quota.yaml
│   ├── limit-range.yaml
│   ├── local-queue.yaml
│   ├── role-ray-user.yaml
│   ├── rolebinding.yaml
│   ├── sa-rolebinding.yaml
│   ├── scc-binding.yaml
│   └── sa-ray.yaml
├── tenant-overlays/             # Per-tenant customizations
│   ├── tenant-a/
│   │   └── kustomization.yaml
│   └── tenant-b/
│       └── kustomization.yaml
├── scripts/
│   ├── onboard-tenant.sh
│   └── validate-tenant.sh
└── docs/
    ├── architecture.md
    ├── onboarding-guide.md
    └── tenant-user-guide.md
```

# Multi-Tenant KubeRay Architecture on RHOAI 2.25

## Overview

This document describes the architecture for running multi-tenant KubeRay workloads on Red Hat OpenShift AI (RHOAI) 2.25.8 with namespace-level isolation, RBAC, and Kueue-based quota management on OpenShift 4.19.

## Platform Architecture

```mermaid
graph TB
    subgraph cluster["OpenShift 4.19 Cluster"]
        subgraph ods["redhat-ods-applications"]
            RHOAI["RHOAI Operator 2.25.8"]
            CF["CodeFlare Operator<br/><i>mTLS + OAuth proxy injection</i>"]
            KR["KubeRay Operator<br/><i>RayCluster, RayJob, RayService CRDs</i>"]
            DASH["RHOAI Dashboard<br/><i>2 replicas, 3 containers each</i>"]
            NC["Notebook Controller<br/><i>ODH + upstream controllers</i>"]
        end

        subgraph kueue_ns["openshift-kueue-operator"]
            KOp["Kueue Operator<br/><i>2 replicas</i>"]
            KCM["Kueue Controller Manager<br/><i>2 replicas</i>"]
        end

        subgraph cluster_scoped["Cluster-Scoped Resources"]
            CQ["ClusterQueue: gpu-pool<br/><i>BestEffortFIFO scheduling</i>"]
            RF_CPU["ResourceFlavor: cpu-flavor"]
            RF_GPU["ResourceFlavor: gpu-flavor<br/><i>toleration: nvidia.com/gpu</i>"]
        end

        subgraph alpha["ds-team-alpha"]
            LQ_A["LocalQueue: default"]
            RQ_A["ResourceQuota: ray-quota<br/>CPU: 4 &bull; Mem: 16Gi &bull; GPU: 1"]
            RBAC_A["Role: ray-tenant-user<br/>+ 3 RoleBindings"]
            SCC_A["SCC: nonroot-v2"]
            WL_A["RayClusters / RayJobs"]
        end

        subgraph beta["ds-team-beta"]
            LQ_B["LocalQueue: default"]
            RQ_B["ResourceQuota: ray-quota<br/>CPU: 8 &bull; Mem: 32Gi &bull; GPU: 2"]
            RBAC_B["Role: ray-tenant-user<br/>+ 3 RoleBindings"]
            SCC_B["SCC: nonroot-v2"]
            WL_B["RayClusters / RayJobs"]
        end
    end

    RHOAI -->|manages| CF
    RHOAI -->|manages| KR
    RHOAI -->|manages| DASH
    RHOAI -->|manages| NC
    CF -->|injects oauth-proxy<br/>+ create-cert| WL_A
    CF -->|injects oauth-proxy<br/>+ create-cert| WL_B
    KR -->|reconciles| WL_A
    KR -->|reconciles| WL_B
    KCM -->|admission control| CQ
    CQ --> RF_CPU
    CQ --> RF_GPU
    LQ_A -->|routes to| CQ
    LQ_B -->|routes to| CQ

    style cluster fill:#f5f5f5,stroke:#333
    style ods fill:#e6f2ff,stroke:#0066cc
    style kueue_ns fill:#fff0e6,stroke:#cc6600
    style cluster_scoped fill:#f0f0f0,stroke:#666
    style alpha fill:#e6ffe6,stroke:#2e8b57
    style beta fill:#ffe6e6,stroke:#cc3333
```

## Operator Deployment (Verified)

```mermaid
graph LR
    subgraph ods_pods["redhat-ods-applications pods"]
        P1["codeflare-operator-manager<br/><i>1 replica</i>"]
        P2["kuberay-operator<br/><i>1 replica</i>"]
        P3["notebook-controller-deployment<br/><i>1 replica</i>"]
        P4["odh-notebook-controller-manager<br/><i>1 replica</i>"]
        P5["rhods-dashboard<br/><i>2 replicas × 3 containers</i>"]
    end

    subgraph kueue_pods["openshift-kueue-operator pods"]
        P6["kueue-controller-manager<br/><i>2 replicas</i>"]
        P7["openshift-kueue-operator<br/><i>2 replicas</i>"]
    end

    style ods_pods fill:#e6f2ff,stroke:#0066cc
    style kueue_pods fill:#fff0e6,stroke:#cc6600
```

## Kueue Quota Hierarchy

```mermaid
graph TD
    CQ["ClusterQueue: gpu-pool<br/>namespaceSelector: kueue.openshift.io/managed=true<br/>queueingStrategy: BestEffortFIFO"]

    subgraph resource_groups["Resource Groups"]
        RG1["CPU + Memory<br/><i>flavor: cpu-flavor</i><br/>cpu: 32 cores<br/>memory: 128Gi"]
        RG2["GPU<br/><i>flavor: gpu-flavor</i><br/>nvidia.com/gpu: 4"]
    end

    CQ --> RG1
    CQ --> RG2

    LQ_A["LocalQueue: default<br/><i>ns: ds-team-alpha</i>"]
    LQ_B["LocalQueue: default<br/><i>ns: ds-team-beta</i>"]

    LQ_A -->|clusterQueue: gpu-pool| CQ
    LQ_B -->|clusterQueue: gpu-pool| CQ

    subgraph quotas["Namespace ResourceQuotas (hard caps)"]
        Q_A["ds-team-alpha<br/>requests.cpu: 4<br/>requests.memory: 16Gi<br/>requests.nvidia.com/gpu: 1<br/>pods: 20"]
        Q_B["ds-team-beta<br/>requests.cpu: 8<br/>requests.memory: 32Gi<br/>requests.nvidia.com/gpu: 2<br/>pods: 20"]
    end

    LQ_A -.->|namespace quota| Q_A
    LQ_B -.->|namespace quota| Q_B

    style CQ fill:#fff0e6,stroke:#cc6600
    style resource_groups fill:#f5f5f5,stroke:#999
    style quotas fill:#f5f5f5,stroke:#999
```

## RBAC Model

```mermaid
graph TD
    subgraph role["Role: ray-tenant-user"]
        R1["ray.io → rayclusters, rayjobs, rayservices<br/><b>CRUD</b>"]
        R2["core → pods, pods/log, services,<br/>endpoints, configmaps, events<br/><b>CRUD</b>"]
        R3["core → secrets<br/><b>read-only</b>"]
        R4["kubeflow.org → notebooks<br/><b>CRUD</b>"]
        R5["kueue.x-k8s.io → workloads, localqueues<br/><b>read-only</b>"]
        R6["core → persistentvolumeclaims<br/><b>CRUD</b>"]
    end

    subgraph bindings["Per-Tenant RoleBindings"]
        B1["ray-tenant-binding<br/><i>Group → tenant group</i>"]
        B2["ray-sa-binding<br/><i>SA: ray-service-account</i><br/><i>SA: default</i>"]
        B3["ray-scc-binding<br/><i>ClusterRole: system:openshift:scc:nonroot-v2</i><br/><i>SA: default</i>"]
    end

    B1 -->|roleRef| role
    B2 -->|roleRef| role
    B3 -.->|SCC grant, not Role ref| SCC["nonroot-v2 SCC"]

    style role fill:#e6f2ff,stroke:#0066cc
    style bindings fill:#f0f0f0,stroke:#666
```

## Security Model

### Authentication & Authorization Flow

```mermaid
sequenceDiagram
    actor User as User (OpenShift Identity)
    participant DASH as RHOAI Dashboard
    participant WB as Workbench (Notebook)
    participant SDK as CodeFlare SDK
    participant API as Kubernetes API
    participant KR as KubeRay Operator
    participant CF as CodeFlare Operator
    participant RAY as Ray Dashboard

    User->>DASH: OpenShift OAuth login
    DASH->>WB: Launch workbench in tenant namespace
    WB->>SDK: cluster.apply()
    SDK->>API: Create RayCluster CR
    API->>API: RBAC check (ray-tenant-user Role)
    API->>KR: Reconcile RayCluster
    KR->>KR: Create head + worker pods
    CF->>KR: Inject create-cert init container (mTLS)
    CF->>KR: Inject oauth-proxy sidecar (dashboard auth)
    User->>RAY: Access dashboard via Route
    RAY->>RAY: OAuth proxy → OpenShift login required
```

### mTLS Between Ray Nodes

```mermaid
graph LR
    subgraph head["Ray Head Pod"]
        IC["init: create-cert<br/><i>generates TLS certs</i>"]
        H["ray-head container"]
        OP["oauth-proxy sidecar<br/><i>protects port 8265</i>"]
    end

    subgraph worker["Ray Worker Pod"]
        IC2["init: create-cert<br/><i>generates TLS certs</i>"]
        W["ray-worker container"]
    end

    IC -->|mounts certs| H
    IC2 -->|mounts certs| W
    H <-->|"mTLS (GCS protocol)"| W

    RT["OpenShift Route<br/><i>TLS termination</i>"] --> OP

    style head fill:#e6f2ff,stroke:#0066cc
    style worker fill:#e6ffe6,stroke:#2e8b57
```

## Workload Admission Flow

```mermaid
flowchart TD
    SUBMIT["Tenant submits RayCluster/RayJob<br/>with label: kueue.x-k8s.io/queue-name=default"]
    LQ["LocalQueue: default<br/><i>in tenant namespace</i>"]
    CQ["ClusterQueue: gpu-pool"]
    CHECK_NS["Check namespace ResourceQuota<br/><i>pods, cpu, memory, gpu caps</i>"]
    CHECK_CQ["Check ClusterQueue capacity<br/><i>32 CPU, 128Gi, 4 GPU total</i>"]
    STRATEGY["Apply BestEffortFIFO scheduling"]
    ADMIT["Workload Admitted"]
    QUEUE["Workload Queued<br/><i>wait for capacity</i>"]
    CREATE["KubeRay creates pods<br/>CodeFlare injects mTLS + OAuth"]

    SUBMIT --> LQ
    LQ --> CQ
    CQ --> CHECK_NS
    CHECK_NS --> CHECK_CQ
    CHECK_CQ --> STRATEGY
    STRATEGY -->|capacity available| ADMIT
    STRATEGY -->|no capacity| QUEUE
    ADMIT --> CREATE
    QUEUE -->|capacity freed| ADMIT

    style SUBMIT fill:#f5f5f5,stroke:#333
    style ADMIT fill:#e6ffe6,stroke:#2e8b57
    style QUEUE fill:#fff0e6,stroke:#cc6600
```

## Tenant Isolation Model

```mermaid
graph TD
    subgraph alpha["ds-team-alpha"]
        A_NS["Namespace<br/>labels: opendatahub.io/dashboard=true<br/>kueue.openshift.io/managed=true"]
        A_RQ["ResourceQuota: ray-quota<br/>requests.cpu: 4, memory: 16Gi<br/>nvidia.com/gpu: 1, pods: 20"]
        A_LR["LimitRange: ray-limits<br/>default: 2 CPU, 4Gi<br/>max: 8 CPU, 32Gi, 1 GPU"]
        A_LQ["LocalQueue: default → gpu-pool"]
        A_ROLE["Role: ray-tenant-user"]
        A_RB["RoleBinding: ray-tenant-binding<br/>→ Group: ds-team-alpha-users"]
        A_SA["ServiceAccount: ray-service-account<br/>+ RoleBinding: ray-sa-binding"]
        A_SCC["RoleBinding: ray-scc-binding<br/>→ ClusterRole: system:openshift:scc:nonroot-v2<br/>→ SA: default"]
    end

    subgraph beta["ds-team-beta"]
        B_NS["Namespace<br/>labels: opendatahub.io/dashboard=true<br/>kueue.openshift.io/managed=true"]
        B_RQ["ResourceQuota: ray-quota<br/>requests.cpu: 8, memory: 32Gi<br/>nvidia.com/gpu: 2, pods: 20"]
        B_LR["LimitRange: ray-limits<br/>default: 2 CPU, 4Gi<br/>max: 8 CPU, 32Gi, 1 GPU"]
        B_LQ["LocalQueue: default → gpu-pool"]
        B_ROLE["Role: ray-tenant-user"]
        B_RB["RoleBinding: ray-tenant-binding<br/>→ Group: ds-team-beta-users"]
        B_SA["ServiceAccount: ray-service-account<br/>+ RoleBinding: ray-sa-binding"]
        B_SCC["RoleBinding: ray-scc-binding<br/>→ ClusterRole: system:openshift:scc:nonroot-v2<br/>→ SA: default"]
    end

    alpha -.->|"DENIED: Alpha SA cannot<br/>create in Beta namespace"| beta
    beta -.->|"DENIED: Beta SA cannot<br/>create in Alpha namespace"| alpha

    style alpha fill:#e6ffe6,stroke:#2e8b57
    style beta fill:#ffe6e6,stroke:#cc3333
```

## DSC Configuration (API v1)

The DataScienceCluster custom resource on RHOAI 2.25 uses the `v1` API:

```yaml
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Managed       # Injects mTLS + OAuth into RayClusters
    ray:
      managementState: Managed       # Deploys KubeRay operator
    kueue:
      managementState: Unmanaged     # Kueue installed separately
      defaultClusterQueueName: gpu-pool
      defaultLocalQueueName: default
    dashboard:
      managementState: Managed       # RHOAI web console
    workbenches:
      managementState: Managed       # Jupyter notebook support
```

## RHOAI 2.25 vs 3.x Differences

```mermaid
graph LR
    subgraph v225["RHOAI 2.25"]
        D1["DSC API: v1"]
        D2["codeflare: Managed<br/><i>bundled with operator</i>"]
        D3["Ray Dashboard: OAuth proxy sidecar"]
        D4["mTLS: CodeFlare create-cert init"]
        D5["Kueue: separate operator<br/>managementState: Unmanaged"]
    end

    subgraph v3x["RHOAI 3.x"]
        D6["DSC API: v2"]
        D7["codeflare: separate component"]
        D8["Ray Dashboard: Gateway API / HTTPRoute"]
        D9["mTLS: cert-manager integration"]
        D10["Kueue: integrated<br/>managementState: Managed"]
    end

    style v225 fill:#e6f2ff,stroke:#0066cc
    style v3x fill:#f0f0f0,stroke:#999
```

## CodeFlare Operator Config

The `codeflare-operator-config` ConfigMap in `redhat-ods-applications` controls Ray security behavior. Key settings:

| Setting | Default | Description |
|---------|---------|-------------|
| AppWrapper autopilot | enabled | Anti-affinity injection, GPU health taints |
| Fault tolerance grace period | 60s | Admission grace period for workloads |

## Verified Deployment State

| Component | Version | Namespace | Replicas | Status |
|-----------|---------|-----------|----------|--------|
| RHOAI Operator | 2.25.8 | redhat-ods-operator | 3 | Running |
| CodeFlare Operator | (bundled) | redhat-ods-applications | 1 | Running |
| KubeRay Operator | (bundled) | redhat-ods-applications | 1 | Running |
| RHOAI Dashboard | (bundled) | redhat-ods-applications | 2 | Running |
| Notebook Controller | (bundled) | redhat-ods-applications | 2 | Running |
| Kueue Operator | 1.2.0 | openshift-kueue-operator | 2 | Running |
| Kueue Controller | (bundled) | openshift-kueue-operator | 2 | Running |

## Directory Structure

```
kray-ops/
├── platform/                    # Cluster-scoped resources (OPS)
│   ├── kustomization.yaml
│   ├── dsc.yaml                 # DataScienceCluster reference (v1 API)
│   ├── clusterqueue.yaml        # gpu-pool: 32 CPU, 128Gi, 4 GPU
│   ├── resourceflavor-cpu.yaml
│   └── resourceflavor-gpu.yaml  # GPU toleration: nvidia.com/gpu
├── tenant-base/                 # Kustomize base for all tenants
│   ├── kustomization.yaml
│   ├── namespace.yaml           # labels: dashboard=true, kueue managed=true
│   ├── resource-quota.yaml
│   ├── limit-range.yaml
│   ├── local-queue.yaml         # default → gpu-pool
│   ├── role-ray-user.yaml       # 6 rule groups
│   ├── rolebinding.yaml         # Group binding
│   ├── sa-rolebinding.yaml      # SA binding (ray-service-account + default)
│   ├── scc-binding.yaml         # nonroot-v2 for default SA
│   └── sa-ray.yaml
├── tenant-overlays/
│   ├── tenant-a/                # ds-team-alpha: 4 CPU, 16Gi, 1 GPU
│   └── tenant-b/                # ds-team-beta:  8 CPU, 32Gi, 2 GPU
├── scripts/
│   ├── onboard-tenant.sh        # Automated provisioning with pre-flight checks
│   └── validate-tenant.sh       # 11 isolation tests (RBAC, Kueue, infra)
└── docs/
    ├── architecture.md
    ├── onboarding-guide.md
    └── tenant-user-guide.md
```

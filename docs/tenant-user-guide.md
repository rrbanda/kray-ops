# Tenant User Guide -- KubeRay on RHOAI 2.25

> **Official documentation:** For the full product-supported workflow, see [Chapter 3 -- Running Ray-based distributed workloads](https://docs.redhat.com/en/documentation/red_hat_openshift_ai/) in the RHOAI 2.25 docs. This guide provides supplemental examples specific to the kray-ops tenant model.

## Getting Started

Your platform admin has provisioned a namespace for your team with:
- **KubeRay** access for creating Ray clusters and jobs
- **Kueue** integration for fair resource sharing
- **mTLS** encryption between Ray nodes
- **OAuth-protected** Ray dashboard
- **ResourceQuotas** to prevent resource exhaustion

## Check Your Access

Verify you can access your namespace:

```bash
# List your Ray resources
oc get rayclusters -n <your-namespace>
oc get rayjobs -n <your-namespace>

# Check your quota
oc describe resourcequota ray-quota -n <your-namespace>

# Check Kueue queue status
oc get localqueues -n <your-namespace>
```

## Workflow 1: Long-Running RayCluster

Create a persistent Ray cluster for interactive development:

### Using CodeFlare SDK (from a Workbench notebook)

```python
from codeflare_sdk import Cluster, ClusterConfiguration, TokenAuthentication

auth = TokenAuthentication(
    token="<your-token>",
    server="<api-server-url>",
    skip_tls=False
)
auth.login()

cluster = Cluster(
    ClusterConfiguration(
        name="my-workspace",
        namespace="<your-namespace>",
        num_workers=2,
        worker_cpu_requests=2,
        worker_memory_requests=8,
        local_queue="default",
    )
)

cluster.apply()
cluster.wait_ready()

# Connect
import ray
ray.init(cluster.cluster_uri())
```

### Using YAML (via oc CLI)

```yaml
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: my-workspace
  namespace: <your-namespace>
  labels:
    kueue.x-k8s.io/queue-name: default
spec:
  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
    template:
      spec:
        containers:
          - name: ray-head
            image: quay.io/modh/ray:2.35.0-py311-cu121
            resources:
              requests:
                cpu: "1"
                memory: 4Gi
              limits:
                cpu: "2"
                memory: 8Gi
            ports:
              - containerPort: 6379
              - containerPort: 8265
              - containerPort: 10001
  workerGroupSpecs:
    - groupName: workers
      replicas: 2
      rayStartParams: {}
      template:
        spec:
          containers:
            - name: ray-worker
              image: quay.io/modh/ray:2.35.0-py311-cu121
              resources:
                requests:
                  cpu: "1"
                  memory: 2Gi
                limits:
                  cpu: "2"
                  memory: 4Gi
```

Apply:
```bash
oc apply -f raycluster.yaml -n <your-namespace>
```

### Accessing the Ray Dashboard

The CodeFlare operator automatically creates an OAuth-protected Route:

```bash
# Find the dashboard URL
oc get route -n <your-namespace> | grep ray

# Open in browser -- you'll be prompted for OpenShift login
```

## Workflow 2: RayJob on Existing Cluster

Submit a job to your running cluster:

### Using CodeFlare SDK

```python
from codeflare_sdk import RayJob

job = RayJob(
    job_name="quick-test",
    entrypoint="python train.py",
    cluster_name="my-workspace",
    namespace="<your-namespace>",
    runtime_env={
        "working_dir": ".",
        "pip": "requirements.txt"
    }
)

job.submit()
print(job.status())
print(job.logs())
```

### Using YAML

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: quick-test
  namespace: <your-namespace>
  labels:
    kueue.x-k8s.io/queue-name: default
spec:
  entrypoint: "python -c 'import ray; ray.init(); print(ray.cluster_resources())'"
  clusterSelector:
    ray.io/cluster: my-workspace
  shutdownAfterJobFinishes: false
  suspend: false
```

## Workflow 3: Ephemeral RayJob

Submit a self-contained job that creates and destroys its own cluster:

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: batch-job
  namespace: <your-namespace>
  labels:
    kueue.x-k8s.io/queue-name: default
spec:
  entrypoint: "python -c 'import ray; ray.init(); print(sum(ray.get([ray.remote(lambda: 1).remote() for _ in range(10)])))'"
  shutdownAfterJobFinishes: true
  rayClusterSpec:
    headGroupSpec:
      rayStartParams:
        dashboard-host: "0.0.0.0"
      template:
        spec:
          containers:
            - name: ray-head
              image: quay.io/modh/ray:2.35.0-py311-cu121
              resources:
                requests:
                  cpu: "500m"
                  memory: 2Gi
                limits:
                  cpu: "1"
                  memory: 4Gi
    workerGroupSpecs:
      - groupName: workers
        replicas: 1
        rayStartParams: {}
        template:
          spec:
            containers:
              - name: ray-worker
                image: quay.io/modh/ray:2.35.0-py311-cu121
                resources:
                  requests:
                    cpu: "500m"
                    memory: 1Gi
                  limits:
                    cpu: "1"
                    memory: 2Gi
```

## Monitoring Your Resources

### Quota Usage

```bash
oc describe resourcequota ray-quota -n <your-namespace>
```

Example output:
```
Name:                    ray-quota
Namespace:               ds-team-alpha
Resource                 Used  Hard
--------                 ----  ----
limits.cpu               4     16
limits.memory            16Gi  64Gi
pods                     3     20
requests.cpu             2     4
requests.memory          8Gi   16Gi
requests.nvidia.com/gpu  0     1
```

### Kueue Workload Status

```bash
# Check if your workload is admitted or queued
oc get workloads -n <your-namespace>
```

States:
- **Admitted** -- Resources allocated, pods running
- **Pending** -- Waiting for capacity in the queue
- **Evicted** -- Preempted by a higher-priority workload

### Pod Status

```bash
oc get pods -n <your-namespace>
oc describe pod <pod-name> -n <your-namespace>
oc logs <pod-name> -n <your-namespace>
```

## Cleanup

```bash
# Delete a RayCluster
oc delete raycluster my-workspace -n <your-namespace>

# Delete a RayJob
oc delete rayjob batch-job -n <your-namespace>

# Using CodeFlare SDK
cluster.down()
```

## Limitations

- You **cannot** modify your ResourceQuota or LimitRange
- You **cannot** create resources in other team namespaces
- You **cannot** modify RBAC roles or bindings
- GPU requests are subject to both namespace quota and ClusterQueue capacity
- If the ClusterQueue is full, your workload will be queued (not rejected)

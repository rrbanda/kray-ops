# Tenant Onboarding Guide (Platform Admin)

> **See also:** The RHOAI 2.25 product documentation covers Kueue setup (Chapter 8), distributed workload configuration (Chapter 9), and project access management (Chapter 5). This guide supplements those docs with automation for quota governance and custom RBAC.

## Choosing an Onboarding Path

There are two approaches to tenant provisioning:

| Approach | How | Best For |
|----------|-----|----------|
| **This repo (oc apply -k)** | Full provisioning via Kustomize overlays. Creates namespace, labels, LocalQueue, RBAC, quotas, SCC. | Teams needing strict quota governance, custom RBAC, and repeatable GitOps automation. |
| **Dashboard + this repo** | Create project via RHOAI Dashboard (handles namespace, labels, LocalQueue, permissions), then apply only quotas/SCC from this repo. | Teams already using Dashboard for project management who need quota caps added. |

> **Do not mix both paths for the same namespace** without verifying that LocalQueue names and RBAC bindings are compatible. The Dashboard creates its own default LocalQueue and uses Admin/Contributor roles that differ from `ray-tenant-user`.

## Prerequisites

Before onboarding tenants, ensure:

1. **RHOAI 2.25** is installed with `codeflare: Managed` and `ray: Managed`
2. **Kueue Operator** is installed (channel `stable-v1.2`)
3. **Platform resources** are applied:
   ```bash
   oc apply -k platform/
   ```
4. The `gpu-pool` ClusterQueue exists:
   ```bash
   oc get clusterqueues gpu-pool
   ```

## Onboarding a New Tenant

### Step 1: Create the Overlay

Copy an existing overlay and customize:

```bash
cp -r tenant-overlays/tenant-a tenant-overlays/tenant-new
```

Edit `tenant-overlays/tenant-new/kustomization.yaml`:

- Replace all `ds-team-alpha` with your tenant namespace (e.g., `ds-team-gamma`)
- Adjust ResourceQuota values for the tenant's needs
- Set the correct group name for `ray-tenant-binding` subjects

### Step 2: Adjust Quotas

In the kustomization overlay, modify the ResourceQuota patch:

```yaml
- target:
    kind: ResourceQuota
    name: ray-quota
  patch: |
    - op: replace
      path: /spec/hard/requests.cpu
      value: "16"
    - op: replace
      path: /spec/hard/requests.memory
      value: 64Gi
    - op: replace
      path: /spec/hard/requests.nvidia.com~1gpu
      value: "4"
```

> **Important:** If you raise `limits.cpu` or `limits.memory` above the base defaults (8 CPU / 32Gi), also patch the LimitRange max to match, or individual containers will be rejected despite the higher namespace quota. See the `tenant-b` overlay for an example.

### Step 3: Set RBAC Group

Update the RoleBinding patch to bind to the correct OpenShift group:

```yaml
- target:
    kind: RoleBinding
    name: ray-tenant-binding
  patch: |
    - op: replace
      path: /subjects/0/name
      value: my-team-users    # OpenShift group name
```

### Step 4: Deploy

Use the onboard script or apply directly:

```bash
# Option A: Use the script
./scripts/onboard-tenant.sh tenant-overlays/tenant-new

# Option B: Apply directly
oc apply -k tenant-overlays/tenant-new/
```

### Step 5: Validate

Run the validation script:

```bash
./scripts/validate-tenant.sh <namespace> <test-user>

# Example:
./scripts/validate-tenant.sh ds-team-gamma system:serviceaccount:ds-team-gamma:ray-service-account
```

All 14 tests should pass:
- 6 RBAC tests (create/list in own namespace, denied elsewhere)
- 2 Kueue tests (LocalQueue exists, Workload read access)
- 6 Infrastructure tests (ResourceQuota, LimitRange, ServiceAccount, SCC/group/SA RoleBindings)

### Step 6: Configure Image-Pull Access (if needed)

This repo does not manage image-pull secrets. If your Ray container images are in a private registry, create an image-pull secret in the tenant namespace and link it to `ray-service-account`:

```bash
oc create secret docker-registry ray-pull-secret \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<token> \
  -n <tenant-namespace>

oc secrets link ray-service-account ray-pull-secret --for=pull -n <tenant-namespace>
```

For the default RHOAI image (`quay.io/modh/ray:2.35.0-py311-cu121`), no pull secret is needed -- it is publicly accessible.

## Adjusting ClusterQueue Capacity

To change the total resource pool available to all tenants:

```bash
oc edit clusterqueue gpu-pool
```

Modify `nominalQuota` values under `resourceGroups`:
- `cpu` -- Total CPU cores available
- `memory` -- Total memory available
- `nvidia.com/gpu` -- Total GPU count

## Adding GPU Node Tolerance

If GPU nodes have taints, update `platform/resourceflavor-gpu.yaml`:

```yaml
spec:
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
```

## Removing a Tenant

```bash
# Delete all tenant resources
oc delete -k tenant-overlays/tenant-name/

# This removes: namespace, quota, RBAC, LocalQueue, and all workloads within
```

## Troubleshooting

### Tenant Cannot Create RayClusters

1. Check the RoleBinding exists:
   ```bash
   oc get rolebinding -n <tenant-ns>
   ```
2. Verify the user is in the correct group:
   ```bash
   oc get group <group-name> -o yaml
   ```
3. Test permissions:
   ```bash
   oc auth can-i create rayclusters.ray.io -n <tenant-ns> --as=<user>
   ```

### RayCluster Pods Not Scheduling

1. Check Kueue workload status:
   ```bash
   oc get workloads -n <tenant-ns>
   ```
2. Check ResourceQuota usage:
   ```bash
   oc describe resourcequota ray-quota -n <tenant-ns>
   ```
3. Check ClusterQueue capacity:
   ```bash
   oc describe clusterqueue gpu-pool
   ```

### OAuth Proxy Errors on Ray Dashboard

1. Verify CodeFlare config:
   ```bash
   oc get cm codeflare-operator-config -n redhat-ods-applications -o yaml
   ```
2. Check OAuth proxy sidecar logs:
   ```bash
   oc logs <head-pod> -c oauth-proxy -n <tenant-ns>
   ```

### mTLS Certificate Issues

1. Check the `create-cert` init container:
   ```bash
   oc logs <head-pod> -c create-cert -n <tenant-ns>
   ```
2. Verify SCC binding:
   ```bash
   oc get rolebinding ray-scc-binding -n <tenant-ns> -o yaml
   ```

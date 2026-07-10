#!/bin/bash
# onboard-tenant.sh -- Onboard a new tenant for KubeRay on RHOAI 2.25
#
# Usage:
#   ./scripts/onboard-tenant.sh <tenant-overlay-dir>
#
# Example:
#   ./scripts/onboard-tenant.sh tenant-overlays/tenant-a
set -euo pipefail

OVERLAY_DIR="${1:?Usage: onboard-tenant.sh <tenant-overlay-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/$OVERLAY_DIR/kustomization.yaml" ]; then
  echo "ERROR: $OVERLAY_DIR/kustomization.yaml not found"
  exit 1
fi

echo "=========================================="
echo "  KubeRay Tenant Onboarding"
echo "  Overlay: $OVERLAY_DIR"
echo "=========================================="
echo ""

# Pre-flight: check KubeRay + CodeFlare operators
echo "--- Pre-flight checks ---"
if ! oc get pods -n redhat-ods-applications 2>/dev/null | grep -q 'kuberay-operator.*Running'; then
  echo "ERROR: KubeRay operator not running. Enable ray: Managed in DSC first."
  exit 1
fi
if ! oc get pods -n redhat-ods-applications 2>/dev/null | grep -q 'codeflare-operator.*Running'; then
  echo "ERROR: CodeFlare operator not running. Enable codeflare: Managed in DSC first."
  exit 1
fi
echo "  KubeRay operator: Running"
echo "  CodeFlare operator: Running"

# Check Kueue
if ! oc get clusterqueues gpu-pool &>/dev/null; then
  echo "  ClusterQueue 'gpu-pool' not found. Applying platform manifests..."
  oc apply -k "$REPO_ROOT/platform/"
  echo "  Platform resources created."
fi
echo "  ClusterQueue: gpu-pool exists"
echo ""

# Apply tenant overlay
echo "--- Applying tenant overlay ---"
oc apply -k "$REPO_ROOT/$OVERLAY_DIR"
echo ""

# Extract namespace from overlay
TENANT_NS=$(oc kustomize "$REPO_ROOT/$OVERLAY_DIR" | grep 'kind: Namespace' -A2 | grep 'name:' | head -1 | awk '{print $2}')
echo "--- Tenant namespace: $TENANT_NS ---"

# Verify
echo ""
echo "--- Verification ---"
echo "Namespace:"
oc get ns "$TENANT_NS" --show-labels 2>/dev/null | head -2
echo ""
echo "ResourceQuota:"
oc get resourcequota -n "$TENANT_NS" 2>/dev/null
echo ""
echo "LocalQueue:"
oc get localqueues -n "$TENANT_NS" 2>/dev/null
echo ""
echo "Role:"
oc get role ray-tenant-user -n "$TENANT_NS" 2>/dev/null
echo ""
echo "RoleBinding:"
oc get rolebinding -n "$TENANT_NS" 2>/dev/null

echo ""
echo "=========================================="
echo "  Tenant '$TENANT_NS' onboarded!"
echo "=========================================="
echo ""
echo "Next steps for tenants:"
echo "  - Create RayClusters: oc apply -f raycluster.yaml -n $TENANT_NS"
echo "  - Use CodeFlare SDK from a workbench in this namespace"
echo "  - View quota: oc get resourcequota -n $TENANT_NS"

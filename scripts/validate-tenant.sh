#!/bin/bash
# validate-tenant.sh -- Validate tenant isolation for KubeRay
#
# Usage:
#   ./scripts/validate-tenant.sh <tenant-namespace> [tenant-user]
#
# Tests RBAC, quota, and Kueue configuration for a tenant namespace.
# If tenant-user is omitted, uses system:serviceaccount:<ns>:ray-service-account
set -euo pipefail

TENANT_NS="${1:?Usage: validate-tenant.sh <tenant-namespace> [tenant-user]}"
TENANT_USER="${2:-system:serviceaccount:${TENANT_NS}:ray-service-account}"

echo "=========================================="
echo "  Tenant Isolation Validation"
echo "  Namespace: $TENANT_NS"
echo "  User: $TENANT_USER"
echo "=========================================="
echo ""

PASS=0
FAIL=0

can_i() {
  if oc auth can-i "$@" 2>/dev/null | grep -q "^yes"; then
    echo "yes"
  else
    echo "no"
  fi
}

check() {
  local desc="$1"
  local expected="$2"
  local got="$3"
  if [ "$got" = "$expected" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected=$expected, got=$got)"
    FAIL=$((FAIL + 1))
  fi
}

resource_exists() {
  if oc get "$@" &>/dev/null; then echo "yes"; else echo "no"; fi
}

echo "--- RBAC Tests ---"
check "Create RayCluster in $TENANT_NS" "yes" \
  "$(can_i create rayclusters.ray.io -n "$TENANT_NS" --as="$TENANT_USER")"

check "List pods in $TENANT_NS" "yes" \
  "$(can_i list pods -n "$TENANT_NS" --as="$TENANT_USER")"

check "Cannot create RayCluster in default" "no" \
  "$(can_i create rayclusters.ray.io -n default --as="$TENANT_USER")"

check "Cannot modify ResourceQuota" "no" \
  "$(can_i update resourcequotas -n "$TENANT_NS" --as="$TENANT_USER")"

check "Cannot create Roles" "no" \
  "$(can_i create roles -n "$TENANT_NS" --as="$TENANT_USER")"

check "Cannot create ClusterRoles" "no" \
  "$(can_i create clusterroles --as="$TENANT_USER")"

echo ""
echo "--- Kueue Tests ---"
check "LocalQueue exists" "yes" \
  "$(resource_exists localqueue default -n "$TENANT_NS")"

check "Can read Kueue Workloads" "yes" \
  "$(can_i list workloads.kueue.x-k8s.io -n "$TENANT_NS" --as="$TENANT_USER")"

echo ""
echo "--- Infrastructure Tests ---"
check "ResourceQuota exists" "yes" \
  "$(resource_exists resourcequota ray-quota -n "$TENANT_NS")"

check "LimitRange exists" "yes" \
  "$(resource_exists limitrange ray-limits -n "$TENANT_NS")"

check "ServiceAccount exists" "yes" \
  "$(resource_exists sa ray-service-account -n "$TENANT_NS")"

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

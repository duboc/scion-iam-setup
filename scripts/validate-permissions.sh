#!/usr/bin/env bash
# Standalone, read-only GCP permission validator for Scion operators.
# Requires NO Scion repository checkout and creates NO GCP resources.
#
# Uses GCP Resource Manager's `projects.testIamPermissions` API to verify
# whether the current user (or an impersonated principal) holds all effective
# permissions required for the chosen Scion deployment tier.
set -euo pipefail

PROJECT_ID=""
TIER="full-operator"
IMPERSONATE_SA=""
CHECK_APIS="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/validate-permissions.sh \
    [--project <GCP_PROJECT_ID>] \
    [--tier <phase1-bootstrap|vm|hybrid|cloudrun|ha-gcloud|ha-terraform|full-operator>] \
    [--impersonate-service-account <sa@project.iam.gserviceaccount.com>] \
    [--check-apis]

Tiers:
  phase1-bootstrap  Checks ONLY Option 1A permissions (roles/editor + roles/resourcemanager.projectIamAdmin).
                    If this passes, you can self-grant all remaining roles using ./scripts/grant-deployer-iam.sh.
  vm                Single-Node GCE VM + Cloud Run IAP Proxy
  hybrid            Single-Node GCE VM + GKE Agent Cluster + Cloud Filestore NFS
  cloudrun          Single-Node Cloud Run Sandbox
  ha-gcloud         HA Hub on Cloud Run + GKE (manual gcloud setup)
  ha-terraform      Multi-Hub HA via Terraform
  full-operator     (Default) All permissions across every tier, IAP login/SSH, Secret Manager, and Vertex AI

Options:
  --project <id>                        Target GCP Project ID (defaults to active `gcloud config get-value project`)
  --tier <tier>                         Permission bundle to validate (default: full-operator)
  --impersonate-service-account <email> Validate effective permissions of a Service Account via impersonation
  --check-apis                          Also check whether the required GCP APIs (*.googleapis.com) are enabled
  -h, --help                            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --tier)
      TIER="${2:-}"
      shift 2
      ;;
    --impersonate-service-account)
      IMPERSONATE_SA="${2:-}"
      shift 2
      ;;
    --check-apis)
      CHECK_APIS="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for bin in gcloud curl jq; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Error: Required command '${bin}' not found in PATH." >&2
    exit 1
  fi
done

if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Error: --project <GCP_PROJECT_ID> is required (no active gcloud project set)." >&2
  usage >&2
  exit 1
fi

if [[ -n "${IMPERSONATE_SA}" ]]; then
  export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${IMPERSONATE_SA}"
  CALLER_IDENTITY="${IMPERSONATE_SA} (impersonated)"
  SUGGESTED_MEMBER="serviceAccount:${IMPERSONATE_SA}"
else
  ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)"
  if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
    echo "Error: No active gcloud account found. Run: gcloud auth login" >&2
    exit 1
  fi
  CALLER_IDENTITY="${ACTIVE_ACCOUNT}"
  if [[ "${ACTIVE_ACCOUNT}" == *.gserviceaccount.com ]]; then
    SUGGESTED_MEMBER="serviceAccount:${ACTIVE_ACCOUNT}"
  else
    SUGGESTED_MEMBER="user:${ACTIVE_ACCOUNT}"
  fi
fi

# Each entry is: "permission|providing_role|description"
BASE_BOOTSTRAP_ENTRIES=(
  "resourcemanager.projects.get|roles/editor|Read project metadata"
  "resourcemanager.projects.getIamPolicy|roles/resourcemanager.projectIamAdmin|Read project IAM policy"
  "resourcemanager.projects.setIamPolicy|roles/resourcemanager.projectIamAdmin|Bind project IAM roles (Option 1A self-bootstrap)"
  "serviceusage.services.enable|roles/editor or roles/serviceusage.serviceUsageAdmin|Enable GCP APIs (*.googleapis.com)"
  "serviceusage.services.list|roles/editor or roles/serviceusage.serviceUsageAdmin|List enabled GCP APIs"
  "iam.serviceAccounts.create|roles/editor or roles/iam.serviceAccountAdmin|Create GCP Service Accounts"
  "iam.serviceAccounts.actAs|roles/editor or roles/iam.serviceAccountUser|Attach/impersonate Service Accounts (actAs)"
)

VM_ENTRIES=(
  "compute.instances.create|roles/editor|Create GCE Hub VM"
  "compute.networks.create|roles/editor or roles/compute.networkAdmin|Create VPC network"
  "compute.subnetworks.create|roles/editor or roles/compute.networkAdmin|Create VPC subnetwork"
  "compute.routers.create|roles/editor or roles/compute.networkAdmin|Create Cloud Router & Cloud NAT"
  "compute.firewalls.create|roles/editor or roles/compute.networkAdmin|Create VPC firewall rules"
  "artifactregistry.repositories.create|roles/editor|Create Artifact Registry repository"
  "run.services.create|roles/editor or roles/run.admin|Deploy Cloud Run IAP proxy / Hub service"
  "run.services.getIamPolicy|roles/run.admin|Read Cloud Run service IAM policy"
  "run.services.setIamPolicy|roles/run.admin|Grant roles/run.invoker on Cloud Run service"
  "aiplatform.endpoints.predict|roles/aiplatform.user or roles/aiplatform.admin|Invoke Vertex AI / Model Garden endpoints"
)

HYBRID_EXTRA_ENTRIES=(
  "iam.serviceAccounts.getIamPolicy|roles/iam.serviceAccountAdmin|Read Service Account IAM policy"
  "iam.serviceAccounts.setIamPolicy|roles/iam.serviceAccountAdmin|Bind tokenCreator / Workload Identity on Service Accounts"
  "iap.web.setIamPolicy|roles/iap.admin|Configure IAP web policy"
  "iap.webServices.setIamPolicy|roles/iap.admin|Bind roles/iap.httpsResourceAccessor on Cloud Run IAP"
  "container.clusters.create|roles/editor or roles/container.admin|Create/manage GKE clusters"
)

HA_TERRAFORM_EXTRA_ENTRIES=(
  "secretmanager.secrets.create|roles/editor or roles/secretmanager.admin|Create Secret Manager secrets"
  "secretmanager.secrets.setIamPolicy|roles/secretmanager.admin|Bind per-secret IAM policies (Terraform HA)"
  "servicenetworking.services.addPeering|roles/servicenetworking.networksAdmin|Configure Private Service Access VPC peering"
  "storage.buckets.create|roles/editor or roles/storage.admin|Create GCS buckets"
  "storage.buckets.setIamPolicy|roles/storage.admin|Bind GCS bucket IAM policies (not included in roles/owner!)"
)

FULL_OPERATOR_EXTRA_ENTRIES=(
  "iam.roles.get|roles/iam.securityReviewer|Inspect IAM role definitions & Policy Troubleshooter"
  "iap.webServiceVersions.accessViaIAP|roles/iap.httpsResourceAccessor|Log into IAP-protected Scion Web UI & CLI (not in roles/owner!)"
  "iap.tunnelInstances.accessViaIAP|roles/iap.tunnelResourceAccessor|SSH into private GCE VMs via IAP TCP tunnel"
)

ENTRIES=("${BASE_BOOTSTRAP_ENTRIES[@]}")

case "${TIER}" in
  phase1-bootstrap)
    ;;
  vm)
    ENTRIES+=("${VM_ENTRIES[@]}")
    ;;
  hybrid|cloudrun|ha-gcloud)
    ENTRIES+=(
      "${VM_ENTRIES[@]}"
      "${HYBRID_EXTRA_ENTRIES[@]}"
    )
    ;;
  ha-terraform)
    ENTRIES+=(
      "${VM_ENTRIES[@]}"
      "${HYBRID_EXTRA_ENTRIES[@]}"
      "${HA_TERRAFORM_EXTRA_ENTRIES[@]}"
    )
    ;;
  full-operator)
    ENTRIES+=(
      "${VM_ENTRIES[@]}"
      "${HYBRID_EXTRA_ENTRIES[@]}"
      "${HA_TERRAFORM_EXTRA_ENTRIES[@]}"
      "${FULL_OPERATOR_EXTRA_ENTRIES[@]}"
    )
    ;;
  *)
    echo "Error: Invalid --tier '${TIER}'." >&2
    usage >&2
    exit 1
    ;;
esac

echo "==================================================================="
echo "Scion GCP Permission Validator (Read-Only)"
echo "==================================================================="
echo "  Project ID       : ${PROJECT_ID}"
echo "  Caller Principal : ${CALLER_IDENTITY}"
echo "  Validation Tier  : ${TIER}"
echo "==================================================================="

TOKEN="$(gcloud auth print-access-token)"

PERMS_JSON="["
FIRST="true"
for entry in "${ENTRIES[@]}"; do
  perm="${entry%%|*}"
  if [[ "${FIRST}" == "true" ]]; then
    PERMS_JSON+="\"${perm}\""
    FIRST="false"
  else
    PERMS_JSON+=",\"${perm}\""
  fi
done
PERMS_JSON+="]"

RESP="$(curl -sS -X POST "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"permissions\":${PERMS_JSON}}")"

if echo "${RESP}" | jq -e '.error' >/dev/null 2>&1; then
  echo "Error calling testIamPermissions on project '${PROJECT_ID}':" >&2
  echo "${RESP}" | jq -r '.error.message' >&2
  exit 1
fi

GRANTED_LIST="$(echo "${RESP}" | jq -r '.permissions[]? // empty')"

PASS_COUNT=0
FAIL_COUNT=0
HAS_SET_IAM_POLICY="false"
if grep -qxF "resourcemanager.projects.setIamPolicy" <<< "${GRANTED_LIST}"; then
  HAS_SET_IAM_POLICY="true"
fi

echo ""
printf "%-10s %-42s %-45s\n" "STATUS" "PERMISSION" "PROVIDED BY ROLE"
printf "%-10s %-42s %-45s\n" "------" "----------" "----------------"

for entry in "${ENTRIES[@]}"; do
  perm="${entry%%|*}"
  rest="${entry#*|}"
  role="${rest%%|*}"
  if grep -qxF "${perm}" <<< "${GRANTED_LIST}"; then
    printf "%-10s %-42s %-45s\n" "[PASS]" "${perm}" "${role}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf "%-10s %-42s %-45s\n" "[MISSING]" "${perm}" "${role}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

API_MISSING_COUNT=0
if [[ "${CHECK_APIS}" == "true" ]]; then
  echo ""
  echo "-------------------------------------------------------------------"
  echo "Checking Enabled GCP APIs (*.googleapis.com)..."
  echo "-------------------------------------------------------------------"
  REQUIRED_APIS=(
    "serviceusage.googleapis.com"
    "cloudresourcemanager.googleapis.com"
    "iam.googleapis.com"
    "iamcredentials.googleapis.com"
    "compute.googleapis.com"
    "run.googleapis.com"
    "iap.googleapis.com"
    "cloudbuild.googleapis.com"
    "secretmanager.googleapis.com"
    "storage.googleapis.com"
    "artifactregistry.googleapis.com"
    "policytroubleshooter.googleapis.com"
    "aiplatform.googleapis.com"
    "logging.googleapis.com"
    "monitoring.googleapis.com"
    "cloudtrace.googleapis.com"
  )
  if [[ "${TIER}" == "hybrid" ]]; then
    REQUIRED_APIS+=("container.googleapis.com" "file.googleapis.com" "vpcaccess.googleapis.com")
  elif [[ "${TIER}" == "ha-gcloud" || "${TIER}" == "ha-terraform" || "${TIER}" == "full-operator" ]]; then
    REQUIRED_APIS+=("container.googleapis.com" "sqladmin.googleapis.com" "file.googleapis.com" "servicenetworking.googleapis.com" "vpcaccess.googleapis.com")
  fi

  ENABLED_APIS="$(gcloud services list --enabled --project="${PROJECT_ID}" --format="value(config.name)" 2>/dev/null || true)"
  for api in "${REQUIRED_APIS[@]}"; do
    if grep -qxF "${api}" <<< "${ENABLED_APIS}"; then
      printf "%-10s %-42s\n" "[ENABLED]" "${api}"
    else
      printf "%-10s %-42s\n" "[DISABLED]" "${api}"
      API_MISSING_COUNT=$((API_MISSING_COUNT + 1))
    fi
  done
fi

echo ""
echo "==================================================================="
echo "Summary: ${PASS_COUNT} permissions present, ${FAIL_COUNT} missing."
if [[ "${CHECK_APIS}" == "true" ]]; then
  echo "APIs   : ${API_MISSING_COUNT} required APIs disabled."
fi
echo "==================================================================="

if [[ "${FAIL_COUNT}" -eq 0 && "${API_MISSING_COUNT}" -eq 0 ]]; then
  echo "SUCCESS: ${CALLER_IDENTITY} has all required permissions for tier '${TIER}'."
  exit 0
fi

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo ""
  if [[ "${HAS_SET_IAM_POLICY}" == "true" ]]; then
    echo "GOOD NEWS: You already hold 'resourcemanager.projects.setIamPolicy' (Option 1A / Project IAM Admin)!"
    echo "You can self-grant all missing roles right now from your own account by running:"
    echo ""
    echo "  ./scripts/grant-deployer-iam.sh \\"
    echo "    --project ${PROJECT_ID} \\"
    echo "    --member ${SUGGESTED_MEMBER} \\"
    echo "    --tier ${TIER/#phase1-bootstrap/full-operator}"
  else
    echo "ACTION REQUIRED (Phase 1): You do not hold 'resourcemanager.projects.setIamPolicy'."
    echo "Ask a Project Owner or Cloud IAM Admin to grant you Option 1A (minimal 2-role bootstrap):"
    echo ""
    echo "  gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=${SUGGESTED_MEMBER} --role=roles/editor"
    echo "  gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=${SUGGESTED_MEMBER} --role=roles/resourcemanager.projectIamAdmin"
    echo ""
    echo "Or ask them to run:"
    echo "  ./scripts/grant-deployer-iam.sh --project ${PROJECT_ID} --member ${SUGGESTED_MEMBER} --tier ${TIER/#phase1-bootstrap/full-operator} --include-editor"
  fi
fi

if [[ "${API_MISSING_COUNT}" -gt 0 ]]; then
  echo ""
  echo "To enable the missing GCP APIs, run:"
  echo "  ./scripts/enable-apis.sh --project ${PROJECT_ID} --tier all --ensure-default-network"
fi

exit 1

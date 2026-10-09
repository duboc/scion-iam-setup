#!/usr/bin/env bash
# Grant the required GCP IAM roles to a human operator or CI deployer principal
# so they can deploy, configure, and operate Scion end-to-end from their account.
#
# NOTE: Whoever runs this script must already hold `roles/owner` or
# `roles/resourcemanager.projectIamAdmin` on the target GCP project.
set -euo pipefail

PROJECT_ID=""
MEMBER=""
TIER="full-operator"
INCLUDE_EDITOR="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/grant-deployer-iam.sh \
    --project <GCP_PROJECT_ID> \
    --member <user:you@example.com|serviceAccount:ci@proj.iam.gserviceaccount.com> \
    [--tier <full-operator|vm|hybrid|cloudrun|ha-gcloud|ha-terraform>] \
    [--include-editor] \
    [--dry-run]

Tiers (Additive roles on top of roles/editor):
  full-operator  (Default) Complete self-sufficiency for a human operator to deploy ANY tier,
                 configure IAM/SAs, enable Vertex AI & Model Garden, manage secrets, access
                 the Hub UI/CLI through IAP, SSH into VMs via IAP, and pass actAs checks.
  vm             Single-Node GCE VM + Cloud Run IAP Proxy (scripts/single-node-vm/deploy.sh)
  hybrid         Single-Node GCE VM + GKE Agent Cluster + Cloud Filestore NFS
  cloudrun       Single-Node Cloud Run Sandbox (scripts/single-node/deploy.sh)
  ha-gcloud      HA Hub on Cloud Run + GKE (manual gcloud runbook)
  ha-terraform   Multi-Hub HA via Terraform (deploy/terraform/)

Options:
  --project <id>      Target GCP Project ID (required)
  --member <member>   IAM principal, e.g. user:alice@example.com or serviceAccount:... (required)
  --tier <tier>       Role bundle to grant (default: full-operator)
  --include-editor    Also grant roles/editor if the principal does not already have it
  --dry-run           Print the gcloud commands without executing them
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --member)
      MEMBER="${2:-}"
      shift 2
      ;;
    --tier)
      TIER="${2:-}"
      shift 2
      ;;
    --include-editor)
      INCLUDE_EDITOR="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
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

if [[ -z "${PROJECT_ID}" || -z "${MEMBER}" ]]; then
  echo "Error: Both --project <GCP_PROJECT_ID> and --member <user:...|serviceAccount:...> are required." >&2
  usage >&2
  exit 1
fi

if [[ "${MEMBER}" != user:* && "${MEMBER}" != serviceAccount:* && "${MEMBER}" != group:* ]]; then
  echo "Error: --member must start with 'user:', 'serviceAccount:', or 'group:' (got '${MEMBER}')." >&2
  exit 1
fi

ROLES=()

if [[ "${INCLUDE_EDITOR}" == "true" ]]; then
  ROLES+=("roles/editor")
fi

case "${TIER}" in
  vm)
    ROLES+=(
      "roles/resourcemanager.projectIamAdmin"
      "roles/run.admin"
      "roles/iap.admin"
      "roles/iap.httpsResourceAccessor"
      "roles/iap.tunnelResourceAccessor"
      "roles/compute.networkAdmin"
    )
    ;;
  hybrid)
    ROLES+=(
      "roles/resourcemanager.projectIamAdmin"
      "roles/run.admin"
      "roles/iam.serviceAccountAdmin"
      "roles/iap.admin"
      "roles/iap.httpsResourceAccessor"
      "roles/iap.tunnelResourceAccessor"
      "roles/compute.networkAdmin"
    )
    ;;
  cloudrun|ha-gcloud)
    ROLES+=(
      "roles/resourcemanager.projectIamAdmin"
      "roles/iam.serviceAccountAdmin"
      "roles/iam.serviceAccountUser"
      "roles/run.admin"
      "roles/iap.admin"
    )
    ;;
  ha-terraform)
    ROLES+=(
      "roles/resourcemanager.projectIamAdmin"
      "roles/iam.serviceAccountAdmin"
      "roles/run.admin"
      "roles/iap.admin"
      "roles/secretmanager.admin"
      "roles/compute.networkAdmin"
      "roles/servicenetworking.networksAdmin"
      "roles/container.admin"
      "roles/storage.admin"
    )
    ;;
  full-operator)
    ROLES+=(
      "roles/resourcemanager.projectIamAdmin"
      "roles/iam.serviceAccountAdmin"
      "roles/iam.serviceAccountUser"
      "roles/iam.securityReviewer"
      "roles/run.admin"
      "roles/iap.admin"
      "roles/iap.httpsResourceAccessor"
      "roles/iap.tunnelResourceAccessor"
      "roles/secretmanager.admin"
      "roles/compute.networkAdmin"
      "roles/servicenetworking.networksAdmin"
      "roles/container.admin"
      "roles/storage.admin"
      "roles/aiplatform.admin"
      "roles/serviceusage.serviceUsageAdmin"
    )
    ;;
  *)
    echo "Error: Invalid --tier '${TIER}'. Expected one of: full-operator, vm, hybrid, cloudrun, ha-gcloud, ha-terraform." >&2
    exit 1
    ;;
esac

echo "==> Target GCP Project : ${PROJECT_ID}"
echo "==> Target Principal   : ${MEMBER}"
echo "==> Selected Tier      : ${TIER}"
echo "==> Roles to Grant (${#ROLES[@]}):"
for role in "${ROLES[@]}"; do
  echo "    - ${role}"
done
echo ""

for role in "${ROLES[@]}"; do
  CMD=(
    "gcloud" "projects" "add-iam-policy-binding" "${PROJECT_ID}"
    "--member=${MEMBER}"
    "--role=${role}"
    "--condition=None"
    "--quiet"
  )
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "${CMD[@]}"
    echo ""
  else
    echo "--> Granting ${role} to ${MEMBER}..."
    "${CMD[@]}" >/dev/null
  fi
done

echo ""
echo "==> Completed IAM role grants for ${MEMBER} on project ${PROJECT_ID}."

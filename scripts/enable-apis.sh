#!/usr/bin/env bash
# Enable required GCP APIs for Scion deployments and runtime features.
set -euo pipefail

PROJECT_ID=""
TIER="all"
ENSURE_DEFAULT_NETWORK="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/enable-apis.sh --project <GCP_PROJECT_ID> [--tier <vm|cloudrun|hybrid|ha|all>] [--ensure-default-network] [--dry-run]

Tiers:
  vm        Single-Node GCE VM + Cloud Run IAP Proxy + Vertex AI + IAM Minting/Troubleshooting
  cloudrun  Single-Node Cloud Run Sandbox + IAP + Vertex AI + IAM Minting/Troubleshooting
  hybrid    GCE VM Hub + GKE Agent Cluster + Cloud Filestore (NFS) + Vertex AI
  ha        Multi-Hub / HA (Cloud Run + Cloud SQL + GKE + Filestore + Service Networking + Vertex AI)
  all       All APIs across every Scion deployment mode (default)

Options:
  --project <id>             Target GCP Project ID (required)
  --tier <tier>              Deployment tier (default: all)
  --ensure-default-network   Create the auto-mode 'default' VPC network if skipped by org policy
                             (constraints/compute.skipDefaultNetworkCreation)
  --dry-run                  Print the gcloud commands without executing them
  -h, --help                 Show this help message
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
    --ensure-default-network)
      ENSURE_DEFAULT_NETWORK="true"
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

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Error: --project <GCP_PROJECT_ID> is required." >&2
  usage >&2
  exit 1
fi

CORE_APIS=(
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

HYBRID_APIS=(
  "container.googleapis.com"
  "file.googleapis.com"
  "vpcaccess.googleapis.com"
)

HA_APIS=(
  "container.googleapis.com"
  "sqladmin.googleapis.com"
  "file.googleapis.com"
  "servicenetworking.googleapis.com"
  "vpcaccess.googleapis.com"
)

APIS=("${CORE_APIS[@]}")

case "${TIER}" in
  vm|cloudrun)
    ;;
  hybrid)
    APIS+=("${HYBRID_APIS[@]}")
    ;;
  ha|all)
    APIS+=("${HA_APIS[@]}")
    ;;
  *)
    echo "Error: Invalid --tier '${TIER}'. Expected one of: vm, cloudrun, hybrid, ha, all." >&2
    exit 1
    ;;
esac

echo "==> Target GCP Project : ${PROJECT_ID}"
echo "==> Selected Tier      : ${TIER}"
echo "==> APIs to Enable (${#APIS[@]}):"
for api in "${APIS[@]}"; do
  echo "    - ${api}"
done

BATCH_SIZE=15
TOTAL_APIS="${#APIS[@]}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "[DRY-RUN] Would execute (in batches of <= ${BATCH_SIZE} due to GCP Service Usage 20-service batch limit):"
  for ((i = 0; i < TOTAL_APIS; i += BATCH_SIZE)); do
    BATCH=("${APIS[@]:i:BATCH_SIZE}")
    CMD=("gcloud" "services" "enable" "${BATCH[@]}" "--project=${PROJECT_ID}")
    printf '  %q' "${CMD[@]}"
    echo ""
  done
  if [[ "${ENSURE_DEFAULT_NETWORK}" == "true" ]]; then
    echo "  gcloud compute networks describe default --project=${PROJECT_ID} || gcloud compute networks create default --project=${PROJECT_ID} --subnet-mode=auto"
  fi
  exit 0
fi

echo ""
echo "==> Enabling APIs (in batches of <= ${BATCH_SIZE})..."
for ((i = 0; i < TOTAL_APIS; i += BATCH_SIZE)); do
  BATCH=("${APIS[@]:i:BATCH_SIZE}")
  echo "--> Enabling batch ($((i + 1))..$((i + ${#BATCH[@]})) of ${TOTAL_APIS})..."
  gcloud services enable "${BATCH[@]}" "--project=${PROJECT_ID}" --quiet
done

if [[ "${ENSURE_DEFAULT_NETWORK}" == "true" ]]; then
  echo ""
  echo "==> Checking for 'default' VPC network..."
  if gcloud compute networks describe default "--project=${PROJECT_ID}" --quiet &>/dev/null; then
    echo "    'default' VPC network already exists."
  else
    echo "    'default' VPC network missing (org policy skipDefaultNetworkCreation). Creating auto-mode 'default' network..."
    gcloud compute networks create default "--project=${PROJECT_ID}" --subnet-mode=auto --quiet
  fi
fi

echo "==> Done. Reminder: Third-party Model Garden models (e.g. Anthropic Claude on Vertex AI)"
echo "    must also have their EULA/terms accepted manually in the GCP Console -> Vertex AI -> Model Garden."

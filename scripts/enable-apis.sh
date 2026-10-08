#!/usr/bin/env bash
# Enable required GCP APIs for Scion deployments and runtime features.
set -euo pipefail

PROJECT_ID=""
TIER="all"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/enable-apis.sh --project <GCP_PROJECT_ID> [--tier <vm|cloudrun|hybrid|ha|all>] [--dry-run]

Tiers:
  vm        Single-Node GCE VM + Cloud Run IAP Proxy + Vertex AI + IAM Minting/Troubleshooting
  cloudrun  Single-Node Cloud Run Sandbox + IAP + Vertex AI + IAM Minting/Troubleshooting
  hybrid    GCE VM Hub + GKE Agent Cluster + Cloud Filestore (NFS) + Vertex AI
  ha        Multi-Hub / HA (Cloud Run + Cloud SQL + GKE + Filestore + Service Networking + Vertex AI)
  all       All APIs across every Scion deployment mode (default)

Options:
  --project <id>   Target GCP Project ID (required)
  --tier <tier>    Deployment tier (default: all)
  --dry-run        Print the gcloud command without executing it
  -h, --help       Show this help message
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
  "compute.googleapis.com"
  "run.googleapis.com"
  "iap.googleapis.com"
  "secretmanager.googleapis.com"
  "storage.googleapis.com"
  "artifactregistry.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudresourcemanager.googleapis.com"
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

CMD=("gcloud" "services" "enable" "${APIS[@]}" "--project=${PROJECT_ID}")

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "[DRY-RUN] Would execute:"
  printf '  %q' "${CMD[@]}"
  echo ""
  exit 0
fi

echo ""
echo "==> Enabling APIs..."
"${CMD[@]}"
echo "==> Done. Reminder: Third-party Model Garden models (e.g. Anthropic Claude on Vertex AI)"
echo "    must also have their EULA/terms accepted manually in the GCP Console -> Vertex AI -> Model Garden."

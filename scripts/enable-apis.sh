#!/usr/bin/env bash
# Enable required GCP APIs for Scion deployments and optionally ensure the
# project VPC network (<PROJECT_ID>) and IAP SSH firewall rule exist.
set -euo pipefail

PROJECT_ID=""
TIER="all"
REGION="us-central1"
ENSURE_VPC="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/enable-apis.sh \
    --project <GCP_PROJECT_ID> \
    [--tier <vm|cloudrun|hybrid|ha|all>] \
    [--ensure-vpc] \
    [--region <us-central1>] \
    [--dry-run]

Tiers:
  vm        Single-Node GCE VM + Cloud Run IAP Proxy + Vertex AI + IAM Minting/Troubleshooting
  cloudrun  Single-Node Cloud Run Sandbox + IAP + Vertex AI + IAM Minting/Troubleshooting
  hybrid    GCE VM Hub + GKE Agent Cluster + Cloud Filestore (NFS) + Vertex AI
  ha        Multi-Hub / HA (Cloud Run + Cloud SQL + GKE + Filestore + Service Networking + Vertex AI)
  all       All APIs across every Scion deployment mode (default)

Options:
  --project <id>             Target GCP Project ID (required)
  --tier <tier>              Deployment tier (default: all)
  --ensure-vpc               Inspect <GCP_PROJECT_ID> and ensure VPC network '<GCP_PROJECT_ID>'
                             (not 'default'), regional subnet, IAP SSH firewall rule
                             (35.235.240.0/20 -> tcp:22), and Cloud Run Direct VPC Egress
                             proxy firewall rule (<SUBNET_CIDR> -> tcp:8080) exist
  --ensure-default-network   Alias for --ensure-vpc
  --region <region>          Region for subnet verification when --ensure-vpc is set (default: us-central1)
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
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --ensure-vpc|--ensure-default-network)
      ENSURE_VPC="true"
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
VPC_NAME="${PROJECT_ID}"
IAP_FW_RULE="${VPC_NAME}-allow-iap-ssh"
PROXY_FW_RULE="${VPC_NAME}-allow-proxy"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "[DRY-RUN] Would execute (in batches of <= ${BATCH_SIZE} due to GCP Service Usage 20-service batch limit):"
  for ((i = 0; i < TOTAL_APIS; i += BATCH_SIZE)); do
    BATCH=("${APIS[@]:i:BATCH_SIZE}")
    CMD=("gcloud" "services" "enable" "${BATCH[@]}" "--project=${PROJECT_ID}")
    printf '  %q' "${CMD[@]}"
    echo ""
  done
  if [[ "${ENSURE_VPC}" == "true" ]]; then
    echo "  gcloud compute networks describe ${VPC_NAME} --project=${PROJECT_ID} || gcloud compute networks create ${VPC_NAME} --project=${PROJECT_ID} --subnet-mode=auto"
    echo "  gcloud compute firewall-rules describe ${IAP_FW_RULE} --project=${PROJECT_ID} || gcloud compute firewall-rules create ${IAP_FW_RULE} --project=${PROJECT_ID} --network=${VPC_NAME} --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20"
    echo "  gcloud compute firewall-rules describe ${PROXY_FW_RULE} --project=${PROJECT_ID} || gcloud compute firewall-rules create ${PROXY_FW_RULE} --project=${PROJECT_ID} --network=${VPC_NAME} --direction=INGRESS --action=ALLOW --rules=tcp:8080 --source-ranges=<SUBNET_CIDR>"
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

if [[ "${ENSURE_VPC}" == "true" ]]; then
  echo ""
  echo "==> Inspecting VPC network '${VPC_NAME}' in project '${PROJECT_ID}'..."
  if gcloud compute networks describe "${VPC_NAME}" "--project=${PROJECT_ID}" --quiet &>/dev/null; then
    echo "    VPC network '${VPC_NAME}' already exists."
  else
    echo "    Creating VPC network '${VPC_NAME}'..."
    if ! gcloud compute networks create "${VPC_NAME}" "--project=${PROJECT_ID}" --subnet-mode=auto --quiet 2>/dev/null; then
      echo "    Auto-mode VPC blocked by org policy; creating custom-mode VPC '${VPC_NAME}' + subnet in '${REGION}'..."
      gcloud compute networks create "${VPC_NAME}" "--project=${PROJECT_ID}" --subnet-mode=custom --quiet
      gcloud compute networks subnets create "${VPC_NAME}" \
        "--project=${PROJECT_ID}" \
        "--network=${VPC_NAME}" \
        "--region=${REGION}" \
        --range="10.128.0.0/20" \
        --quiet
    fi
  fi

  # Ensure a regional subnet exists in REGION on VPC_NAME (for custom-mode networks)
  SUBNET_NAME="$(gcloud compute networks subnets list \
    "--project=${PROJECT_ID}" \
    "--regions=${REGION}" \
    "--filter=network ~ /networks/${VPC_NAME}$" \
    --format="value(name)" 2>/dev/null | head -1 || true)"
  if [[ -z "${SUBNET_NAME}" ]]; then
    SUBNET_NAME="${VPC_NAME}"
    echo "    Creating regional subnet '${SUBNET_NAME}' in '${REGION}' on network '${VPC_NAME}'..."
    gcloud compute networks subnets create "${SUBNET_NAME}" \
      "--project=${PROJECT_ID}" \
      "--network=${VPC_NAME}" \
      "--region=${REGION}" \
      --range="10.128.0.0/20" \
      --quiet
  else
    echo "    Found regional subnet '${SUBNET_NAME}' in '${REGION}' on network '${VPC_NAME}'."
  fi

  SUBNET_CIDR="$(gcloud compute networks subnets describe "${SUBNET_NAME}" \
    "--region=${REGION}" "--project=${PROJECT_ID}" \
    --format="value(ipCidrRange)" 2>/dev/null || echo "10.128.0.0/20")"
  [[ -z "${SUBNET_CIDR}" ]] && SUBNET_CIDR="10.128.0.0/20"
  echo "    Regional subnet '${SUBNET_NAME}' CIDR (${REGION}): ${SUBNET_CIDR}"

  echo "==> Ensuring IAP SSH firewall rule '${IAP_FW_RULE}' (35.235.240.0/20 -> tcp:22) on network '${VPC_NAME}'..."
  if EXISTING_IAP_NET="$(gcloud compute firewall-rules describe "${IAP_FW_RULE}" "--project=${PROJECT_ID}" --format="value(network)" 2>/dev/null)"; then
    if [[ -n "${EXISTING_IAP_NET}" && "${EXISTING_IAP_NET}" != *"/${VPC_NAME}" && "${EXISTING_IAP_NET}" != "${VPC_NAME}" ]]; then
      echo "    Firewall rule '${IAP_FW_RULE}' is attached to '${EXISTING_IAP_NET##*/}'; recreating on '${VPC_NAME}'..."
      gcloud compute firewall-rules delete "${IAP_FW_RULE}" "--project=${PROJECT_ID}" --quiet
    fi
  fi
  if gcloud compute firewall-rules describe "${IAP_FW_RULE}" "--project=${PROJECT_ID}" --quiet &>/dev/null; then
    gcloud compute firewall-rules update "${IAP_FW_RULE}" \
      "--project=${PROJECT_ID}" \
      --rules=tcp:22 \
      --source-ranges=35.235.240.0/20 \
      --quiet
    echo "    Verified/updated firewall rule '${IAP_FW_RULE}' on network '${VPC_NAME}'."
  else
    gcloud compute firewall-rules create "${IAP_FW_RULE}" \
      "--project=${PROJECT_ID}" \
      "--network=${VPC_NAME}" \
      --direction=INGRESS \
      --action=ALLOW \
      --rules=tcp:22 \
      --source-ranges=35.235.240.0/20 \
      --description="Allow IAP TCP forwarding for SSH on network ${VPC_NAME}" \
      --quiet
    echo "    Created firewall rule '${IAP_FW_RULE}' on network '${VPC_NAME}'."
  fi

  echo "==> Ensuring Cloud Run Direct VPC Egress proxy firewall rule '${PROXY_FW_RULE}' (${SUBNET_CIDR} -> tcp:8080) on network '${VPC_NAME}'..."
  if EXISTING_PROXY_NET="$(gcloud compute firewall-rules describe "${PROXY_FW_RULE}" "--project=${PROJECT_ID}" --format="value(network)" 2>/dev/null)"; then
    if [[ -n "${EXISTING_PROXY_NET}" && "${EXISTING_PROXY_NET}" != *"/${VPC_NAME}" && "${EXISTING_PROXY_NET}" != "${VPC_NAME}" ]]; then
      echo "    Firewall rule '${PROXY_FW_RULE}' is attached to '${EXISTING_PROXY_NET##*/}'; recreating on '${VPC_NAME}'..."
      gcloud compute firewall-rules delete "${PROXY_FW_RULE}" "--project=${PROJECT_ID}" --quiet
    fi
  fi
  if gcloud compute firewall-rules describe "${PROXY_FW_RULE}" "--project=${PROJECT_ID}" --quiet &>/dev/null; then
    gcloud compute firewall-rules update "${PROXY_FW_RULE}" \
      "--project=${PROJECT_ID}" \
      --rules=tcp:8080 \
      --source-ranges="${SUBNET_CIDR}" \
      --quiet
    echo "    Verified/updated firewall rule '${PROXY_FW_RULE}' on network '${VPC_NAME}'."
  else
    gcloud compute firewall-rules create "${PROXY_FW_RULE}" \
      "--project=${PROJECT_ID}" \
      "--network=${VPC_NAME}" \
      --direction=INGRESS \
      --action=ALLOW \
      --rules=tcp:8080 \
      --source-ranges="${SUBNET_CIDR}" \
      --description="Allow Cloud Run Direct VPC Egress IAP proxy to reach Scion Hub VM on tcp:8080" \
      --quiet
    echo "    Created firewall rule '${PROXY_FW_RULE}' on network '${VPC_NAME}'."
  fi
fi

echo "==> Done. Reminder: Third-party Model Garden models (e.g. Anthropic Claude on Vertex AI)"
echo "    must also have their EULA/terms accepted manually in the GCP Console -> Vertex AI -> Model Garden."

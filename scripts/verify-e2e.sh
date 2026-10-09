#!/usr/bin/env bash
# End-to-End Verification Script for Scion GCP IAM, Service Account Minting,
# Policy Troubleshooter actAs Enforcement, and Vertex AI Inference.
#
# This script verifies that a non-Owner operator principal starting ONLY with
# Option 1A (roles/editor + roles/resourcemanager.projectIamAdmin) can:
#   1. Self-grant the full-operator IAM bundle (grant-deployer-iam.sh)
#   2. Enable all 21 required GCP APIs and ensure the '<PROJECT_ID>' VPC network
#      + IAP SSH firewall rule (enable-apis.sh --ensure-vpc)
#   3. Deploy a Single-Node GCE VM + Cloud Run IAP Proxy (scion scripts/single-node-vm/deploy.sh)
#   4. Wire Hub SA Minting, Policy Troubleshooter v3, and BYO Agent SA IAM (grant-runtime-sa-iam.sh)
#   5. Execute runtime checks from inside the Hub VM:
#      - Hub SA Minting (create SA + bind tokenCreator & self-actAs)
#      - BYOSA short-lived token generation (iamcredentials.googleapis.com)
#      - Policy Troubleshooter v3 iam.serviceAccounts.actAs verification
#      - Live Vertex AI Gemini inference (aiplatform.googleapis.com)
#
# Automatic On-Failure Sanitization:
#   If any step fails, the EXIT trap automatically rolls back / deletes any
#   resources created during the run unless --no-sanitize-on-failure is set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ID=""
ADMIN_EMAIL=""
SCION_REPO_DIR=""
REGION="us-central1"
HUB_NAME="e2e"
OPERATOR_SA_NAME="operator-e2e"
BYO_SA_NAME="byo-agent"
SKIP_VM_DEPLOY="false"
SANITIZE_ON_FAILURE="true"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-e2e.sh \
    --project <GCP_PROJECT_ID> \
    --admin-email <admin@example.com> \
    --scion-repo </path/to/scion> \
    [--region <us-central1>] \
    [--hub-name <e2e>] \
    [--skip-vm-deploy] \
    [--no-sanitize-on-failure] \
    [--dry-run]

Prerequisites:
  - The active gcloud account must hold roles/owner or roles/resourcemanager.projectIamAdmin
    on <GCP_PROJECT_ID> (with billing linked) to perform the Phase 1 bootstrap.
  - All Phase 2 steps automatically execute under Service Account impersonation
    (operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com) with NO roles/owner privileges.

Options:
  --project <id>             Target GCP Project ID (required)
  --admin-email <email>      Admin user email for IAP & actAs verification, e.g. admin@example.com (required)
  --scion-repo <path>        Path to a local checkout of the Scion repository (required unless --skip-vm-deploy)
  --region <region>          GCP region for resources (default: us-central1)
  --hub-name <name>          Hub name suffix, <= 20 chars (default: e2e)
  --skip-vm-deploy           Skip running Scion's deploy.sh if scion-hub-<hub-name> is already deployed
  --no-sanitize-on-failure   Keep created resources if a step fails (default: sanitize/delete on failure)
  --dry-run                  Print the verification stages without executing them
  -h, --help                 Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --admin-email)
      ADMIN_EMAIL="${2:-}"
      shift 2
      ;;
    --scion-repo)
      SCION_REPO_DIR="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --hub-name)
      HUB_NAME="${2:-}"
      shift 2
      ;;
    --skip-vm-deploy)
      SKIP_VM_DEPLOY="true"
      shift
      ;;
    --no-sanitize-on-failure)
      SANITIZE_ON_FAILURE="false"
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

if [[ -z "${PROJECT_ID}" || -z "${ADMIN_EMAIL}" ]]; then
  echo "Error: --project and --admin-email are required." >&2
  usage >&2
  exit 1
fi

if [[ "${SKIP_VM_DEPLOY}" != "true" ]]; then
  if [[ -z "${SCION_REPO_DIR}" || ! -x "${SCION_REPO_DIR}/scripts/single-node-vm/deploy.sh" ]]; then
    echo "Error: --scion-repo must point to a Scion checkout containing scripts/single-node-vm/deploy.sh." >&2
    exit 1
  fi
fi

OPERATOR_SA="${OPERATOR_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
HUB_SA="scion-hub-${HUB_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BYO_SA="${BYO_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
MINT_SA="scion-minted-test@${PROJECT_ID}.iam.gserviceaccount.com"
INSTANCE_NAME="scion-hub-${HUB_NAME}"

if [[ "${DRY_RUN}" == "true" ]]; then
  cat <<EOF
[DRY-RUN] End-to-End Verification Plan:
  Project ID   : ${PROJECT_ID}
  VPC Network  : ${PROJECT_ID} (with IAP SSH firewall rule ${PROJECT_ID}-allow-iap-ssh)
  Admin Email  : ${ADMIN_EMAIL}
  Operator SA  : ${OPERATOR_SA} (Starts ONLY with roles/editor + roles/resourcemanager.projectIamAdmin)
  Hub SA       : ${HUB_SA}
  BYO Agent SA : ${BYO_SA}
  VM Instance  : ${INSTANCE_NAME} (${REGION})
  On Failure   : Sanitize/rollback resources = ${SANITIZE_ON_FAILURE}
EOF
  exit 0
fi

TMP_WORK_DIR="$(mktemp -d)"
chmod 700 "${TMP_WORK_DIR}"
DEPLOY_CFG="${TMP_WORK_DIR}/deploy-config.json"
DEPLOY_STARTED="false"

sanitize_on_exit() {
  local exit_code=$?
  set +e
  if [[ "${exit_code}" -ne 0 && "${SANITIZE_ON_FAILURE}" == "true" ]]; then
    echo "" >&2
    echo "===================================================================" >&2
    echo "ERROR (exit ${exit_code}): Sanitizing created resources in project '${PROJECT_ID}'..." >&2
    echo "===================================================================" >&2
    if [[ "${DEPLOY_STARTED}" == "true" && -f "${DEPLOY_CFG}" && -x "${SCION_REPO_DIR}/scripts/single-node-vm/deploy.sh" ]]; then
      "${SCION_REPO_DIR}/scripts/single-node-vm/deploy.sh" --delete --config "${DEPLOY_CFG}" </dev/null >&2 || true
    fi
    for sa in "${MINT_SA}" "${BYO_SA}"; do
      if gcloud iam service-accounts describe "${sa}" --project="${PROJECT_ID}" &>/dev/null; then
        gcloud iam service-accounts delete "${sa}" --project="${PROJECT_ID}" --quiet >&2 || true
      fi
    done
    echo "==> Sanitization on failure complete." >&2
  fi
  rm -rf "${TMP_WORK_DIR}"
  exit "${exit_code}"
}
trap sanitize_on_exit EXIT

echo "==================================================================="
echo "Phase 1: Cloud Admin Bootstrap (Option 1A — Minimal 2-Role Grant)"
echo "==================================================================="

echo "--> [1.1] Enabling bootstrap IAM & Resource Manager APIs..."
gcloud services enable \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}" \
  --quiet

echo "--> [1.2] Creating non-Owner operator identity (${OPERATOR_SA})..."
if ! gcloud iam service-accounts describe "${OPERATOR_SA}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${OPERATOR_SA_NAME}" \
    --display-name="Simulated Non-Owner Operator (Option 1A)" \
    --project="${PROJECT_ID}" \
    --quiet
fi

echo "--> [1.3] Allowing ${ADMIN_EMAIL} to impersonate ${OPERATOR_SA}..."
gcloud iam service-accounts add-iam-policy-binding "${OPERATOR_SA}" \
  --project="${PROJECT_ID}" \
  --member="user:${ADMIN_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --quiet >/dev/null
gcloud iam service-accounts add-iam-policy-binding "${OPERATOR_SA}" \
  --project="${PROJECT_ID}" \
  --member="user:${ADMIN_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --quiet >/dev/null

echo "--> [1.4] Granting ONLY Option 1A (roles/editor + roles/resourcemanager.projectIamAdmin) to ${OPERATOR_SA}..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${OPERATOR_SA}" \
  --role="roles/editor" \
  --condition=None \
  --quiet >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${OPERATOR_SA}" \
  --role="roles/resourcemanager.projectIamAdmin" \
  --condition=None \
  --quiet >/dev/null

echo "--> [1.5] Waiting for IAM tokenCreator propagation on ${OPERATOR_SA}..."
for i in $(seq 1 18); do
  if gcloud auth print-access-token --impersonate-service-account="${OPERATOR_SA}" >/dev/null 2>&1; then
    echo "    Impersonation active (attempt ${i})."
    break
  fi
  sleep 5
done

echo ""
echo "==================================================================="
echo "Phase 2: Operator Self-Service Execution (Impersonating ${OPERATOR_SA})"
echo "==================================================================="
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${OPERATOR_SA}"

echo "--> [2.1] Self-granting full-operator roles via grant-deployer-iam.sh..."
"${SCRIPT_DIR}/grant-deployer-iam.sh" \
  --project "${PROJECT_ID}" \
  --member "serviceAccount:${OPERATOR_SA}" \
  --tier full-operator

echo "--> [2.2] Enabling all 21 GCP APIs and ensuring VPC '${PROJECT_ID}' + IAP SSH firewall rule..."
"${SCRIPT_DIR}/enable-apis.sh" \
  --project "${PROJECT_ID}" \
  --tier all \
  --region "${REGION}" \
  --ensure-vpc

if [[ "${SKIP_VM_DEPLOY}" != "true" ]]; then
  echo "--> [2.4] Deploying Single-Node VM + Cloud Run IAP Proxy as ${OPERATOR_SA}..."
  cat > "${DEPLOY_CFG}" <<EOF
{
  "hub_name": "${HUB_NAME}",
  "project_id": "${PROJECT_ID}",
  "region": "${REGION}",
  "machine_size": "small",
  "disk_size_gb": 50,
  "chat_plugins": [],
  "container_images": {
    "source": "registry",
    "registry": "${REGION}-docker.pkg.dev/${PROJECT_ID}/scion",
    "force_rebuild": false
  },
  "admin_email": "${ADMIN_EMAIL}",
  "update_policy": "disabled",
  "release_channel": "nightly"
}
EOF
  DEPLOY_STARTED="true"
  IAP_ENFORCEMENT_WAIT_SECS=10 "${SCION_REPO_DIR}/scripts/single-node-vm/deploy.sh" \
    --config "${DEPLOY_CFG}"
fi

echo "--> [2.5a] Creating BYO Agent SA (${BYO_SA}) and running grant-runtime-sa-iam.sh..."
if ! gcloud iam service-accounts describe "${BYO_SA}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${BYO_SA_NAME}" \
    --display-name="BYO Agent SA E2E" \
    --project="${PROJECT_ID}" \
    --quiet
fi

"${SCRIPT_DIR}/grant-runtime-sa-iam.sh" \
  --project "${PROJECT_ID}" \
  --hub-sa "${HUB_SA}" \
  --enable-minting \
  --enable-enforce-check \
  --agent-sa "${BYO_SA}" \
  --grant-vertex-ai \
  --allow-user-act-as "${ADMIN_EMAIL}"

ZONE="$(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="name=${INSTANCE_NAME}" \
  --format="value(zone)" | head -1)"

echo "--> [2.5b] Running runtime verification inside ${INSTANCE_NAME} (zone: ${ZONE})..."
gcloud compute ssh "${INSTANCE_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}" \
  --tunnel-through-iap \
  --quiet \
  --command="
    set -euo pipefail
    PROJECT_ID='${PROJECT_ID}'
    REGION='${REGION}'
    HUB_SA='${HUB_SA}'
    BYO_SA='${BYO_SA}'
    ADMIN_EMAIL='${ADMIN_EMAIL}'
    MINT_SA_NAME='scion-minted-test'
    MINT_SA=\"\${MINT_SA_NAME}@\${PROJECT_ID}.iam.gserviceaccount.com\"

    echo '--- [Test 1] Active VM Identity ---'
    gcloud auth list

    echo '--- [Test 2] Hub SA Minting (create SA + bind tokenCreator & self-actAs) ---'
    if ! gcloud iam service-accounts describe \"\${MINT_SA}\" --project=\"\${PROJECT_ID}\" &>/dev/null; then
      gcloud iam service-accounts create \"\${MINT_SA_NAME}\" \
        --display-name='Hub Minted Agent SA Test' \
        --project=\"\${PROJECT_ID}\" \
        --quiet
    fi
    gcloud iam service-accounts add-iam-policy-binding \"\${MINT_SA}\" \
      --project=\"\${PROJECT_ID}\" \
      --member=\"serviceAccount:\${HUB_SA}\" \
      --role='roles/iam.serviceAccountTokenCreator' \
      --quiet >/dev/null
    gcloud iam service-accounts add-iam-policy-binding \"\${MINT_SA}\" \
      --project=\"\${PROJECT_ID}\" \
      --member=\"serviceAccount:\${MINT_SA}\" \
      --role='roles/iam.serviceAccountUser' \
      --quiet >/dev/null
    echo 'PASS: Hub SA successfully minted SA and bound tokenCreator + self-actAs policies.'

    echo '--- [Test 3] BYOSA Short-Lived Token Minting (iamcredentials generateAccessToken) ---'
    BYO_TOKEN=''
    for i in \$(seq 1 12); do
      if BYO_TOKEN=\$(gcloud auth print-access-token --impersonate-service-account=\"\${BYO_SA}\" 2>/dev/null); then
        echo \"PASS: Hub SA minted short-lived access token for BYOSA (attempt \${i}).\"
        break
      fi
      sleep 5
    done
    if [[ -z \"\${BYO_TOKEN}\" ]]; then
      echo 'FAIL: Could not mint token for BYOSA.'
      exit 1
    fi

    echo '--- [Test 4] Policy Troubleshooter v3 actAs Enforcement Check ---'
    HUB_TOKEN=\$(gcloud auth print-access-token)
    PT_RESPONSE=\$(curl -fsSL -X POST 'https://policytroubleshooter.googleapis.com/v3/iam:troubleshoot' \
      -H \"Authorization: Bearer \${HUB_TOKEN}\" \
      -H 'Content-Type: application/json' \
      -d \"{
        \\\"accessTuple\\\": {
          \\\"principal\\\": \\\"\${ADMIN_EMAIL}\\\",
          \\\"fullResourceName\\\": \\\"//iam.googleapis.com/projects/\${PROJECT_ID}/serviceAccounts/\${BYO_SA}\\\",
          \\\"permission\\\": \\\"iam.serviceAccounts.actAs\\\"
        }
      }\")
    OVERALL=\$(echo \"\${PT_RESPONSE}\" | jq -r '.overallAccessState')
    ALLOW_STATE=\$(echo \"\${PT_RESPONSE}\" | jq -r '.allowPolicyExplanation.allowAccessState')
    DENY_STATE=\$(echo \"\${PT_RESPONSE}\" | jq -r '.denyPolicyExplanation.denyAccessState')
    echo \"Policy Troubleshooter v3 states: overall=\${OVERALL}, allow=\${ALLOW_STATE}, deny=\${DENY_STATE}\"
    if [[ \"\${OVERALL}\" == 'OVERALL_ACCESS_STATE_CAN_ACCESS' ]] || [[ \"\${ALLOW_STATE}\" == 'ALLOW_ACCESS_STATE_GRANTED' && \"\${DENY_STATE}\" != 'DENY_ACCESS_STATE_DENIED' ]]; then
      echo 'PASS: Policy Troubleshooter v3 verified actAs permission.'
    else
      echo \"FAIL: Unexpected Policy Troubleshooter state: \${PT_RESPONSE}\"
      exit 1
    fi

    echo '--- [Test 5] Vertex AI Gemini Inference (via BYO Agent SA token) ---'
    VERTEX_RESP=\$(curl -fsSL -X POST \"https://\${REGION}-aiplatform.googleapis.com/v1/projects/\${PROJECT_ID}/locations/\${REGION}/publishers/google/models/gemini-2.5-flash:generateContent\" \
      -H \"Authorization: Bearer \${BYO_TOKEN}\" \
      -H 'Content-Type: application/json' \
      -d '{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Reply with the single word: VERTEX_OK\"}]}]}')
    VERTEX_TEXT=\$(echo \"\${VERTEX_RESP}\" | jq -r '.candidates[0].content.parts[0].text' | tr -d '\n\r ')
    echo \"Vertex AI response: \${VERTEX_TEXT}\"
    if [[ \"\${VERTEX_TEXT}\" == *'VERTEX_OK'* ]]; then
      echo 'PASS: Vertex AI inference succeeded via BYO Agent SA.'
    else
      echo \"FAIL: Unexpected Vertex AI response: \${VERTEX_RESP}\"
      exit 1
    fi
  "

echo ""
echo "==> ALL END-TO-END IAM & RUNTIME VERIFICATION CHECKS PASSED."

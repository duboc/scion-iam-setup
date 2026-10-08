#!/usr/bin/env bash
# Configure GCP Service Account IAM bindings for Scion Hub runtime features:
#   1. Hub SA Minting (roles/iam.serviceAccountAdmin for Hub SA)
#   2. Policy Troubleshooter actAs enforcement (roles/iam.securityReviewer for Hub SA)
#   3. Target Agent SA impersonation (roles/iam.serviceAccountTokenCreator on Agent SA for Hub SA)
#   4. Vertex AI access for Agent SA (roles/aiplatform.user on Project for Agent SA)
#   5. Human User actAs delegation on Agent SA (roles/iam.serviceAccountUser on Agent SA)
set -euo pipefail

PROJECT_ID=""
HUB_SA=""
AGENT_SA=""
USER_EMAIL=""
ENABLE_MINTING="false"
ENABLE_ENFORCE_CHECK="false"
GRANT_VERTEX_AI="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/grant-runtime-sa-iam.sh \
    --project <GCP_PROJECT_ID> \
    --hub-sa <hub-sa@project.iam.gserviceaccount.com> \
    [--enable-minting] \
    [--enable-enforce-check] \
    [--agent-sa <agent-sa@project.iam.gserviceaccount.com>] \
    [--grant-vertex-ai] \
    [--allow-user-act-as <user@example.com>] \
    [--dry-run]

Options:
  --project <id>               Target GCP Project ID (required)
  --hub-sa <email>             Scion Hub runtime Service Account email (required)
  --enable-minting             Grant Hub SA roles/iam.serviceAccountAdmin on the project so
                               `scion hub gcp-accounts mint` can create and configure SAs
  --enable-enforce-check       Grant Hub SA roles/iam.securityReviewer on the project so
                               Policy Troubleshooter v3 (`gcp_iam_check_mode: enforce`) works
  --agent-sa <email>           Target Agent Service Account email (BYOSA or Hub-minted) to
                               bind roles/iam.serviceAccountTokenCreator for the Hub SA
  --grant-vertex-ai            Grant --agent-sa roles/aiplatform.user on --project for Vertex AI
  --allow-user-act-as <email>  Grant user:<email> roles/iam.serviceAccountUser on --agent-sa
                               so the user passes `iam.serviceAccounts.actAs` enforcement
  --dry-run                    Print gcloud commands without executing them
  -h, --help                   Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --hub-sa)
      HUB_SA="${2:-}"
      shift 2
      ;;
    --enable-minting)
      ENABLE_MINTING="true"
      shift
      ;;
    --enable-enforce-check)
      ENABLE_ENFORCE_CHECK="true"
      shift
      ;;
    --agent-sa)
      AGENT_SA="${2:-}"
      shift 2
      ;;
    --grant-vertex-ai)
      GRANT_VERTEX_AI="true"
      shift
      ;;
    --allow-user-act-as)
      USER_EMAIL="${2:-}"
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

if [[ -z "${PROJECT_ID}" || -z "${HUB_SA}" ]]; then
  echo "Error: Both --project and --hub-sa are required." >&2
  usage >&2
  exit 1
fi

run_cmd() {
  local desc="$1"
  shift
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "--> ${desc}"
    printf '    [DRY-RUN]'
    printf ' %q' "$@"
    echo ""
  else
    echo "--> ${desc}"
    "$@" >/dev/null
  fi
}

if [[ "${ENABLE_MINTING}" == "true" ]]; then
  run_cmd "Granting roles/iam.serviceAccountAdmin to Hub SA (${HUB_SA}) for SA Minting" \
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      "--member=serviceAccount:${HUB_SA}" \
      "--role=roles/iam.serviceAccountAdmin" \
      "--condition=None" \
      "--quiet"
fi

if [[ "${ENABLE_ENFORCE_CHECK}" == "true" ]]; then
  run_cmd "Granting roles/iam.securityReviewer to Hub SA (${HUB_SA}) for Policy Troubleshooter actAs checks" \
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      "--member=serviceAccount:${HUB_SA}" \
      "--role=roles/iam.securityReviewer" \
      "--condition=None" \
      "--quiet"
fi

if [[ -n "${AGENT_SA}" ]]; then
  run_cmd "Granting Hub SA (${HUB_SA}) roles/iam.serviceAccountTokenCreator on Agent SA (${AGENT_SA})" \
    gcloud iam service-accounts add-iam-policy-binding "${AGENT_SA}" \
      "--project=${PROJECT_ID}" \
      "--member=serviceAccount:${HUB_SA}" \
      "--role=roles/iam.serviceAccountTokenCreator" \
      "--quiet"

  if [[ "${GRANT_VERTEX_AI}" == "true" ]]; then
    run_cmd "Granting Agent SA (${AGENT_SA}) roles/aiplatform.user on project ${PROJECT_ID}" \
      gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        "--member=serviceAccount:${AGENT_SA}" \
        "--role=roles/aiplatform.user" \
        "--condition=None" \
        "--quiet"
  fi

  if [[ -n "${USER_EMAIL}" ]]; then
    run_cmd "Granting user:${USER_EMAIL} roles/iam.serviceAccountUser (actAs) on Agent SA (${AGENT_SA})" \
      gcloud iam service-accounts add-iam-policy-binding "${AGENT_SA}" \
        "--project=${PROJECT_ID}" \
        "--member=user:${USER_EMAIL}" \
        "--role=roles/iam.serviceAccountUser" \
        "--quiet"
  fi
fi

echo "==> Runtime Service Account IAM setup complete."

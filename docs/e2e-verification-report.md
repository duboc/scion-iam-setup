# End-to-End IAM & Runtime Verification Report

This document records the live end-to-end validation of the [Phase 1 (Admin Request)](../README.md#phase-1--what-the-operator-must-request-to-get-started) and [Phase 2 (Operator Self-Service)](../README.md#phase-2--what-the-operator-runs-after-receiving-access) workflows on a fresh Google Cloud project inside a hardened GCP organization.

All sensitive identifiers have been sanitized to standard placeholders (`<GCP_PROJECT_ID>`, `<PROJECT_NUMBER>`, `<ORG_ID>`, `admin@example.com`). You can reproduce the entire verification suite on any test project using [`scripts/verify-e2e.sh`](../scripts/verify-e2e.sh).

---

## 1. Test Methodology (Zero `roles/owner` Privileges in Phase 2)

Because creating a new GCP project automatically grants `roles/owner` to the creator—which would mask missing permissions if Phase 2 were run directly as the project creator—the verification enforces strict privilege separation:

1. **Phase 1 (Cloud Admin Bootstrap):**
   - Created a brand-new GCP project `<GCP_PROJECT_ID>` and linked billing.
   - Created a dedicated non-Owner operator principal `operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com`.
   - Granted `operator-e2e` **only Option 1A** (`roles/editor` + `roles/resourcemanager.projectIamAdmin`).
2. **Phase 2 (Operator Self-Service under Impersonation):**
   - Exported `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com"`.
   - Executed every deployment, IAM binding, API enablement, and SSH command strictly as `operator-e2e`.
3. **Runtime Verification (Inside the Deployed Scion Hub VM):**
   - Executed Service Account minting, short-lived token generation, Policy Troubleshooter v3 `actAs` checks, and live Vertex AI Gemini inference from inside `scion-hub-e2e` running as the Hub Runtime Service Account (`scion-hub-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com`).

---

## 2. Verification Matrix & Results

| Step | Executing Principal | Command / Action | Expected Outcome | Result |
| :--- | :--- | :--- | :--- | :---: |
| **1.1** | Cloud Admin | Create `<GCP_PROJECT_ID>`, link billing, enable bootstrap IAM APIs (`serviceusage`, `cloudresourcemanager`, `iam`, `iamcredentials`) | Project active; `operator-e2e` SA created | **PASS** |
| **1.2** | Cloud Admin | Grant **only Option 1A** (`roles/editor` + `roles/resourcemanager.projectIamAdmin`) to `operator-e2e` | `get-iam-policy` shows only `roles/editor` and `roles/resourcemanager.projectIamAdmin` on `operator-e2e` | **PASS** |
| **2.1** | `operator-e2e` *(Impersonated)* | `./scripts/grant-deployer-iam.sh --project <GCP_PROJECT_ID> --member serviceAccount:operator-e2e@... --tier full-operator` | Operator self-grants all 15 `full-operator` roles using `projectIamAdmin` without `roles/owner` | **PASS** |
| **2.2** | `operator-e2e` *(Impersonated)* | `./scripts/enable-apis.sh --project <GCP_PROJECT_ID> --tier all --ensure-default-network` | All 21 APIs enabled in batches of `<= 15`; auto-mode `default` VPC network created | **PASS** |
| **2.4** | `operator-e2e` *(Impersonated)* | Run Scion `scripts/single-node-vm/deploy.sh` | Provisions `scion-hub-e2e` VM, Cloud Router/NAT, firewall rules, `scion-hub.service` (`/healthz` healthy), Artifact Registry repo, and Cloud Run IAP proxy (`--no-allow-unauthenticated --iap`) | **PASS** |
| **2.5a** | `operator-e2e` *(Impersonated)* | `./scripts/grant-runtime-sa-iam.sh --project <GCP_PROJECT_ID> --hub-sa scion-hub-e2e@... --enable-minting --enable-enforce-check --agent-sa byo-agent@... --grant-vertex-ai --allow-user-act-as admin@example.com` | Binds `serviceAccountAdmin` & `securityReviewer` to Hub SA; binds `serviceAccountTokenCreator` (Hub SA), `aiplatform.user`, and `serviceAccountUser` (`admin@example.com`) on `byo-agent` | **PASS** |
| **2.5b** | `scion-hub-e2e` *(Inside Hub VM)* | **Hub SA Minting Test:** Create `scion-minted-test@...` and bind `roles/iam.serviceAccountTokenCreator` (Hub SA) + `roles/iam.serviceAccountUser` (self-`actAs`) | Minted SA created and SA-level IAM policies bound by Hub SA | **PASS** |
| **2.5c** | `scion-hub-e2e` *(Inside Hub VM)* | **BYOSA Token Impersonation Test:** `gcloud auth print-access-token --impersonate-service-account=byo-agent@...` | Hub SA mints short-lived OAuth2 access token for `byo-agent@...` | **PASS** |
| **2.5d** | `scion-hub-e2e` *(Inside Hub VM)* | **Policy Troubleshooter v3 `actAs` Check:** `POST https://policytroubleshooter.googleapis.com/v3/iam:troubleshoot` for `admin@example.com` on `byo-agent@...` | Returns `allowAccessState: ALLOW_ACCESS_STATE_GRANTED` (accepted by Scion's `PolicyTroubleshooterChecker`) | **PASS** |
| **2.5e** | `byo-agent` *(Impersonated from VM)* | **Vertex AI Inference Test:** `POST https://us-central1-aiplatform.googleapis.com/v1/.../models/gemini-2.5-flash:generateContent` | Returns HTTP 200 with model response `VERTEX_OK` | **PASS** |

---

## 3. Sanitized Verification Transcript

### Phase 1 & Phase 2.1–2.2 (Option 1A Self-Bootstrap & Batched API Enablement)

```text
==> Verifying operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com initial roles on <GCP_PROJECT_ID>:
ROLE
roles/editor
roles/resourcemanager.projectIamAdmin

==> [Phase 2.1] Running grant-deployer-iam.sh AS operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com (Option 1A self-bootstrap)...
==> Roles to Grant (15):
    - roles/resourcemanager.projectIamAdmin
    - roles/iam.serviceAccountAdmin
    - roles/iam.serviceAccountUser
    - roles/iam.securityReviewer
    - roles/run.admin
    - roles/iap.admin
    - roles/iap.httpsResourceAccessor
    - roles/iap.tunnelResourceAccessor
    - roles/secretmanager.admin
    - roles/compute.networkAdmin
    - roles/servicenetworking.networksAdmin
    - roles/container.admin
    - roles/storage.admin
    - roles/aiplatform.admin
    - roles/serviceusage.serviceUsageAdmin
==> Completed IAM role grants for serviceAccount:operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com on project <GCP_PROJECT_ID>.

==> [Phase 2.2] Running enable-apis.sh AS operator-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com...
==> Enabling APIs (in batches of <= 15)...
--> Enabling batch (1..15 of 21)...
--> Enabling batch (16..21 of 21)...
==> Checking for 'default' VPC network...
    'default' VPC network missing (org policy skipDefaultNetworkCreation). Creating auto-mode 'default' network...
Created [https://www.googleapis.com/compute/v1/projects/<GCP_PROJECT_ID>/global/networks/default].
```

### Phase 2.4 (Single-Node VM + Cloud Run IAP Proxy Deployment as `operator-e2e`)

```text
--- Phase 2: GCP Resources ---
  Default VPC network found.
  Created service account: scion-hub-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com
  Roles bound: logging.logWriter, monitoring.metricWriter, cloudtrace.agent, artifactregistry.writer, aiplatform.user
  Created proxy service account: scion-hub-e2e-proxy@<GCP_PROJECT_ID>.iam.gserviceaccount.com
  IAP tunnel access granted to: admin@example.com
  Created Cloud Router: scion-hub-e2e-router
  Created Cloud NAT: scion-hub-e2e-nat
  Created firewall rule: scion-hub-e2e-allow-iap-ssh (target tags: scion-hub-e2e)
  Created firewall rule: scion-hub-e2e-allow-proxy (source: 10.128.0.0/20, target tags: scion-hub-e2e)
  Created VM: scion-hub-e2e (zone: us-central1-c)
  SSH connection established.
  Cloud-init completed.

--- Phase 3: VM Setup ---
  Installed scion binary (nightly)
  scion-hub.service started.
  Health check passed.
  Hub env vars seeded (GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION).

--- Phase 4: IAP Proxy ---
  Artifact Registry repo ready: cloud-run-source-deploy
  Proxy image built on VM.
  Proxy image pushed: us-central1-docker.pkg.dev/<GCP_PROJECT_ID>/cloud-run-source-deploy/scion-hub-e2e-iap-proxy:latest
  Cloud Run IAP proxy deployed with IAP enabled (no allUsers invoker binding was ever created).
  Proxy URL: https://scion-hub-e2e-iap-proxy-xxxxxxxxxx-uc.a.run.app
  IAP service agent can invoke: scion-hub-e2e-iap-proxy
  No allUsers invoker binding present.
  IAP access granted to: admin@example.com (service-level binding)

--- Phase 5: Finalize ---
  settings.yaml updated (auth mode: proxy, provider: iap).
  scion-hub.service restarted.
  {"status":"healthy","hub":{"status":"healthy","hub_name":"scion-hub-e2e","checks":{"colocated_broker":"healthy","database":"healthy"}},"broker":{"status":"healthy","checks":{"docker":"available"}}}
  Health check passed.
=== Deployment Complete ===
```

### Phase 2.5 (Runtime SA Minting, BYOSA Impersonation, Policy Troubleshooter v3 & Vertex AI)

```text
--- [Test 1] Active VM Identity ---
ACTIVE  ACCOUNT
*       scion-hub-e2e@<GCP_PROJECT_ID>.iam.gserviceaccount.com

--- [Test 2] Hub SA Minting (create SA + bind tokenCreator to Hub SA + bind self-actAs) ---
Created service account [scion-minted-test].
Service account email: scion-minted-test@<GCP_PROJECT_ID>.iam.gserviceaccount.com
Updated IAM policy for serviceAccount [scion-minted-test@<GCP_PROJECT_ID>.iam.gserviceaccount.com].
Updated IAM policy for serviceAccount [scion-minted-test@<GCP_PROJECT_ID>.iam.gserviceaccount.com].
PASS: Hub SA successfully minted SA and bound tokenCreator + self-actAs policies.

--- [Test 3] BYOSA Short-Lived Token Minting (iamcredentials generateAccessToken) ---
PASS: Hub SA successfully minted short-lived access token for BYOSA (attempt 1).

--- [Test 4] Policy Troubleshooter v3 actAs Enforcement Check (Scion PolicyTroubleshooterChecker logic) ---
Policy Troubleshooter v3 states: overall=UNKNOWN_INFO, allow=ALLOW_ACCESS_STATE_GRANTED, deny=DENY_ACCESS_STATE_UNKNOWN_INFO
PASS: Policy Troubleshooter v3 verified actAs permission (matches Scion PolicyTroubleshooterChecker).

--- [Test 5] Vertex AI Gemini Inference (using BYO Agent SA token) ---
Vertex AI response (BYO Agent SA): VERTEX_OK
PASS: Vertex AI inference succeeded via BYO Agent SA.
```

---

## 4. Key Engineering Lessons Discovered & Codified

1. **GCP Service Usage 20-Service Batch Limit (`SU_MAX_BATCH_SIZE_EXCEEDED`):**
   Passing all 21 required APIs to a single `gcloud services enable` invocation fails with `INVALID_ARGUMENT: Number of services must not exceed the maximum batch size (20)`. [`scripts/enable-apis.sh`](../scripts/enable-apis.sh) now enables services in batches of `<= 15`.
2. **Bootstrap APIs on Fresh Projects:**
   Before creating or impersonating Service Accounts on a newly created project, `serviceusage.googleapis.com`, `cloudresourcemanager.googleapis.com`, `iam.googleapis.com`, and `iamcredentials.googleapis.com` must be enabled first.
3. **Hardened Organization `default` VPC Network (`constraints/compute.skipDefaultNetworkCreation`):**
   Organizations enforcing `skipDefaultNetworkCreation` do not create a `default` VPC network when `compute.googleapis.com` is enabled. Added `--ensure-default-network` to [`scripts/enable-apis.sh`](../scripts/enable-apis.sh).
4. **IAM Propagation Delay on New Service Account Bindings (~20–45s):**
   Newly bound `roles/iam.serviceAccountTokenCreator` policies on freshly created Service Accounts take 20–45 seconds to propagate before `iamcredentials.googleapis.com` (`generateAccessToken`) succeeds.
5. **Policy Troubleshooter v3 Project-Level vs. Org-Level `roles/iam.securityReviewer`:**
   When `roles/iam.securityReviewer` is granted only at the Project level, Policy Troubleshooter v3 returns `overallAccessState: UNKNOWN_INFO` (`allowAccessState: ALLOW_ACCESS_STATE_GRANTED`, `denyAccessState: DENY_ACCESS_STATE_UNKNOWN_INFO`) because Organization-level IAM Deny policies cannot be inspected. Scion's `PolicyTroubleshooterChecker` allows this by default (`denyUnknownFailOpen: true`).

---

## 5. Running the Verification Yourself

```bash
./scripts/verify-e2e.sh \
  --project <GCP_PROJECT_ID> \
  --admin-email <admin@example.com> \
  --scion-repo /path/to/scion
```

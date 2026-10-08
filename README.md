# Scion GCP IAM, Permissions & Model Garden Setup

Reference guide and bootstrap scripts for configuring **Google Cloud IAM roles, Service Accounts, APIs, and Vertex AI / Model Garden access** across all [Scion](https://github.com/GoogleCloudPlatform/scion) deployment modes.

---

## Quick Start (Bootstrap an Operator Account & Project)

> **Prerequisite:** The initial bootstrap command (`grant-deployer-iam.sh`) must be run once by someone who already holds `roles/owner` or `roles/resourcemanager.projectIamAdmin` on the target GCP project. Once granted, the operator can configure the entire stack from their own account.

```bash
# 1. Grant full end-to-end operator permissions on top of roles/editor
./scripts/grant-deployer-iam.sh \
  --project <GCP_PROJECT_ID> \
  --member user:operator@example.com \
  --tier full-operator \
  --include-editor

# 2. Enable all required GCP APIs (Compute, Cloud Run, IAP, GKE, Cloud SQL, Vertex AI, IAM, etc.)
./scripts/enable-apis.sh \
  --project <GCP_PROJECT_ID> \
  --tier all

# 3. (Post-Deploy) Wire Hub SA minting, Policy Troubleshooter actAs checks, and Agent SA delegation
./scripts/grant-runtime-sa-iam.sh \
  --project <GCP_PROJECT_ID> \
  --hub-sa scion-hub-runner@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
  --enable-minting \
  --enable-enforce-check \
  --agent-sa scion-agent@<GCP_PROJECT_ID>.iam.gserviceaccount.com \
  --grant-vertex-ai \
  --allow-user-act-as operator@example.com
```

Add `--dry-run` to any script to inspect the exact `gcloud` commands before executing them.

---

## 1. What Permissions Does the Deploying Operator Need on Their Account?

### Why `roles/editor` Alone Fails
`roles/editor` includes resource creation (`compute.*`, `run.*`, `iam.serviceAccounts.create`), Service Account attachment (`iam.serviceAccounts.actAs`), and API enablement (`serviceusage.services.enable`). **However, `roles/editor` contains zero `*.setIamPolicy` permissions** and does not grant IAP pass-through or secret policy administration.

To ensure a human operator can **deploy infrastructure, bind IAM policies, enable Model Garden models, configure secrets, SSH into VMs, AND log into the deployed Scion Hub from their own account**, grant the following bundle (`--tier full-operator`):

### Complete Operator Account Permission Table (`roles/editor` + Additive Roles)

| Role on Operator Account (`user:operator@example.com`) | Key Permissions Provided | What It Unlocks for the Operator |
| :--- | :--- | :--- |
| **`roles/editor`** *(Base role)* | `iam.serviceAccounts.create`, `iam.serviceAccounts.actAs`, `serviceusage.services.enable`, compute/storage/SQL CRUD | Creates base GCP resources, creates Service Accounts, attaches SAs to VMs/Cloud Run, and enables APIs. |
| **`roles/resourcemanager.projectIamAdmin`** | `resourcemanager.projects.getIamPolicy`<br>`resourcemanager.projects.setIamPolicy` | Grants project-level IAM roles to the Hub, Transport, and Agent Service Accounts (and allows the operator to self-grant missing project roles). |
| **`roles/iam.serviceAccountAdmin`** | `iam.serviceAccounts.create`<br>`iam.serviceAccounts.delete`<br>`iam.serviceAccounts.setIamPolicy` | Binds SA-level policies: grants `serviceAccountTokenCreator` on Transport/Agent SAs and `workloadIdentityUser` for GKE Workload Identity. |
| **`roles/iam.serviceAccountUser`** | `iam.serviceAccounts.actAs` | Allows attaching SAs to workloads **and** ensures the operator passes Policy Troubleshooter `actAs` checks when `gcp_iam_check_mode: enforce` is enabled. |
| **`roles/iam.securityReviewer`** | `iam.roles.get`, `resourcemanager.projects.getIamPolicy` | Allows inspecting all IAM policies and testing Policy Troubleshooter v3 `actAs` checks directly from the operator account. |
| **`roles/run.admin`** | `run.services.create`, `run.services.update`<br>`run.services.setIamPolicy` | Deploys Cloud Run Hub / IAP Proxy services and binds `roles/run.invoker` for the IAP service agent and Transport SA. |
| **`roles/iap.admin`** | `iap.web.setIamPolicy`<br>`iap.webServices.setIamPolicy` | Enables Identity-Aware Proxy on Cloud Run and manages IAP access bindings for users and the Transport SA. |
| **`roles/iap.httpsResourceAccessor`** | `iap.webServiceVersions.accessViaIAP` | **Critical for operator login:** Allows the operator themselves to pass through IAP to open the Scion Web UI and run `scion` CLI commands against the Hub. |
| **`roles/iap.tunnelResourceAccessor`** | `iap.tunnelInstances.accessViaIAP` | Allows the operator to SSH into private Single-Node / Hybrid GCE VMs via `gcloud compute ssh --tunnel-through-iap`. |
| **`roles/secretmanager.admin`** | `secretmanager.secrets.create`<br>`secretmanager.secrets.setIamPolicy`<br>`secretmanager.versions.add` | Creates secrets and sets per-secret IAM bindings (`google_secret_manager_secret_iam_member` in Terraform HA requires `secretmanager.secrets.setIamPolicy`, which `editor` lacks). |
| **`roles/compute.networkAdmin`** | `compute.networks.*`, `compute.subnetworks.*`, `compute.routers.*`, `compute.firewalls.*` | Creates and modifies VPCs, subnets, Cloud Router, Cloud NAT, and firewall rules. |
| **`roles/servicenetworking.networksAdmin`** | `servicenetworking.services.addPeering` | Establishes Private Service Access VPC peering for private Cloud SQL and Cloud Filestore instances. |
| **`roles/container.admin`** | `container.clusters.*`, `container.pods.*`, Kubernetes RBAC admin | Creates GKE Autopilot clusters, binds K8s RBAC (`ClusterRole`/`RoleBinding`), and allows the operator to run `kubectl` against agent pods. |
| **`roles/storage.admin`** | `storage.buckets.create`<br>`storage.buckets.setIamPolicy`<br>`storage.objects.*` | Creates GCS buckets for Scion templates/workspaces and binds bucket-level IAM policies. |
| **`roles/aiplatform.admin`** | `aiplatform.endpoints.*`, Vertex AI admin permissions | Configures Vertex AI and enables/accepts Model Garden models in the GCP Console. |
| **`roles/serviceusage.serviceUsageAdmin`** | `serviceusage.services.enable`, `serviceusage.quotas.*` | Enables required `*.googleapis.com` APIs and manages project service quotas. |

> **Organization-Level Note (OAuth Consent Screen & 3P Model Garden Terms):**
> - **IAP OAuth Brand:** If the project does not use Workforce Identity / external IdP and needs an internal GCP OAuth consent screen (`gcloud iap oauth-brands`), the operator works within the project.
> - **Model Garden Partner Models (e.g., Anthropic Claude):** Accepting 3P Marketplace/Partner terms in the GCP Console (**Vertex AI → Model Garden**) may require Billing Account Viewer or Consumer Procurement permissions (`roles/consumerprocurement.orderAdmin` or `roles/billing.viewer`) in organizations with strict Marketplace governance.

---

## 2. Deployer Roles by Deployment Tier ("`roles/editor` Plus What?")

If you prefer granting the minimum deployer roles for a specific architecture tier rather than `full-operator`, use `--tier <tier>` with `./scripts/grant-deployer-iam.sh`:

| Role (in addition to `roles/editor`) | Single-Node VM (`vm`) | Hybrid Tier (`hybrid`) | Cloud Run Sandbox (`cloudrun`) | HA via `gcloud` (`ha-gcloud`) | Multi-Hub HA Terraform (`ha-terraform`) |Full Operator (`full-operator`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `roles/resourcemanager.projectIamAdmin` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `roles/run.admin` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `roles/iam.serviceAccountAdmin` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| `roles/iap.admin` | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| `roles/iam.serviceAccountUser` | *(in editor)* | *(in editor)* | ✅ | ✅ | *(in editor)* | ✅ |
| `roles/secretmanager.admin` | — | — | — | — | ✅ | ✅ |
| `roles/compute.networkAdmin` | — | — | — | — | ✅ | ✅ |
| `roles/servicenetworking.networksAdmin` | — | — | — | — | ✅ | ✅ |
| `roles/container.admin` | — | *(in editor)* | — | *(in editor)* | ✅ | ✅ |
| `roles/storage.admin` | — | — | — | — | ✅ | ✅ |
| `roles/iap.httpsResourceAccessor` | Recommended | Recommended | Recommended | Recommended | Recommended | ✅ |
| `roles/iap.tunnelResourceAccessor` | Recommended | Recommended | — | — | — | ✅ |
| `roles/aiplatform.admin` | Recommended | Recommended | Recommended | Recommended | Recommended | ✅ |
| `roles/iam.securityReviewer` | Optional | Optional | Optional | Optional | Optional | ✅ |

---

## 3. Required GCP APIs (`*.googleapis.com`)

Run `./scripts/enable-apis.sh --project <GCP_PROJECT_ID> --tier all` to enable all required services:

| GCP Service API | Required By Tier | Purpose in Scion |
| :--- | :--- | :--- |
| `compute.googleapis.com` | All | GCE VMs, VPC networks, subnets, Cloud Router/NAT, firewall rules. |
| `run.googleapis.com` | All | Hub Cloud Run service, Single-Node VM IAP proxy, or Cloud Run Sandbox. |
| `iap.googleapis.com` | All | Identity-Aware Proxy authentication for Web UI, CLI, and agent transport tokens. |
| `secretmanager.googleapis.com` | All | Dynamic storage for User, Project, and Hub secrets (`scion-<hub_hash>-*`). |
| `storage.googleapis.com` | All | GCS bucket storage for agent templates, workspaces, and artifacts. |
| `artifactregistry.googleapis.com` | All | Container image registry for Scion Hub and agent harness images. |
| `iam.googleapis.com` | All | Service Account creation, Hub SA minting (`IAMAdminClient`), and SA IAM policies. |
| `iamcredentials.googleapis.com` | All | Short-lived token generation (`generateAccessToken`, `generateIdToken`) & `signBlob` for GCS signed URLs. |
| `cloudresourcemanager.googleapis.com` | All | Project metadata resolution and project-level IAM policy bindings. |
| `aiplatform.googleapis.com` | All (Vertex AI) | Vertex AI & Model Garden inference endpoints (Gemini, Claude on Vertex). |
| `policytroubleshooter.googleapis.com` | All (`enforce`/`log`) | Policy Troubleshooter API v3 used by Hub to verify caller `iam.serviceAccounts.actAs` permissions. |
| `logging.googleapis.com` | All | Cloud Logging for Hub, Runtime Broker, and agent containers. |
| `monitoring.googleapis.com` | All | Cloud Monitoring metrics. |
| `cloudtrace.googleapis.com` | All | Distributed Cloud Trace telemetry. |
| `container.googleapis.com` | `hybrid`, `ha` | Google Kubernetes Engine (GKE Autopilot) for isolated agent pods. |
| `file.googleapis.com` | `hybrid`, `ha` | Cloud Filestore (NFS) for shared agent workspace volumes across pods. |
| `vpcaccess.googleapis.com` | `hybrid`, `ha` | Serverless VPC Access / Direct VPC egress between Cloud Run and VPC resources. |
| `sqladmin.googleapis.com` | `ha` | Cloud SQL for PostgreSQL state database. |
| `servicenetworking.googleapis.com` | `ha` | Private Service Access VPC peering for Cloud SQL and Filestore. |

---

## 4. Vertex AI & Model Garden Requirements

Getting agents to invoke LLMs on Vertex AI requires **four distinct configurations** (IAM alone is not sufficient for partner models):

| Requirement | Where Configured | Exact Setting / Role | Notes & Common Gotchas |
| :--- | :--- | :--- | :--- |
| **1. Vertex AI API** | GCP Project | `aiplatform.googleapis.com` | Enabled via `./scripts/enable-apis.sh`. |
| **2. Agent Runtime IAM** | Target GCP Project | `roles/aiplatform.user` (`aiplatform.endpoints.predict`) | Must be granted to the SA the agent runs as:<br>• **Passthrough (VM):** VM Service Account (`scion-hub-<name>@...`)<br>• **Passthrough (GKE):** Workload Identity Agent SA (`<hub>-agent@...`)<br>• **Assign Mode:** The specific BYO or Hub-minted Agent SA. |
| **3. Model Garden Partner Enablement** | **GCP Console → Vertex AI → Model Garden** | Enable model & accept Partner EULA/Terms | **Outside IAM:** First-party **Gemini** models work as soon as `aiplatform.googleapis.com` is enabled. Third-party partner models (such as **Anthropic Claude on Vertex AI**) **must be manually enabled per project in the Model Garden console** by an operator with `roles/aiplatform.admin`. |
| **4. Hub Env Vars & GCP Identity Mode** | Scion Hub (`scion hub env` & Project/Agent config) | • `GOOGLE_CLOUD_PROJECT=<project>`<br>• `GOOGLE_CLOUD_REGION=<region>` (e.g., `us-east5` for Claude)<br>• GCP Identity Mode: **`passthrough`** or **`assign`** | • Scion automatically maps `GOOGLE_CLOUD_PROJECT` to `ANTHROPIC_VERTEX_PROJECT_ID` for the Claude harness.<br>• **GKE / HA Gotcha:** Agent GCP identity defaults to **`block`** (which blocks the metadata server). You must change the project or agent GCP identity mode from `block` to `passthrough` or `assign`. |

```bash
# Example: Configure global Vertex AI environment variables on the Scion Hub
scion hub env set --scope hub --always GOOGLE_CLOUD_PROJECT=<GCP_PROJECT_ID>
scion hub env set --scope hub --always GOOGLE_CLOUD_REGION=us-east5
```

---

## 5. Service Account Creation, Minting & Impersonation

Scion supports three GCP identity workflows for agent containers:

| Feature / Mode | Required API(s) | Hub Runtime SA Permission | Target SA / Caller Permission | How It Works & Caveats |
| :--- | :--- | :--- | :--- | :--- |
| **A. Hub-Minted SAs**<br>(`scion hub gcp-accounts mint`) | `iam.googleapis.com`<br>`iamcredentials.googleapis.com` | **`roles/iam.serviceAccountAdmin`** on the Hub's GCP project | • **Caller in Scion:** Project Owner/Admin (project-scoped) or Hub Admin (hub-scoped).<br>• **Minted SA:** Created with **zero project roles**! | The Hub creates `scion-<slug>@<project>.iam.gserviceaccount.com` and calls `SetIamPolicy` on that SA to grant:<br>1. `roles/iam.serviceAccountTokenCreator` to the **Hub SA**<br>2. `roles/iam.serviceAccountUser` (`actAs`) to the **minted SA on itself** (so parent agents can spawn sub-agents).<br>⚠️ **You must still grant `roles/aiplatform.user` (or other project roles) to the newly minted SA** using `./scripts/grant-runtime-sa-iam.sh --agent-sa <minted-sa> --grant-vertex-ai`. |
| **B. Bring-Your-Own SA (BYOSA)**<br>(`assign` mode) | `iamcredentials.googleapis.com` | **`roles/iam.serviceAccountTokenCreator`** bound **on the target Agent SA** | Target Agent SA holds `roles/aiplatform.user` (and any project-specific roles) on its GCP project. | When registered, the Hub verifies impersonation via `generateAccessToken` and mints short-lived access/OIDC tokens on demand for the agent container's `sciontool` metadata server (`POST /api/v1/agent/gcp-token`). |
| **C. Enforced `actAs` Delegation**<br>(`gcp_iam_check_mode: enforce`) | `policytroubleshooter.googleapis.com` | **`roles/iam.securityReviewer`** on the GCP Project (or Org/Folder for cross-project SAs) | **Human User (`user:...`) or Parent Agent SA** must hold **`roles/iam.serviceAccountUser`** (`iam.serviceAccounts.actAs`) on the target Agent SA (or Broker Host SA for `passthrough`). | Before allowing a user to attach a GCP SA to a project or launch an agent with it, the Hub calls Policy Troubleshooter v3 to verify the caller has `iam.serviceAccounts.actAs` on that SA. **Fails closed** if the Hub SA lacks `roles/iam.securityReviewer`. |

---

## 6. Complete Runtime Service Accounts & End-User IAM Matrix

### A. Hub Runtime Service Account (`<hub>-hub@...` / `scion-hub-runner@...`)

| Role | Resource Scope | Why Scion Hub Needs It |
| :--- | :--- | :--- |
| `roles/cloudsql.client` (+ `roles/cloudsql.instanceUser` if IAM DB auth) | Project | Connect to Cloud SQL (PostgreSQL) in HA mode. |
| `roles/storage.objectAdmin` | Project or Bucket | Read/write agent templates, workspaces, and artifacts in GCS. |
| `roles/secretmanager.admin` | Project *(can be conditioned to `scion-<hash>-*`)* | Create, update, and read user/project/hub secrets dynamically (`secretAccessor` alone fails when users save secrets in the UI/CLI). |
| `roles/container.developer` *(or `roles/container.clusterViewer` + K8s RBAC)* | Project / GKE Cluster | Schedule and manage agent Pods in GKE. |
| `roles/iam.serviceAccountTokenCreator` | **Self** (`<hub>-hub` SA) | Required for `iam.serviceAccounts.signBlob` to generate signed GCS URLs for template syncing. |
| `roles/iam.serviceAccountTokenCreator` *(or `serviceAccountOpenIdTokenCreator`)* | **Transport SA** (`<hub>-transport` SA) | Mint `SCION_TRANSPORT_TOKEN` OIDC tokens so GKE agent pods can traverse IAP to reach the Hub API. |
| `roles/iam.serviceAccountTokenCreator` | **Each Assigned Agent SA** | Mint short-lived GCP access and OIDC tokens for agents running in `assign` mode. |
| `roles/iam.serviceAccountAdmin` | Project *(Optional — Minting)* | Required if using `scion hub gcp-accounts mint` so the Hub can create SAs and bind its own `serviceAccountTokenCreator` policy on them. |
| `roles/iam.securityReviewer` | Project or Org *(Optional — Enforce mode)* | Required when `server.auth.gcp_iam_check_mode` is `enforce` or `log` (Policy Troubleshooter v3). |
| `roles/logging.logWriter`, `roles/monitoring.metricWriter`, `roles/cloudtrace.agent` | Project | Emit structured logs, metrics, and traces. |

### B. Transport Service Account (`<hub>-transport@...` / `scion-transport@...`)

| Role | Resource Scope | Why Scion Needs It |
| :--- | :--- | :--- |
| `roles/iap.httpsResourceAccessor` | IAP Web Service / Cloud Run Service | Allows agent OIDC callbacks (`SCION_TRANSPORT_TOKEN`) to pass through Identity-Aware Proxy. |
| `roles/run.invoker` | Hub Cloud Run Service | Allows the request to invoke the underlying Cloud Run service after passing IAP. |

### C. Default Agent / Broker Host Service Account (`<hub>-agent@...` or VM SA)

| Role | Resource Scope | Why Scion Needs It |
| :--- | :--- | :--- |
| `roles/aiplatform.user` | Project | Call Vertex AI / Model Garden endpoints when agents run in `passthrough` mode. |
| `roles/iam.workloadIdentityUser` | **On `<hub>-agent` SA** *(Member: `serviceAccount:<PROJECT>.svc.id.goog[scion-agents/scion-agent]`)* | Binds the Kubernetes Service Account (`scion-agents/scion-agent`) to `<hub>-agent` via GKE Workload Identity. |
| `roles/artifactregistry.reader` | Project | Pull agent harness container images from Artifact Registry. |
| `roles/logging.logWriter`, `roles/monitoring.metricWriter` | Project | Emit container logs and metrics from GKE / GCE. |

### D. Human End-Users (Developers Using Scion)

| Role | Resource Scope | Why the User Needs It |
| :--- | :--- | :--- |
| `roles/iap.httpsResourceAccessor` | IAP Web Service / Cloud Run Service | Log into the Scion Web UI and authenticate `scion` CLI commands through IAP. |
| `roles/iam.serviceAccountUser` (`iam.serviceAccounts.actAs`) | Target Agent SA *(Only if `gcp_iam_check_mode: enforce`)* | Required to register a BYOSA, set it as a project default, or launch an agent with it when IAM `actAs` enforcement is enabled. |

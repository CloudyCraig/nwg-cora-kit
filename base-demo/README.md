# NatWest Payment Platform demo on EKS + Splunk Observability

A ~1 hour demo that stands up a 24-service simulation of the NatWest Payment
Platform on a real Amazon EKS cluster, fully instrumented with the Splunk
Distribution of OpenTelemetry Python and shipped through the Splunk OTel
Collector to Splunk Observability Cloud.

Every pod is a real running service making real HTTP calls to its configured
downstreams. Only the business logic is simulated (`sleep` + fan-out). From
Splunk's view the telemetry is indistinguishable from production.

## Architecture

```
Channels (traffic-generator)
   mobile-app, online-banking, branch, bankline, bankline-direct, partner-api
          |
          v
     api-gateway
          |
          v
 payment-initiation-service --> customer-profile, limits, notification,
          |                     user, payment-status, fee-pricing
          |
          +--> payment-validation-service
          |      --> account, beneficiary, sanctions-aml, fraud-detection
          |
          +--> routing-service  (picks one scheme per payment)
          |      --> faster-payments | bacs | chaps | swift | sepa | cheque
          |
          
          +--> ledger-service --> settlement --> reconciliation --> reporting
```

24 services total: 1 gateway + 4 experience + 5 payment + 4 business
+ 4 ledger & settlement + 6 external payment networks.

## Prerequisites

- AWS account with permission to create EKS, IAM, ECR, Secrets Manager, KMS
  (EKS is deployed into the **existing default VPC** — no VPC creation required,
  to work around org-level SCPs that block `ec2:CreateVpc`)
- `aws`, `terraform` (>=1.6), `kubectl`, `helm`, `docker` (with `buildx`), `jq`
- Splunk Observability Cloud account with an **ingest token** and realm
  (e.g. `us1`, `eu0`)

## One-time setup

1. Copy the example tfvars:
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   # Edit terraform/terraform.tfvars: set allowed_public_api_cidrs to YOUR IP/32
   ```

2. Export the sensitive vars (never committed):
   ```bash
   export TF_VAR_splunk_realm="us1"          # or your realm
   export TF_VAR_splunk_access_token="..."   # Splunk Observability ingest token
   export TF_VAR_allowed_public_api_cidrs='["'"$(curl -s https://checkip.amazonaws.com)"'/32"]'

   # Splunk Enterprise HEC tokens (3 required, fresh per environment).
   # Generate with uuidgen; never reuse the placeholder values from git history.
   export TF_VAR_splunk_enterprise_hec_token="$(uuidgen)"
   export TF_VAR_splunk_enterprise_hec_token_firehose="$(uuidgen)"
   export TF_VAR_splunk_enterprise_hec_token_scripts="$(uuidgen)"
   ```

## Build the demo (~1 hour end-to-end, first time)

```bash
./scripts/00-provision.sh          # ~15-20 min (EKS control plane + Splunk Enterprise EC2)
./scripts/01-build-push.sh         # ~3-5 min  (docker buildx + ECR)
./scripts/02-install-collector.sh  # ~2 min    (Splunk OTel chart)
./scripts/03-deploy.sh             # ~2-3 min  (24 services)
./scripts/04-start-traffic.sh      # ~30 sec
./scripts/05-deploy-frontend.sh    # ~1 min    (SPA login + persona switcher)
./scripts/05b-frontend-public-proxy.sh  # ~30 sec   (nginx on Splunk EC2 -> NodePort)
```

The SPA is then reachable on the stable demo hostname:
**http://itsi.splunk-observability.com/** (Route53 A-record -> Elastic IP on the
Splunk Enterprise EC2; see [`terraform/splunk_enterprise_dns.tf`](./terraform/splunk_enterprise_dns.tf)).

### Optional: ITSI tier + ThousandEyes synthetic monitoring

```bash
./scripts/06-install-itsi.sh                  # ~10 min   (ITSI + PSC + NFR licence)
./scripts/07-itsi-bootstrap.sh                # ~1 min    (5-tier service tree, 32 microservices, 7 KPI base searches, glass table)
./scripts/08-configure-thousandeyes.sh        # ~30 sec   (6 ThousandEyes tests via TE v7 API)
./scripts/09-configure-splunk-te-inputs.sh    # ~30 sec   (Splunk index + 4 HEC tokens for the Cisco TE add-on)
./scripts/10-extend-itsi-with-te.sh           # ~1 min    (adds an L2 "Digital Customer Experience" tier with 7 synthetic KPIs)
```

Step 8 needs `secrets/thousandeyes.env` populated with a working v7 OAuth bearer
token + Account Group ID — see [`secrets/thousandeyes.env.example`](./secrets/thousandeyes.env.example)
for the schema.

Then open Splunk Observability Cloud and navigate to APM -> Service Map.
You should see the 24 NatWest services with edges matching the diagram.

## Verify

```bash
kubectl get pods -n natwest                 # 24 services + 1 traffic-generator
kubectl get pods -n splunk-otel             # agent DaemonSet + clusterReceiver
kubectl logs deploy/traffic-generator -n natwest -f
```

In Splunk Observability Cloud:

- **APM -> Service Map** – all 24 services, edges match the diagram
- **APM -> Traces** – end-to-end trace: `api-gateway -> payment-initiation
  -> payment-validation -> fraud-detection -> routing -> faster-payments
  -> ledger -> settlement -> reconciliation -> reporting`
- **APM -> Tag Spotlight** – break down by `payment.scenario`
  (faster-payments, chaps, swift, ...)
- **Log Observer** – pod logs with `trace_id` linking back to APM
- **Infrastructure Navigator -> Kubernetes** – cluster + nodes + pods

## Presenting the demo

The full presenter pack lives under [`docs/presentation/`](./docs/presentation/):

| Artefact | Purpose |
|---|---|
| [`scripts/generate-deck.py`](./scripts/generate-deck.py) | Builds the customer-ready `.pptx` against the Splunk corporate template (master, fonts, colours, footer, segues all inherited) |
| [`docs/presentation/SLIDES.md`](./docs/presentation/SLIDES.md) | Marp source — fast in-browser preview while iterating on content |
| [`docs/presentation/TALK_TRACK.md`](./docs/presentation/TALK_TRACK.md) | Tell-Show-Tell talk track — Ask Beats, Objections, Competitive Positioning, Champion Brief |
| [`scripts/run-of-show.md`](./scripts/run-of-show.md) | Operational drive script (commands, `kubectl` checks, recovery) |
| [`docs/customer/path-to-green.md`](./docs/customer/path-to-green.md) | Maps every row of the customer's *Splunk Observability Cloud — Capability Assessment* (Path to Green) to the matching live demo asset, plus the remediation plan for the 2 AMBER rows |
| [`docs/customer/path-to-green-requirements-v1.1.md`](./docs/customer/path-to-green-requirements-v1.1.md) | Customer-shaped v1.1 of the same assessment — preserves the original 8 sections + Requirement/RAG/Capability/Proof/Comment columns; refreshed Comments carry the live-demo evidence and an extended RAG legend (GREEN ✓ = demonstrably proven in this demo) |
| [`docs/customer/story-rum-apm-postgres.md`](./docs/customer/story-rum-apm-postgres.md) | The "Postgres meltdown" single-trigger story (~6 min) that walks RUM → Session Replay → APM trace → Metrics & Database Query Performance → Logs → Postgres KPIs in two acts. Fire from the SPA Chaos Dashboard (`/?ops=1#/ops` → *Customer stories (multi-act)* → **Payment meltdown**) or from a shell via `scripts/incident.sh payment-meltdown`. |
| [`scripts/render-customer-docs.sh`](./scripts/render-customer-docs.sh) | Renders every `.md` under `docs/customer/` into a sibling `.docx` (and `.pdf` with `--pdf`) via pandoc, so the customer can receive Rakesh-format Word docs without losing markdown as the source of truth. Needs `brew install pandoc`; `.docx`/`.pdf` outputs are gitignored. |

Render the customer deck:

```bash
python3 scripts/generate-deck.py
# → docs/presentation/slides.pptx (Splunk-templated, 20 slides + speaker notes)
```

See [`docs/presentation/README.md`](./docs/presentation/README.md) for
the full rendering guide (Splunk template path, Marp preview path, and
how to customise without breaking the template inheritance).

## Demo narrative hooks

The traffic generator sends realistic scenario mixes plus periodic error
bursts. Suggested talk-track moments:

- "Here you see Faster Payments dominating volume (~60%), CHAPS
  used for same-day high-value."
- "Notice `fraud-detection-service` shows the widest latency distribution –
  ML scoring. Splunk APM flags it automatically in RED metrics."
- "Every 3 minutes we inject an error burst – watch `sanctions-aml-service`
  and the downstream impact propagate through the service map."
- "Click into any slow trace and you'll see the full waterfall across
  24 services with zero code changes – pure auto-instrumentation."
- "Open the SPA and switch persona to **Olivia (Bronze)** / **James
  (Silver)** / **Margaret (Gold)** — every span carries
  `customer.id` + `customer.tier`. Tag Spotlight pivots by tier;
  Gold gets a fraud-detection fast-path so its p95 sits below
  Bronze. Run `scripts/incident.sh inject-tier-throttle bronze`
  for a tier-segregated decline incident."

## Cost

| Component                | Approx / month if left running |
|--------------------------|--------------------------------|
| EKS control plane        | $73                            |
| 2x t3.large nodes        | $120                           |
| ECR + Secrets Manager    | <$2                            |
| **Total**                | **~$195**                      |

(No NAT gateway: nodes run in default-VPC public subnets with public IPs.)

Run `./scripts/99-destroy.sh` after the demo to drop it to $0.

## Teardown

```bash
./scripts/99-destroy.sh
```

Removes the traffic generator, the Helm releases, the namespaces, and then
runs `terraform destroy` on EKS, ECR, KMS and Secrets Manager. The default
VPC and its subnets are never modified (only tagged) so nothing shared is
deleted.

## Security notes

- No credentials in source. Splunk ingest token is a Terraform `sensitive`
  variable, stored in AWS Secrets Manager (KMS-encrypted) and mounted into
  the collector via a Kubernetes Secret.
- EKS public API endpoint is CIDR-restricted to the operator IP by the
  `allowed_public_api_cidrs` variable (validation rejects `0.0.0.0/0`).
- EKS secrets are envelope-encrypted with a dedicated KMS key.
- EKS audit + authenticator + controllerManager + scheduler logs enabled.
- ECR scan-on-push + immutable tags + AES256 encryption at rest.
- EKS control-plane audit/auth/api logs shipped to CloudWatch.
- Pods run as non-root (uid 10001), read-only root filesystem, all
  capabilities dropped, seccomp `RuntimeDefault`.
- `NetworkPolicy` defaults to deny in the `natwest` namespace with
  explicit allow for intra-namespace HTTP on port 8080, DNS, and OTLP
  to the collector agent.
- `automountServiceAccountToken: false` on every pod.

## Optional: Splunk Enterprise + Log Observer Connect

The default demo ships traces/metrics/logs straight to Splunk Observability
Cloud. To exercise the **Log Observer Connect (LOC)** flow — where APM
"Logs for this trace" pulls from a Splunk Platform instance — terraform can
also stand up a single-node Splunk Enterprise box in the **same default VPC**
as EKS, and `02-install-collector.sh` will auto-wire the OTel agent to ship
logs there over HEC.

### Enable

In `terraform/terraform.tfvars`:

```hcl
splunk_enterprise_enabled        = true
splunk_enterprise_admin_password = "..."   # min 8 chars; sensitive
splunk_enterprise_allowed_web_cidrs = ["YOUR.IP/32"]  # for 8000/8089/8088 over public IP
# splunk_enterprise_hec_token{,_firehose,_scripts} are REQUIRED; supply via the
# TF_VAR_* env vars shown in step 2 above. There are no longer pinned defaults.
```

Then point at the local installer + license (kept out of this repo):

```hcl
splunk_enterprise_media_path   = "/abs/path/to/splunk-10.x-linux-amd64.tgz"
splunk_enterprise_license_path = "/abs/path/to/Splunk Enterprise NFR.License"
```

`./scripts/00-provision.sh` will:

1. Create a KMS-encrypted, BPA-locked S3 bucket and `aws s3 cp` the installer
   + license up (so they're never in TF state).
2. Provision an EC2 (`c5.4xlarge`, gp3, IMDSv2-required) with an instance
   profile granting just-enough S3 read + SSM.
3. Bootstrap Splunk via `cloud-init`: extract, seed admin, pre-stage HEC
   `inputs.conf` with the pinned token, accept license, register NFR,
   `enable boot-start -systemd-managed 1 -create-polkit-rules 1`.

### Wire the collector

`./scripts/02-install-collector.sh` reads
`terraform output splunk_enterprise_hec_endpoint` /
`splunk_enterprise_hec_token`; when present it:

* Adds `splunk_platform_hec_token` to the existing `splunk-access-token`
  Secret (alongside the o11y access token).
* Helm-overrides `splunkPlatform.endpoint` / `token` / `insecureSkipVerify=true`
  (default Splunk self-signed cert).

Container logs land in index `main`, sourcetype `kube:container:service`,
with `trace_id` / `span_id` already on every record courtesy of
`OTEL_PYTHON_LOG_CORRELATION=true`. Postgres, Redis, and Kafka container
stdout/stderr route to `index=nwpay_infra` (`postgresql`, `redis`, `kafka`
sourcetypes) via `transform/infra_routing` in `collector/values.yaml`.
Postgres DBM snapshots land in the same index as `sourcetype=postgres:dbm`.

### Finish Log Observer Connect (Splunk Enterprise ↔ Observability)

**Automated (Enterprise side + credential check):**

```bash
# Requires TF_VAR_splunk_enterprise_admin_password in .env and kubectl access.
scripts/05f-configure-loc.sh
# or: make configure-loc
```

This bootstraps the `lo-connect` user/role on Splunk Enterprise (indexes
`main`, `splunkrum`, `nwpay_infra`), verifies `:8089` auth, and — when
`SPLUNK_API_TOKEN` (or `TF_VAR_splunk_api_token`) is set — PUTs the existing
`lo-connect` Splunk Enterprise integration in Observability (`GhVhuhqAIAA` in
the eu0 demo org) with the SplunkCommonCA certificate.

If you only have the cluster **ingest** token, step 3 prints the Observability
UI path and writes `.loc-splunk-common-ca.pem` for pasting into the wizard.

**One-shot UI finish** (when no admin API token is available):

1. Splunk Observability → **Logs** → **Logs connections** → **lo-connect** → edit
   (older docs: *Settings → Log Observer Connect*).
2. Splunk URL: `https://itsi.splunk-observability.com:8089` (or
   `terraform output splunk_enterprise_fqdn` with `:8089`).
3. Username `lo-connect`, password `lo-connect-demo-pass` (or your
   `LOC_PASSWORD`), certificate = SplunkCommonCA PEM from
   `scripts/05f-configure-loc.sh` (`.loc-splunk-common-ca.pem`).
4. **Index allow-list** must include `main`, `nwpay_infra`, and `splunkrum`
   when that index exists.
5. APM → any trace → **Logs for this trace** federates from Splunk Enterprise.
6. APM → **postgres** / **redis** / **kafka** → **Logs** tab (infra logs need
   `service.name` from `transform/infra_routing`). See
   [`docs/operations/infra-logs-loc.md`](docs/operations/infra-logs-loc.md).

**Promote demo span attributes to APM MetricSets** (separate from LOC):

```bash
SPLUNK_REALM=eu0 SPLUNK_API_TOKEN=...  scripts/05d-promote-metricsets.sh
# or: scripts/00-bootstrap.sh --with-metricsets
```

   The script attempts the undocumented internal endpoint Splunk's UI
   uses, and falls back to printing a click-by-click runbook if your
   tenant doesn't expose it. Full instructions and the canonical list
   of 9 MetricSets: [`docs/operations/metricsets.md`](docs/operations/metricsets.md).

### Verify

```bash
# Terraform-side
terraform -chdir=terraform output splunk_enterprise_web_url
terraform -chdir=terraform output splunk_enterprise_hec_endpoint

# HEC roundtrip from the Splunk box (via SSM Session Manager)
aws ssm start-session --target "$(terraform -chdir=terraform output -raw splunk_enterprise_instance_id)"
# then: curl -k https://localhost:8088/services/collector/event \
#   -H "Authorization: Splunk $TOKEN" -d '{"event":"hello"}'

# From inside the cluster: confirm the platform exporter is non-zero
kubectl -n splunk-otel logs ds/splunk-otel-collector-agent | grep -i splunk_hec
```

### Cost (additional, if enabled)

| Component                      | Approx / month if left running |
|--------------------------------|--------------------------------|
| 1x c5.4xlarge EC2 (Splunk)    | ~$550 (730 h/mo on-demand, region-dependent) |
| gp3 200 GB root volume         | ~$16                           |
| S3 staging bucket              | <$1 (one-time + tiny)          |
| **Add'l total**                | **~$570**                      |

`./scripts/99-destroy.sh` tears it down with the rest of the demo.

## Optional: ThousandEyes synthetic monitoring + ITSI Digital Customer Experience tier

When the demo wants to tell the **"is the bank reachable, fast and working
end-to-end from anywhere on earth?"** story, ThousandEyes synthetic tests
plug into the existing ITSI service tree without touching any of the live
microservices.

### What gets created

| Test  | Type            | Cadence | What it tells you                                        |
|-------|-----------------|---------|----------------------------------------------------------|
| TE-01 | HTTP server     | 2 min   | The SPA login page is reachable < 3 s from 5 geos        |
| TE-02 | HTTP server     | 2 min   | `/api/recent` returns 200 with a JSON `items` payload     |
| TE-03 | Page-load       | 5 min   | Real-browser DOM/page-load metrics (synthetic baseline)  |
| TE-04 | Web transaction | 15 min  | Full journey: login -> send payment -> look up status    |
| TE-05 | HTTP server POST| 5 min   | `/api/process` accepts a synthetic FPS payment           |
| TE-06 | DNS server      | 5 min   | `itsi.splunk-observability.com` resolves on 1.1.1.1/8.8.8.8/9.9.9.9 |

These feed an **L2 Digital Customer Experience tier** in ITSI with 7 KPIs:

- SPA availability + response time (TE-01)
- API gateway availability (TE-02)
- SPA page-load time (TE-03)
- End-to-end journey success rate + transaction time (TE-04)
- DNS resolution time (TE-06)

### Setup

```bash
# 1. Drop credentials into secrets/thousandeyes.env (gitignored)
cp secrets/thousandeyes.env.example secrets/thousandeyes.env
$EDITOR secrets/thousandeyes.env  # set TE_OAUTH_BEARER_TOKEN + TE_ACCOUNT_GROUP_ID

# 2. Create the 6 tests in ThousandEyes Cloud
./scripts/08-configure-thousandeyes.sh

# 3. Provision Splunk side: index + 4 HEC tokens for the Cisco TE add-on
./scripts/09-configure-splunk-te-inputs.sh

# 4. Manual click-through (one-time, the add-on doesn't expose these via REST):
#      - Splunk Web -> Cisco ThousandEyes App -> Configuration -> ThousandEyes User -> OAuth Authorize
#      - Splunk Web -> Cisco ThousandEyes App -> Inputs -> create the 4 streams
#      - ThousandEyes UI -> Account Settings -> Integrations -> Streaming -> new Splunk stream
#    Step 9 prints the exact URLs / token values to paste.

# 5. Add the synthetic L2 tier to ITSI
./scripts/10-extend-itsi-with-te.sh
```

### Why HEC port 8088 is now public-internet ingress

ThousandEyes Cloud needs to reach the Splunk HEC endpoint from the public
internet. `terraform/splunk_enterprise_dns.tf` adds an SG rule that opens
tcp/8088 from `var.thousandeyes_egress_cidrs` (default `0.0.0.0/0`). The
HEC tokens themselves are the access control. To tighten, point that
variable at the published TE Cloud egress prefixes from the
[ThousandEyes docs](https://docs.thousandeyes.com/).

## Phase 2 extensions (intentionally out of scope)

The demo is a topology simulator, not a real payment system. Natural
next steps if you want to grow it into a fuller demo:

- Replace the template image with real Spring Boot / Python / Node
  services for 3-5 "hero" services (payment-initiation, fraud-detection,
  ledger) so Splunk APM code profiling has real code to profile.
- Add a real data plane: MSK (Kafka) for event streaming,
  RDS PostgreSQL for `ledger-service`, ElastiCache Redis for
  `customer-profile-service`.
- Add auth: mTLS via an in-cluster CA or SPIRE workload identities.
- Add Splunk Enterprise Security / ITSI: the same OTel pipeline can
  fork to both observability and security backends via the collector.
- Replace `kubectl apply` with ArgoCD or Flux for GitOps.

## Repo layout

```
terraform/                  EKS 1.30 on default VPC, ECR, KMS, Secrets Manager
app/                        Python template microservice + Dockerfile
helm/natwest-payments/      Helm chart encoding the 24-service topology
collector/                  Splunk OTel Collector helm values
traffic-generator/          Python traffic generator (6 payment scenarios)
scripts/                    One-shot scripts 00..04 + 99-destroy
```

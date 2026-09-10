#!/usr/bin/env bash
# Deploy the NatWest payments demo into the London nwg-demo EKS cluster (Craig's acct).
# - collector -> Craig's eu2 o11y org
# - all 35 workloads from the captured live state, images repointed to Craig's ECR
# Secrets are created here (never printed). HEC endpoint/token are placeholders until
# the London Splunk box is up (patched post-launch).
set -uo pipefail
export AWS_PROFILE=worldpay
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CAP="$REPO/ops/state-capture-2026-07-20/k8s/natwest-all-manifests.yaml"
SEC="$REPO/secrets/observability-eu2.env"
OUT="$HERE/natwest-london.yaml"

# --- eu2 tokens (never echoed) ---
set -a; source "$SEC"; set +a
: "${SFX_REALM:?}"; : "${SFX_INGEST_TOKEN:?}"; : "${SFX_RUM_TOKEN:?}"

echo "[1/6] kubeconfig -> nwg-demo"
aws eks update-kubeconfig --name nwg-demo --region eu-west-1 >/dev/null
kubectl get nodes -o wide || { echo "nodes not ready"; exit 1; }

echo "[2/6] transform captured manifest -> $OUT"
python3 "$HERE/transform-manifest.py" "$CAP" "$OUT"

echo "[3/6] namespace + serviceaccounts"
kubectl create namespace natwest --dry-run=client -o yaml | kubectl apply -f -

echo "[4/6] secrets (generated locally; RUM from eu2)"
# demo frontend password -> record to chmod600 file, store only the sha256 in-cluster
FE_PW="$(openssl rand -hex 8)"
FE_SHA="$(printf '%s' "$FE_PW" | shasum -a 256 | awk '{print $1}')"
umask 077
printf 'web-frontend login password: %s\n' "$FE_PW" > "$HERE/frontend-password.txt"
PG_PW="$(openssl rand -hex 12)"
PRESENTER="$(openssl rand -hex 16)"
PEPPER="$(openssl rand -hex 32)"

# POSTGRES_DB=ledger is REQUIRED (not in capture): the postgres image names its default
# db from it and runs the initdb schema there; ledger-service connects to jdbc .../ledger.
kubectl -n natwest create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=natwest --from-literal=POSTGRES_PASSWORD="$PG_PW" \
  --from-literal=POSTGRES_DB=ledger \
  --dry-run=client -o yaml | kubectl apply -f -
# postgres-monitoring: DSN for the postgres-exporter sidecar (envFrom, not in capture)
kubectl -n natwest create secret generic postgres-monitoring \
  --from-literal=DATA_SOURCE_NAME="postgresql://natwest:${PG_PW}@localhost:5432/ledger?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n natwest create secret generic web-frontend-rum \
  --from-literal=RUM_ACCESS_TOKEN="$SFX_RUM_TOKEN" \
  --from-literal=AUTH_PASSWORD_SHA256="$FE_SHA" \
  --dry-run=client -o yaml | kubectl apply -f -

# HEC endpoint/token are placeholders; patched after the London Splunk box is launched.
kubectl -n natwest create secret generic chaos-controller-token \
  --from-literal=CHAOS_PRESENTER_TOKEN="$PRESENTER" \
  --from-literal=SPLUNK_HEC_ENDPOINT="https://REPLACE_SPLUNK_BOX:8088" \
  --from-literal=SPLUNK_HEC_TOKEN="REPLACE_HEC_TOKEN" \
  --from-literal=SPLUNK_HEC_INDEX="nwpay_audit" \
  --from-literal=SPLUNK_HEC_INSECURE="1" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n natwest create secret generic nwpay-audit-pepper \
  --from-literal=pepper="$PEPPER" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$HERE/chaos-controller-rbac.yaml"
echo "[5/6] splunk-otel-collector -> eu2 org (realm=$SFX_REALM)"
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart >/dev/null 2>&1
helm repo update >/dev/null
helm upgrade --install splunk-otel-collector splunk-otel-collector-chart/splunk-otel-collector \
  -n splunk-monitoring --create-namespace \
  --set splunkObservability.realm="$SFX_REALM" \
  --set splunkObservability.accessToken="$SFX_INGEST_TOKEN" \
  --set clusterName=nwg-demo \
  --set environment=demo \
  --set splunkObservability.profilingEnabled=true \
  --set gateway.enabled=false

echo "[6/6] apply the 35-workload payments stack"
kubectl apply -f "$OUT"

echo "=== rollout status (natwest namespace) ==="
kubectl -n natwest get deploy -o wide 2>&1 | head -40
echo "DONE. Frontend NodePort:"
kubectl -n natwest get svc web-frontend -o jsonpath='{.spec.ports[0].nodePort}'; echo

# Kafka producer startup-race guard: payment-initiation must not start before kafka is ready,
# or its producer inits dead and the settlement/reconciliation/reporting chain stays silent.
kubectl -n natwest patch deploy payment-initiation-service --type=strategic \
  --patch-file "$HERE/payment-initiation-wait-for-kafka.patch.json"

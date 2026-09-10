#!/usr/bin/env bash
# Live-drivable incident control plane for the NatWest payments demo.
#
# >>> PREFERRED INTERFACE: the SPA Chaos Dashboard at /ops <<<
# Run `scripts/05c-chaos-controller.sh` once, then open
# `<spa>/?ops=1#/ops` for a one-click UI. The dashboard backs onto
# chaos-controller (helm chart `chaosController.enabled=true`) which
# performs the SAME `kubectl set env` / `kubectl scale` mutations
# this script does, and emits an IDENTICAL-shape `nwpay:chaos` HEC
# audit event to `index=nwpay_audit` (sourcetype `nwpay:chaos`) so
# the SIEM correlation searches (`chaos_off_change_window`,
# `payments_excessive_declines_by_tier`) keep firing for either path.
#
# This script is kept as a CLI fallback for headless / SSH-only
# environments. The chaos-controller scenario IDs map 1:1 to the
# subcommands below for the original 6 scenarios, so `make
# chaos-recover` and `scripts/incident.sh recover` produce the same
# cluster state.
#
# Each subcommand toggles environment variables on a running Deployment
# via `kubectl set env`, which triggers a rolling restart. The pathology
# is then visible in Splunk RUM, APM, AlwaysOn Profiling, the dashboard,
# and (when the relevant detector exists) as a fired alert.
#
# Usage:
#   scripts/incident.sh bad-deploy-fraud
#   scripts/incident.sh swift-counterparty-flap
#   scripts/incident.sh cache-cold
#   scripts/incident.sh db-slow
#   scripts/incident.sh fraud-cpu-regression
#   scripts/incident.sh inject-tier-throttle bronze
#   scripts/incident.sh clear-tier-throttle
#   scripts/incident.sh kafka-broker-down
#   scripts/incident.sh payment-meltdown
#   scripts/incident.sh recover
#   scripts/incident.sh status
#
# Optional env:
#   NS                       - target namespace (default natwest)
#   FRAUD_ERROR_RATE         - error rate to set on bad-deploy-fraud (default 0.20)
#   SWIFT_ERROR_RATE         - error rate to set on swift-counterparty-flap (default 0.30)
#   COLD_CACHE_HIT_RATE      - cache hit rate to set on cache-cold (default 0.40)
#   DB_LATENCY_MS            - injected DB latency for db-slow (default 200)
#   TIER_THROTTLE_RATE       - throttleProb for the targeted tier (default 0.30)
#   KAFKA_DEPLOYMENT         - kafka deployment name (default kafka)
#   KAFKA_DOWN_WAIT_S        - how long to wait for kafka to re-Ready (default 180)
#   MELTDOWN_DB_LATENCY_MS   - DB latency injected in act 1 of payment-meltdown (default 400)
#   MELTDOWN_ACT1_S          - dwell time at the slow-query phase (default 240)
#   MELTDOWN_ACT2_S          - dwell time at the postgres-outage phase (default 120)
#   MELTDOWN_AUTORECOVER     - 1/0 - auto-clear at the end of act 2 (default 1)
#   MELTDOWN_POSTGRES_DEPLOY - postgres deployment name (default postgres)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/apm_topology_repair.sh"

require_cmd kubectl

NS="${NS:-${SERVICE_NAMESPACE}}"

# ---------------------------------------------------------------------------
# Chaos audit emitter. Posts one structured event per inject / clear into
# Splunk Enterprise's nwpay_audit index via HEC, so the Compliance &
# Security panel can correlate detector firings with the operator action
# that triggered them.
#
# Inputs are read at first use (so missing config does not abort the
# main inject path - chaos audit is a best-effort beacon, not a
# pre-condition):
#
#   SPLUNK_HEC_ENDPOINT  - default tries `terraform output
#                          splunk_enterprise_hec_endpoint_public`
#   SPLUNK_HEC_TOKEN     - default tries `terraform output
#                          splunk_enterprise_hec_token_scripts`
#   SPLUNK_HEC_INDEX     - default nwpay_audit
#   SPLUNK_HEC_INSECURE  - default 1 (the demo Splunk uses self-signed certs)
#   ACTOR                - default $USER. The "who triggered the chaos"
#                          field on the audit event.
# ---------------------------------------------------------------------------

# Canonical customer context for the payment-meltdown story (Margaret Gold,
# FPS pocket-money payment). Stamped on chaos-audit events so ITSI Episode
# Review and SIEM searches can pivot without guessing which SPA persona was
# on stage.
STORY_MELTDOWN_CUSTOMER_ID="${STORY_MELTDOWN_CUSTOMER_ID:-cust-uk-003}"
STORY_MELTDOWN_CUSTOMER_NAME="${STORY_MELTDOWN_CUSTOMER_NAME:-Margaret}"
STORY_MELTDOWN_CUSTOMER_TIER="${STORY_MELTDOWN_CUSTOMER_TIER:-gold}"
STORY_MELTDOWN_PAYMENT_SCHEME="${STORY_MELTDOWN_PAYMENT_SCHEME:-FPS}"
STORY_MELTDOWN_PAYEE_NAME="${STORY_MELTDOWN_PAYEE_NAME:-Henry (grandson)}"
STORY_MELTDOWN_PAYMENT_REFERENCE="${STORY_MELTDOWN_PAYMENT_REFERENCE:-Pocket money}"
STORY_MELTDOWN_AMOUNT_MINOR="${STORY_MELTDOWN_AMOUNT_MINOR:-2500}"

story_audit_context_json() {
  printf '{"customer_id":"%s","customer_name":"%s","customer_tier":"%s","payment_scheme":"%s","payee_name":"%s","payment_reference":"%s","amount_minor_units":%s}' \
    "${STORY_MELTDOWN_CUSTOMER_ID}" \
    "${STORY_MELTDOWN_CUSTOMER_NAME}" \
    "${STORY_MELTDOWN_CUSTOMER_TIER}" \
    "${STORY_MELTDOWN_PAYMENT_SCHEME}" \
    "${STORY_MELTDOWN_PAYEE_NAME}" \
    "${STORY_MELTDOWN_PAYMENT_REFERENCE}" \
    "${STORY_MELTDOWN_AMOUNT_MINOR}"
}

emit_chaos_audit() {
  local action="$1"        # "inject" or "clear"
  local scenario="$2"      # bad-deploy-fraud, db-slow, ...
  local target_service="${3:-unknown}"
  local details_json="${4:-{}}"   # extra JSON object, may be empty

  local endpoint="${SPLUNK_HEC_ENDPOINT:-}"
  local token="${SPLUNK_HEC_TOKEN:-}"
  local index="${SPLUNK_HEC_INDEX:-nwpay_audit}"
  local actor="${ACTOR:-${USER:-unknown}}"

  if [[ -z "${endpoint}" || -z "${token}" ]]; then
    if command -v terraform >/dev/null 2>&1 && [[ -d "${TERRAFORM_DIR:-}" ]]; then
      endpoint="${endpoint:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw splunk_enterprise_hec_endpoint_public 2>/dev/null || true)}"
      token="${token:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw splunk_enterprise_hec_token_scripts 2>/dev/null || true)}"
    fi
  fi

  if [[ -z "${endpoint}" || -z "${token}" || "${endpoint}" == "null" || "${token}" == "null" ]]; then
    return 0
  fi

  local timestamp event_id payload
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  event_id="chaos-$(date -u +%s)-$$"

  # Build the inner event body via printf so embedded values are
  # JSON-escaped at field boundaries (no embedded user input here, but
  # codeguard-0-logging requires we never concatenate raw inputs into a
  # JSON string).
  payload="$(cat <<EOF
{"@timestamp":"${timestamp}","event_type":"chaos","scenario":"${scenario}","target_service":"${target_service}","actor":"${actor}","action":"${action}","event_id":"${event_id}","details":${details_json}}
EOF
)"

  local insecure_arg=""
  if [[ "${SPLUNK_HEC_INSECURE:-1}" == "1" ]]; then
    insecure_arg="-k"
  fi

  curl ${insecure_arg} -fsS \
    -m 5 \
    -H "Authorization: Splunk ${token}" \
    -H "Content-Type: application/json" \
    --data-binary "$(printf '{"event":%s,"sourcetype":"nwpay:chaos","index":"%s","time":%s}\n' "${payload}" "${index}" "$(date -u +%s)")" \
    "${endpoint}" >/dev/null 2>&1 || true
}

# Default values (the same numbers the Helm chart applies on first deploy).
DEFAULT_FRAUD_ERROR_RATE="0.02"
DEFAULT_SANCTIONS_HIT_RATE="0.97"
DEFAULT_SWIFT_ERROR_RATE="0.05"
DEFAULT_DB_LATENCY_MS="0"
DEFAULT_CPU_REGRESSION="false"
# Baseline tier throttleProb maps - mirror helm/values.yaml tierBehaviour
# so `recover` cleanly returns the gateway to a Bronze=0 / Silver=0 /
# Gold=0 baseline. If you change values.yaml, update these too.
DEFAULT_TIER_THROTTLE_PROB="bronze:0.0,silver:0.0,gold:0.0"
DEFAULT_TIER_FRAUD_FAST_PATH_PROB="bronze:0.0,silver:0.2,gold:0.6"

# Override-able incident magnitudes.
FRAUD_ERROR_RATE="${FRAUD_ERROR_RATE:-0.20}"
SWIFT_ERROR_RATE="${SWIFT_ERROR_RATE:-0.30}"
COLD_CACHE_HIT_RATE="${COLD_CACHE_HIT_RATE:-0.40}"
DB_LATENCY_MS="${DB_LATENCY_MS:-200}"
TIER_THROTTLE_RATE="${TIER_THROTTLE_RATE:-0.30}"
KAFKA_DEPLOYMENT="${KAFKA_DEPLOYMENT:-kafka}"
KAFKA_DOWN_WAIT_S="${KAFKA_DOWN_WAIT_S:-180}"

# payment-meltdown orchestrator knobs.
# We default the act-1 latency to 400 ms (vs 200 ms for the standalone
# db-slow scenario) because at 400 ms the SPA submit-button spinner is
# *visibly* longer than the baseline ~80 ms gateway round-trip, which
# is what makes the session-replay step land for the audience. 200 ms
# is detectable in APM but easy to miss with the naked eye on the SPA.
MELTDOWN_DB_LATENCY_MS="${MELTDOWN_DB_LATENCY_MS:-400}"
MELTDOWN_ACT1_S="${MELTDOWN_ACT1_S:-240}"
MELTDOWN_ACT2_S="${MELTDOWN_ACT2_S:-120}"
MELTDOWN_AUTORECOVER="${MELTDOWN_AUTORECOVER:-1}"
MELTDOWN_POSTGRES_DEPLOY="${MELTDOWN_POSTGRES_DEPLOY:-postgres}"

KNOWN_TIERS=("bronze" "silver" "gold")

usage() {
  cat <<EOF
Usage: $(basename "$0") <subcommand>

Subcommands:
  bad-deploy-fraud         Bump fraud-detection-service ERROR_RATE to ${FRAUD_ERROR_RATE}.
                           Watch: SWIFT error-rate detector, p99 SLO detector.
  swift-counterparty-flap  Bump swift-network ERROR_RATE to ${SWIFT_ERROR_RATE}.
                           Watch: SWIFT error-rate detector, error-rate-by-country chart.
  cache-cold               Drop sanctions-aml-service CACHE_HIT_RATE to ${COLD_CACHE_HIT_RATE}.
                           Watch: sanctions cache miss-rate detector, cache-hit-ratio chart.
  db-slow                  Inject ${DB_LATENCY_MS}ms latency into ledger-service Postgres queries.
                           Watch: payment-init p99 SLO detector, AlwaysOn flame graphs.
  fraud-cpu-regression     Swap fraud-detection-service feature extractor from O(N) to O(N^2).
                           Same external behaviour, ~30x more CPU per request. Watch: APM
                           AlwaysOn Profiling diff view - a brand-new tower under
                           _extract_features_pairwise appears that's absent from the baseline.
  inject-tier-throttle TIER  Bump api-gateway TIER_THROTTLE_PROB so requests with
                             customer.tier=TIER are throttled at ${TIER_THROTTLE_RATE}.
                             TIER must be one of: ${KNOWN_TIERS[*]}.
                             Watch: '[NatWest demo] Bronze tier decline rate' detector,
                             'Decline + throttle rate by customer tier' chart, RUM page
                             error count for the matching persona in the SPA.
  clear-tier-throttle      Reset api-gateway TIER_THROTTLE_PROB to the helm baseline
                           (every tier at 0.0).
  kafka-broker-down        Force-delete the kafka pod (deploy/${KAFKA_DEPLOYMENT}) to
                           simulate a broker outage. The Deployment controller
                           recreates the pod within ~30-60s; while it's gone,
                           expect the L4 nwpay_l4_kafka KPIs "Kafka brokers
                           online" + "Kafka active controllers" to drop to 0,
                           "Kafka offline partitions" to spike, and the
                           settlement-service consumer lag to grow. KPIs
                           auto-clear once the new pod is Ready, so no
                           recovery action is required (waits up to
                           ${KAFKA_DOWN_WAIT_S}s and emits a 'clear' audit).
  payment-meltdown         End-to-end "Postgres meltdown" story for showcasing
                           the full RUM (+ session replay) -> APM (+ traces
                           and metrics) -> Splunk Platform logs -> Postgres
                           DBM correlation. Two acts:
                             ACT 1 (~${MELTDOWN_ACT1_S}s): inject db-slow with
                               DB_LATENCY_MS=${MELTDOWN_DB_LATENCY_MS}. The new repo.chaosPgSleep()
                               makes this a REAL slow Postgres query, so
                               pg_stat_statements, APM Database Query
                               Performance, and the nwpay_l4_postgres ITSI
                               KPIs all move (the old Java sleep didn't).
                             ACT 2 (~${MELTDOWN_ACT2_S}s): scale deploy/${MELTDOWN_POSTGRES_DEPLOY} to 0.
                               Payments fail with PSQLException (5xx at the
                               gateway); RUM page-error count + rage clicks
                               spike; ITSI Postgres KPIs go red.
                             RECOVER: when MELTDOWN_AUTORECOVER=1 (default),
                               postgres is scaled back to 1 and db latency
                               is cleared. Set MELTDOWN_AUTORECOVER=0 to
                               leave the cluster broken for follow-up
                               investigation.
                           See docs/customer/story-rum-apm-postgres.md for
                           the click-by-click talk track.
  apm-topology-repair      Re-wire Splunk APM peer.service edges and steady-state
                           replicas (fixes floating settlement/kafka/postgres nodes).
  recover                  Reset ALL of the above to baseline values.
  status                   Print the current incident-relevant env vars.
EOF
}

is_known_tier() {
  # Case-insensitive membership test against KNOWN_TIERS. Returns 0 on
  # match, 1 otherwise. Keeps the inject-tier-throttle UX forgiving of
  # "Bronze" vs "bronze" without leaking a downstream error.
  #
  # `local known` is important: without it the loop variable would leak
  # back into the caller's scope and clobber its own loop iterator.
  local needle known
  needle="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  for known in "${KNOWN_TIERS[@]}"; do
    [[ "${known}" == "${needle}" ]] && return 0
  done
  return 1
}

set_env() {
  # Wrapper around kubectl set env that:
  #  - logs what it's about to do (so the demo flow is narratable)
  #  - waits for the rollout to complete so the next subcommand has a
  #    clean baseline rather than racing the previous restart.
  local deploy="$1"; shift
  log "set env on deploy/${deploy}: $*"
  kubectl -n "${NS}" set env "deploy/${deploy}" "$@" >/dev/null
  kubectl -n "${NS}" rollout status "deploy/${deploy}" --timeout=120s
}

cmd_bad_deploy_fraud() {
  log "INCIDENT bad-deploy-fraud: ERROR_RATE=${FRAUD_ERROR_RATE} on fraud-detection-service"
  set_env fraud-detection-service "ERROR_RATE=${FRAUD_ERROR_RATE}"
  emit_chaos_audit "inject" "bad-deploy-fraud" "fraud-detection-service" \
    "{\"error_rate\":${FRAUD_ERROR_RATE}}"
  log "expect detector '[NatWest demo] SWIFT error rate' to fire within ~3 minutes"
}

cmd_swift_counterparty_flap() {
  log "INCIDENT swift-counterparty-flap: ERROR_RATE=${SWIFT_ERROR_RATE} on swift-network"
  set_env swift-network "ERROR_RATE=${SWIFT_ERROR_RATE}"
  emit_chaos_audit "inject" "swift-counterparty-flap" "swift-network" \
    "{\"error_rate\":${SWIFT_ERROR_RATE}}"
  log "expect detector '[NatWest demo] SWIFT error rate' to fire within ~3 minutes"
}

cmd_cache_cold() {
  log "INCIDENT cache-cold: CACHE_HIT_RATE=${COLD_CACHE_HIT_RATE} on sanctions-aml-service"
  set_env sanctions-aml-service "CACHE_HIT_RATE=${COLD_CACHE_HIT_RATE}"
  emit_chaos_audit "inject" "cache-cold" "sanctions-aml-service" \
    "{\"cache_hit_rate\":${COLD_CACHE_HIT_RATE}}"
  log "expect detector '[NatWest demo] sanctions cache miss rate' to fire within ~5 minutes"
}

cmd_db_slow() {
  log "INCIDENT db-slow: DB_LATENCY_MS=${DB_LATENCY_MS} on ledger-service"
  set_env ledger-service "DB_LATENCY_MS=${DB_LATENCY_MS}"
  emit_chaos_audit "inject" "db-slow" "ledger-service" \
    "{\"db_latency_ms\":${DB_LATENCY_MS},\"customer_id\":\"${STORY_MELTDOWN_CUSTOMER_ID}\",\"customer_name\":\"${STORY_MELTDOWN_CUSTOMER_NAME}\",\"customer_tier\":\"${STORY_MELTDOWN_CUSTOMER_TIER}\",\"payment_scheme\":\"${STORY_MELTDOWN_PAYMENT_SCHEME}\"}"
  log "expect detector '[NatWest demo] payment-initiation p99 latency SLO' to fire within ~2 minutes"
}

cmd_fraud_cpu_regression() {
  # Bad-deploy pathology: the fraud team shipped a "smarter" feature
  # extractor whose inner loop is quadratic in the feature vector. Same
  # external behaviour, dramatically higher CPU. The story:
  #   1) APM Service Health: fraud-detection-service p99 starts climbing.
  #   2) AlwaysOn Profiling diff (build before vs build after the flip):
  #      _extract_features_pairwise is a brand-new tower in the flame
  #      graph - that's the regression, line-of-code precise.
  #   3) Recover by setting CPU_REGRESSION_ENABLED=false.
  log "INCIDENT fraud-cpu-regression: CPU_REGRESSION_ENABLED=true on fraud-detection-service"
  set_env fraud-detection-service "CPU_REGRESSION_ENABLED=true"
  emit_chaos_audit "inject" "fraud-cpu-regression" "fraud-detection-service" \
    '{"cpu_regression":true}'
  log "expect fraud-detection-service p99 to climb within ~1 minute. AlwaysOn Profiling"
  log "diff view will show _extract_features_pairwise as a new flame-graph tower."
}

cmd_inject_tier_throttle() {
  # Build a one-tier-hot map (e.g. "bronze:0.30,silver:0.0,gold:0.0") and
  # set it on api-gateway. We only ever toggle TIER_THROTTLE_PROB on the
  # gateway because that is the only service that consults it - keeping
  # the env-var blast radius small avoids side-effects in the chain.
  local tier="${1:-}"
  if ! is_known_tier "${tier}"; then
    log "ERROR: inject-tier-throttle requires a tier (one of: ${KNOWN_TIERS[*]})"
    exit 2
  fi
  tier="$(printf '%s' "${tier}" | tr '[:upper:]' '[:lower:]')"
  local parts=() known
  for known in "${KNOWN_TIERS[@]}"; do
    if [[ "${known}" == "${tier}" ]]; then
      parts+=("${known}:${TIER_THROTTLE_RATE}")
    else
      parts+=("${known}:0.0")
    fi
  done
  local map
  map="$(IFS=,; echo "${parts[*]}")"
  log "INCIDENT inject-tier-throttle: tier=${tier} prob=${TIER_THROTTLE_RATE}"
  set_env api-gateway "TIER_THROTTLE_PROB=${map}"
  emit_chaos_audit "inject" "tier-throttle" "api-gateway" \
    "{\"tier\":\"${tier}\",\"throttle_rate\":${TIER_THROTTLE_RATE}}"
  log "expect detector '[NatWest demo] Bronze tier decline rate' to fire within ~3 minutes (if tier=bronze)"
  log "every other tier should remain at 0% decline - that's the story"
}

cmd_clear_tier_throttle() {
  log "RECOVERY clear-tier-throttle: reset api-gateway TIER_THROTTLE_PROB=${DEFAULT_TIER_THROTTLE_PROB}"
  set_env api-gateway "TIER_THROTTLE_PROB=${DEFAULT_TIER_THROTTLE_PROB}"
  emit_chaos_audit "clear" "tier-throttle" "api-gateway" "{}"
}

cmd_kafka_broker_down() {
  # Force-delete the broker pod to simulate an unplanned outage. We target
  # the pod through the Deployment's label selector instead of hard-coding
  # a pod name so the script remains correct if the ReplicaSet hash rolls.
  # Grace period 0 ensures the pod is gone immediately rather than draining
  # cleanly - the point is to simulate a crash, not a graceful shutdown.
  #
  # The Deployment controller recreates the pod within seconds. While the
  # broker is unreachable:
  #   * settlement-service consumer reconnects loop, lag grows
  #   * payment-initiation-service producer reconnects loop, but spans show
  #     messaging.failed_attempts > 0 (Splunk APM error rate)
  #   * JMX exporter on :5556 goes unreachable, so the kbs_kafka_health
  #     metrics decay to coalesce(... ,0) within one 1m bin
  #   * ITSI L4 nwpay_l4_kafka rolls Critical (brokers_online=0,
  #     active_controllers=0, offline_partitions>0)
  #
  # We wait up to KAFKA_DOWN_WAIT_S for the new pod to be Ready, then emit
  # a 'clear' audit event so Episode Review shows a clean inject/clear pair
  # rather than an orphan inject. If the pod doesn't come back in time we
  # log a WARN and exit non-zero so this script can be safely chained.
  log "INCIDENT kafka-broker-down: force-deleting pod for deploy/${KAFKA_DEPLOYMENT} in ns ${NS}"
  local pods
  pods="$(kubectl -n "${NS}" get pods -l "app.kubernetes.io/name=${KAFKA_DEPLOYMENT}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${pods}" ]]; then
    log "ERROR: no pods matched selector app.kubernetes.io/name=${KAFKA_DEPLOYMENT} in ns ${NS}"
    exit 2
  fi

  # Emit BEFORE the delete so the audit timeline shows the operator action
  # at the moment of intent, even if the kubectl call hangs / fails part way.
  emit_chaos_audit "inject" "kafka-broker-down" "${KAFKA_DEPLOYMENT}" \
    "{\"namespace\":\"${NS}\",\"deployment\":\"${KAFKA_DEPLOYMENT}\"}"

  kubectl -n "${NS}" delete pod ${pods} --grace-period=0 --force --wait=false >/dev/null
  log "deleted pods: ${pods}"
  log "waiting up to ${KAFKA_DOWN_WAIT_S}s for the Deployment to bring kafka back"

  local waited=0 step=5
  while (( waited < KAFKA_DOWN_WAIT_S )); do
    if kubectl -n "${NS}" rollout status "deploy/${KAFKA_DEPLOYMENT}" --timeout=10s >/dev/null 2>&1; then
      log "kafka is back: deploy/${KAFKA_DEPLOYMENT} rollout complete after ~${waited}s"
      emit_chaos_audit "clear" "kafka-broker-down" "${KAFKA_DEPLOYMENT}" \
        "{\"namespace\":\"${NS}\",\"deployment\":\"${KAFKA_DEPLOYMENT}\",\"down_seconds\":${waited}}"
      log "ITSI nwpay_l4_kafka KPIs should clear within the next 1-2 mstats bins (~1-3 min)"
      return 0
    fi
    sleep "${step}"
    waited=$(( waited + step ))
  done

  warn "kafka did not return Ready within ${KAFKA_DOWN_WAIT_S}s; check 'kubectl -n ${NS} describe deploy/${KAFKA_DEPLOYMENT}'"
  emit_chaos_audit "stuck" "kafka-broker-down" "${KAFKA_DEPLOYMENT}" \
    "{\"namespace\":\"${NS}\",\"deployment\":\"${KAFKA_DEPLOYMENT}\",\"waited_seconds\":${waited}}"
  exit 1
}

cmd_payment_meltdown() {
  # Orchestrated two-act story: db-slow (real Postgres pg_sleep) -> postgres
  # scale-to-zero -> recover. Designed so the presenter clicks ONE button
  # and gets the full RUM/session-replay -> APM (traces + metrics + DB Query
  # Performance) -> Splunk Platform logs -> Postgres DBM walkthrough.
  #
  # The audit trail emits a synthetic `story_id` shared by all three
  # chaos-audit events so the SIEM correlation searches can stitch the
  # two acts back into a single Episode in ITSI Episode Review.
  #
  # Pacing is operator-tunable via MELTDOWN_ACT1_S / MELTDOWN_ACT2_S so a
  # 5-minute slot can `MELTDOWN_ACT1_S=90 MELTDOWN_ACT2_S=60 scripts/...`
  # without code edits. The defaults (240s + 120s) match the
  # docs/customer/story-rum-apm-postgres.md talk track.
  local story_id="meltdown-$(date -u +%s)-$$"
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

  log "STORY payment-meltdown started: story_id=${story_id} (act1=${MELTDOWN_ACT1_S}s, act2=${MELTDOWN_ACT2_S}s, autorecover=${MELTDOWN_AUTORECOVER})"

  # ---- ACT 1: db-slow with the new Postgres-side pg_sleep ----------------
  log "ACT 1/2 payment-meltdown: DB_LATENCY_MS=${MELTDOWN_DB_LATENCY_MS} on ledger-service (real Postgres pg_sleep query)"
  set_env ledger-service "DB_LATENCY_MS=${MELTDOWN_DB_LATENCY_MS}"
  emit_chaos_audit "inject" "payment-meltdown" "ledger-service" \
    "{\"act\":1,\"story_id\":\"${story_id}\",\"db_latency_ms\":${MELTDOWN_DB_LATENCY_MS},\"started_at\":\"${started_at}\",\"customer_id\":\"${STORY_MELTDOWN_CUSTOMER_ID}\",\"customer_name\":\"${STORY_MELTDOWN_CUSTOMER_NAME}\",\"customer_tier\":\"${STORY_MELTDOWN_CUSTOMER_TIER}\",\"payment_scheme\":\"${STORY_MELTDOWN_PAYMENT_SCHEME}\",\"payee_name\":\"${STORY_MELTDOWN_PAYEE_NAME}\",\"payment_reference\":\"${STORY_MELTDOWN_PAYMENT_REFERENCE}\",\"amount_minor_units\":${STORY_MELTDOWN_AMOUNT_MINOR}}"

  log "WATCH (ACT 1) - SPA: log in as Margaret (Gold), FPS £25 to Henry — submit and watch spinner"
  log "WATCH (ACT 1) - RUM Sessions: filter enduser.id=${STORY_MELTDOWN_CUSTOMER_ID} -> session replay submit wait"
  log "WATCH (ACT 1) - APM service map: ledger-service red, postgres-inferred edge p95 climbing"
  log "WATCH (ACT 1) - APM Database Query Performance: SELECT pg_sleep(\$1) appears in top-N by total time"
  log "WATCH (ACT 1) - ITSI nwpay_l4_postgres: node turns red (JDBC pool in use + pending/timeouts KPIs)"
  log "WATCH (ACT 1) - Log Observer Connect: any slow trace -> 'Logs for this trace' -> jdbc.io.duration log line"
  log "dwelling ${MELTDOWN_ACT1_S}s in ACT 1 so the audience can walk every surface above"
  sleep "${MELTDOWN_ACT1_S}"

  # ---- ACT 2: postgres outage --------------------------------------------
  log "ACT 2/2 payment-meltdown: scaling deploy/${MELTDOWN_POSTGRES_DEPLOY} to 0 in ns ${NS}"
  if ! kubectl -n "${NS}" get deploy "${MELTDOWN_POSTGRES_DEPLOY}" >/dev/null 2>&1; then
    log "ERROR: deploy/${MELTDOWN_POSTGRES_DEPLOY} not found in ns ${NS}; abandoning ACT 2 and recovering ACT 1"
    set_env ledger-service "DB_LATENCY_MS=${DEFAULT_DB_LATENCY_MS}"
    emit_chaos_audit "clear" "payment-meltdown" "ledger-service" \
      "{\"act\":1,\"story_id\":\"${story_id}\",\"reason\":\"act2_target_missing\"}"
    exit 2
  fi
  kubectl -n "${NS}" scale "deploy/${MELTDOWN_POSTGRES_DEPLOY}" --replicas=0 >/dev/null
  emit_chaos_audit "inject" "payment-meltdown" "${MELTDOWN_POSTGRES_DEPLOY}" \
    "{\"act\":2,\"story_id\":\"${story_id}\",\"action\":\"scale_to_zero\",\"customer_id\":\"${STORY_MELTDOWN_CUSTOMER_ID}\",\"customer_name\":\"${STORY_MELTDOWN_CUSTOMER_NAME}\",\"payment_scheme\":\"${STORY_MELTDOWN_PAYMENT_SCHEME}\"}"

  log "WATCH (ACT 2) - SPA: Submit now fails. Open RUM Sessions -> rage-click cluster on the latest session"
  log "WATCH (ACT 2) - APM service map: ledger-service error rate spikes; postgres edge goes red/missing"
  log "WATCH (ACT 2) - APM trace: pick any failed ledger trace, JDBC span carries 'Connection refused'"
  log "WATCH (ACT 2) - Splunk Platform: index=main sourcetype=kube:container:service \"org.postgresql.util.PSQLException\""
  log "WATCH (ACT 2) - ITSI Episode Review: 'NatWest payments' episode should now show ACT 1 + ACT 2 notables stitched by story_id"
  log "dwelling ${MELTDOWN_ACT2_S}s in ACT 2"
  sleep "${MELTDOWN_ACT2_S}"

  # ---- RECOVER -----------------------------------------------------------
  if [[ "${MELTDOWN_AUTORECOVER}" == "1" ]]; then
    log "RECOVER payment-meltdown: scaling deploy/${MELTDOWN_POSTGRES_DEPLOY} back to 1 and clearing DB_LATENCY_MS"
    kubectl -n "${NS}" scale "deploy/${MELTDOWN_POSTGRES_DEPLOY}" --replicas=1 >/dev/null
    kubectl -n "${NS}" rollout status "deploy/${MELTDOWN_POSTGRES_DEPLOY}" --timeout=120s
    set_env ledger-service "DB_LATENCY_MS=${DEFAULT_DB_LATENCY_MS}"
    emit_chaos_audit "clear" "payment-meltdown" "multi" \
      "{\"act\":\"recover\",\"story_id\":\"${story_id}\"}"
    log "payment-meltdown story complete. SPA submit should succeed again within ~60s."
  else
    warn "MELTDOWN_AUTORECOVER=0: leaving postgres scaled to 0 and DB_LATENCY_MS=${MELTDOWN_DB_LATENCY_MS}."
    warn "Recover manually with:  scripts/incident.sh recover && kubectl -n ${NS} scale deploy/${MELTDOWN_POSTGRES_DEPLOY} --replicas=1"
  fi
}

cmd_recover() {
  log "RECOVERY: resetting fraud, swift, sanctions cache, ledger DB latency, CPU regression, and tier throttling to baseline"
  set_env fraud-detection-service     "ERROR_RATE=${DEFAULT_FRAUD_ERROR_RATE}" "CPU_REGRESSION_ENABLED=${DEFAULT_CPU_REGRESSION}"
  set_env swift-network               "ERROR_RATE=${DEFAULT_SWIFT_ERROR_RATE}"
  set_env sanctions-aml-service       "CACHE_HIT_RATE=${DEFAULT_SANCTIONS_HIT_RATE}"
  set_env ledger-service              "DB_LATENCY_MS=${DEFAULT_DB_LATENCY_MS}"
  set_env api-gateway                 "TIER_THROTTLE_PROB=${DEFAULT_TIER_THROTTLE_PROB}"

  # payment-meltdown act 2 leaves postgres scaled to 0 if autorecover is
  # off (or if the orchestrator was Ctrl-C'd mid-act-2). Defensively
  # restore it here so an operator typing `recover` always lands back on
  # a fully-working baseline. Idempotent: if the deployment already has
  # >=1 replica we just no-op.
  if kubectl -n "${NS}" get deploy "${MELTDOWN_POSTGRES_DEPLOY}" >/dev/null 2>&1; then
    local pg_replicas
    pg_replicas="$(kubectl -n "${NS}" get deploy "${MELTDOWN_POSTGRES_DEPLOY}" \
                     -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    if [[ "${pg_replicas}" -lt 1 ]]; then
      log "RECOVERY: deploy/${MELTDOWN_POSTGRES_DEPLOY} is scaled to ${pg_replicas}; restoring to 1"
      kubectl -n "${NS}" scale "deploy/${MELTDOWN_POSTGRES_DEPLOY}" --replicas=1 >/dev/null
      kubectl -n "${NS}" rollout status "deploy/${MELTDOWN_POSTGRES_DEPLOY}" --timeout=120s
      emit_chaos_audit "clear" "payment-meltdown" "${MELTDOWN_POSTGRES_DEPLOY}" \
        "{\"act\":\"recover\",\"reason\":\"defensive_postgres_restore\"}"
    fi
  fi

  for s in bad-deploy-fraud swift-counterparty-flap cache-cold db-slow fraud-cpu-regression payment-meltdown; do
    emit_chaos_audit "clear" "${s}" "multi" "{}"
  done

  log "RECOVERY: repairing Splunk APM service-map topology (peer.service + replicas)"
  apm_topology_repair

  log "all incidents cleared. Detectors should clear after their \`lasting\` window expires."
}

cmd_status() {
  for d in fraud-detection-service swift-network sanctions-aml-service ledger-service api-gateway; do
    printf '\n--- %s ---\n' "${d}"
    kubectl -n "${NS}" set env "deploy/${d}" --list 2>/dev/null \
      | grep -E '^(ERROR_RATE|CACHE_HIT_RATE|DB_LATENCY_MS|TAIL_LATENCY_RATE|CPU_REGRESSION_ENABLED|TIER_THROTTLE_PROB|TIER_FRAUD_FAST_PATH_PROB)=' \
      || echo "  (none of the incident vars are set)"
  done
}

main() {
  local sub="${1:-}"
  case "${sub}" in
    bad-deploy-fraud)        shift; cmd_bad_deploy_fraud "$@" ;;
    swift-counterparty-flap) shift; cmd_swift_counterparty_flap "$@" ;;
    cache-cold)              shift; cmd_cache_cold "$@" ;;
    db-slow)                 shift; cmd_db_slow "$@" ;;
    fraud-cpu-regression)    shift; cmd_fraud_cpu_regression "$@" ;;
    inject-tier-throttle)    shift; cmd_inject_tier_throttle "$@" ;;
    clear-tier-throttle)     shift; cmd_clear_tier_throttle "$@" ;;
    kafka-broker-down)       shift; cmd_kafka_broker_down "$@" ;;
    payment-meltdown)        shift; cmd_payment_meltdown "$@" ;;
  recover)                 shift; cmd_recover "$@" ;;
  apm-topology-repair)     shift; apm_topology_repair "$@" ;;
  status)                  shift; cmd_status "$@" ;;
    -h|--help|"")            usage ;;
    *)                       usage; exit 2 ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# scripts/00-bootstrap.sh
#
# Wraps the eleven numbered scripts that build the demo into a single,
# narratable run. Each step is already idempotent on its own (see the
# headers of 00..10); this wrapper adds:
#
#   * progress markers — "[3/6] (02-install-collector.sh) ..." prefix on
#     every line so a presenter can spot where things stopped if the run
#     is interrupted.
#   * --skip / --only / --from filters so a half-built cluster only re-
#     runs the bits that need re-running.
#   * --with-itsi / --with-thousandeyes toggles for the optional tiers.
#   * A clean resume hint on failure (the exact one-shot command to pick
#     up where the run left off).
#
# Usage:
#   scripts/00-bootstrap.sh                      # core demo (00..05 + 05b)
#   scripts/00-bootstrap.sh --with-itsi          # + 06..07
#   scripts/00-bootstrap.sh --with-thousandeyes  # + 08..10 (needs secrets/thousandeyes.env)
#   scripts/00-bootstrap.sh --with-metricsets    # + 05d  (needs SPLUNK_API_TOKEN; advisory only)
#   scripts/00-bootstrap.sh --from 02            # resume from step 02
#   scripts/00-bootstrap.sh --only 02,03         # just these two
#   scripts/00-bootstrap.sh --skip 04            # everything except 04
#   scripts/00-bootstrap.sh --dry-run            # print the plan, run nothing
#   scripts/00-bootstrap.sh --no-preflight       # skip the trailing 00-preflight.sh
#
# Exit codes:
#   0   - every selected step succeeded and preflight passed
#   1   - one of the underlying scripts failed
#   2   - bad invocation (unknown flag, contradicting selectors, ...)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Steps catalogue. The numeric prefix matches the filename so the operator
# can quickly cross-reference the script being driven. Each entry is
# stored as id|script|description; ids are stable so --skip/--only/--from
# survive a script rename.
# ---------------------------------------------------------------------------
CORE_STEPS=(
  "00:00-provision.sh:Provision EKS + ECR + Splunk Enterprise EC2 (Terraform)"
  "01:01-build-push.sh:Build + push the 24-service image to ECR"
  "02:02-install-collector.sh:Install the Splunk OTel Collector chart"
  "03:03-deploy.sh:Helm install the natwest-payments chart (24 services)"
  "04:04-start-traffic.sh:Start the traffic generator"
  "05:05-deploy-frontend.sh:Build + deploy the SPA"
  "05b:05b-frontend-public-proxy.sh:Stand up the public nginx proxy on the Splunk EC2"
)
ITSI_STEPS=(
  "06:06-install-itsi.sh:Install ITSI + PSC + NFR licence on Splunk Enterprise"
  "07:07-itsi-bootstrap.sh:Bootstrap the ITSI service tree + glass tables"
)
TE_STEPS=(
  "08:08-configure-thousandeyes.sh:Create the 6 ThousandEyes synthetic tests"
  "09:09-configure-splunk-te-inputs.sh:Provision the Splunk index + 4 HEC tokens for the TE add-on"
  "10:10-extend-itsi-with-te.sh:Add the L2 Digital Customer Experience tier"
)
# Optional, opt-in via --with-metricsets. Advisory only - the demo runs
# without these MetricSets, the Service Map breakdown / Tag Spotlight
# pivots just won't surface our custom span tags. See
# docs/operations/metricsets.md for the manual UI fallback.
METRICSETS_STEPS=(
  "05d:05d-promote-metricsets.sh:Promote business span tags to APM MetricSets (best-effort, advisory)"
)

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
WITH_ITSI=0
WITH_TE=0
WITH_METRICSETS=0
DRY_RUN=0
SKIP_PREFLIGHT=0
ONLY_LIST=""
SKIP_LIST=""
FROM_STEP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-itsi)        WITH_ITSI=1; shift ;;
    --with-thousandeyes) WITH_TE=1; shift ;;
    --with-metricsets)  WITH_METRICSETS=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --no-preflight)     SKIP_PREFLIGHT=1; shift ;;
    --from)             FROM_STEP="${2:-}"; shift 2 ;;
    --only)             ONLY_LIST="${2:-}"; shift 2 ;;
    --skip)             SKIP_LIST="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "00-bootstrap.sh: unknown flag '$1'" >&2
      exit 2
      ;;
  esac
done

# Mutually-exclusive selector validation. --only and --from are both ways
# of trimming the plan; combining them is ambiguous, refuse loudly.
if [[ -n "${ONLY_LIST}" && -n "${FROM_STEP}" ]]; then
  echo "00-bootstrap.sh: --only and --from are mutually exclusive" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Assemble the plan from the catalogue.
# ---------------------------------------------------------------------------
# Bash 3.2 (macOS default) doesn't support namerefs (`local -n`), so the
# plan is assembled by iterating each catalogue array directly. The cost
# is a tiny amount of duplication for a substantial portability win
# (the demo's target is the operator's laptop, not a Linux CI box).
PLAN=()
for entry in "${CORE_STEPS[@]}"; do PLAN+=("${entry}"); done
if (( WITH_METRICSETS )); then
  for entry in "${METRICSETS_STEPS[@]}"; do PLAN+=("${entry}"); done
fi
if (( WITH_ITSI )); then
  for entry in "${ITSI_STEPS[@]}"; do PLAN+=("${entry}"); done
fi
if (( WITH_TE )); then
  for entry in "${TE_STEPS[@]}"; do PLAN+=("${entry}"); done
fi

# Convert the comma-separated --only / --skip into bash arrays for cheap
# membership checks below.
IFS=',' read -r -a ONLY_ARR <<<"${ONLY_LIST}"
IFS=',' read -r -a SKIP_ARR <<<"${SKIP_LIST}"

in_array() {
  # 1: needle, 2..N: haystack. Returns 0 on match.
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

selected_steps=()
seen_from=0
for entry in "${PLAN[@]}"; do
  id="${entry%%:*}"

  if [[ -n "${ONLY_LIST}" ]]; then
    in_array "${id}" "${ONLY_ARR[@]}" || continue
  fi

  if [[ -n "${FROM_STEP}" ]]; then
    if (( ! seen_from )); then
      [[ "${id}" == "${FROM_STEP}" ]] && seen_from=1 || continue
    fi
  fi

  if [[ -n "${SKIP_LIST}" ]]; then
    in_array "${id}" "${SKIP_ARR[@]}" && continue
  fi

  selected_steps+=("${entry}")
done

if [[ ${#selected_steps[@]} -eq 0 ]]; then
  echo "00-bootstrap.sh: no steps selected (check --only / --from / --skip)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Render the plan.
# ---------------------------------------------------------------------------
total="${#selected_steps[@]}"

log "demo bootstrap plan (${total} step$([[ ${total} -eq 1 ]] || echo s))"
i=0
for entry in "${selected_steps[@]}"; do
  i=$((i + 1))
  IFS=':' read -r id script desc <<<"${entry}"
  printf '  [%d/%d]  %-32s  %s\n' "${i}" "${total}" "${script}" "${desc}"
done

if (( DRY_RUN )); then
  log "dry-run: no commands executed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Execute each selected step. A failure prints the resume command and
# exits non-zero so CI / the operator know exactly what to re-run.
# ---------------------------------------------------------------------------
i=0
start_ts="$(date +%s)"

for entry in "${selected_steps[@]}"; do
  i=$((i + 1))
  IFS=':' read -r id script desc <<<"${entry}"
  step_path="${SCRIPT_DIR}/${script}"

  if [[ ! -x "${step_path}" ]]; then
    fail "step ${id} (${script}) is missing or non-executable: ${step_path}"
  fi

  step_start="$(date +%s)"
  log "[${i}/${total}] start ${script}  ${C_DIM:-}(${desc})${C_RESET:-}"

  # We deliberately do NOT pipe stdout/stderr through tee/sed: the child
  # scripts already use lib.sh's log/warn/fail which produce
  # human-readable, colourised output. Re-streaming through tee tends to
  # eat the colour codes and double the log lines under `set -x`.
  if ! "${step_path}"; then
    rc=$?
    step_end="$(date +%s)"
    warn "[${i}/${total}] FAIL ${script} after $((step_end - step_start))s (exit ${rc})"

    # Compute the resume command. Default: "--from <next-id>". When the
    # failure was on the last step, suggest re-running just that step
    # with --only so the operator doesn't have to type a no-op --from.
    if (( i < total )); then
      next_entry="${selected_steps[i]}"   # 0-indexed, so element i is the *next* step
      next_id="${next_entry%%:*}"
      resume_flag="--from ${next_id}"
    else
      resume_flag="--only ${id}"
    fi
    # Preserve the parent's selector flags so the resume actually picks
    # up where we left off rather than recomputing the catalogue.
    resume_args=()
    (( WITH_ITSI )) && resume_args+=("--with-itsi")
    (( WITH_TE   )) && resume_args+=("--with-thousandeyes")
    (( WITH_METRICSETS )) && resume_args+=("--with-metricsets")
    (( SKIP_PREFLIGHT )) && resume_args+=("--no-preflight")
    [[ -n "${SKIP_LIST}" ]] && resume_args+=("--skip" "${SKIP_LIST}")

    printf '\n%sResume with:%s\n  scripts/00-bootstrap.sh %s %s\n\n' \
      "${C_FAIL:-}" "${C_RESET:-}" \
      "${resume_args[*]}" "${resume_flag}"
    exit "${rc}"
  fi

  step_end="$(date +%s)"
  log "[${i}/${total}] done  ${script} in $((step_end - step_start))s"
done

end_ts="$(date +%s)"
log "all ${total} step(s) succeeded in $((end_ts - start_ts))s"

# ---------------------------------------------------------------------------
# Trailing preflight. Even when every step exited zero, some failure modes
# only show up at runtime (e.g. pod stuck CrashLoopBackOff after image
# pull). 00-preflight.sh has the truth.
# ---------------------------------------------------------------------------
if (( SKIP_PREFLIGHT )); then
  log "skipping trailing preflight (--no-preflight)"
  exit 0
fi

log "running scripts/00-preflight.sh for a final health check"
if "${SCRIPT_DIR}/00-preflight.sh"; then
  log "demo is ready — http://itsi.splunk-observability.com/"
else
  warn "preflight reported failures. The demo may still be partially usable; review the report above."
  exit 1
fi

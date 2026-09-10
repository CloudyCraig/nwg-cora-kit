#!/usr/bin/env bash
# Render the markdown customer deliverables under docs/customer/ into .docx
# (and optionally .pdf) using pandoc, so the customer can read them in the
# same format as the original assessment .docx.
#
# Why this exists:
#   - Markdown is the source of truth (lives in git, plays nice with code
#     review, easy to diff). The .docx artefacts are gitignored binary
#     renders the operator regenerates on demand.
#   - The customer received Rakesh Mottey's v1.0 assessment as a .docx; the
#     v1.1 demo-evidenced update needs to be deliverable in the same shape
#     so it can sit side-by-side with v1.0 in their workspace.
#
# Usage:
#   scripts/render-customer-docs.sh              # render every .md in docs/customer/ to .docx
#   scripts/render-customer-docs.sh --pdf        # ALSO emit .pdf (needs a LaTeX engine)
#   scripts/render-customer-docs.sh path/to.md   # render just one file
#
# Requirements:
#   - pandoc (brew install pandoc).
#   - For --pdf: a LaTeX engine (brew install --cask basictex or mactex).
#
# Output: <name>.docx (and <name>.pdf when --pdf) alongside each <name>.md.
#
# Safe to re-run: pandoc overwrites the output file atomically each time.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the repo root regardless of where this script was invoked from. We
# rely on git here because the script is shipped inside a git repo; if you
# vendor it elsewhere, replace this with a `dirname "$(readlink -f "$0")"`
# style discovery.
# ---------------------------------------------------------------------------
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
CUSTOMER_DIR="${REPO_ROOT}/docs/customer"

# ---------------------------------------------------------------------------
# Pre-flight: pandoc must be on PATH. Be loud about the install command
# rather than silently failing - this script is run interactively and a
# clean error message saves a support ticket.
# ---------------------------------------------------------------------------
if ! command -v pandoc >/dev/null 2>&1; then
  echo "ERROR: pandoc not found on PATH." >&2
  echo "Install with:  brew install pandoc" >&2
  exit 1
fi

WANT_PDF=0
TARGET_FILE=""

# ---------------------------------------------------------------------------
# Tiny arg parser. Two flags are supported and they're orthogonal:
#   --pdf            also emit PDF alongside DOCX
#   <path-to-md>     restrict to one file instead of all .md under docs/customer
# Anything else gets called out so a typo doesn't silently no-op.
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "${arg}" in
    --pdf) WANT_PDF=1 ;;
    -h|--help)
      sed -n '1,/^set -euo pipefail/p' "$0" | sed -n '/^#/p'
      exit 0
      ;;
    *)
      if [[ -f "${arg}" ]]; then
        TARGET_FILE="${arg}"
      else
        echo "ERROR: unknown arg or missing file: ${arg}" >&2
        exit 2
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Pick the file list. Default is every .md under docs/customer/ so adding
# a new markdown deliverable Just Works without editing this script.
# ---------------------------------------------------------------------------
if [[ -n "${TARGET_FILE}" ]]; then
  files=("${TARGET_FILE}")
else
  shopt -s nullglob
  files=("${CUSTOMER_DIR}"/*.md)
  shopt -u nullglob
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No markdown files found under ${CUSTOMER_DIR}." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Render each markdown to .docx (and .pdf when requested). Use GFM with
# pipe_tables because every customer doc in this folder uses GitHub-flavoured
# pipe tables. --standalone is required for valid .docx output.
# ---------------------------------------------------------------------------
for md in "${files[@]}"; do
  base="${md%.md}"
  title="$(grep -m1 '^# ' "${md}" | sed 's/^# //' || true)"
  if [[ -z "${title}" ]]; then
    # Fall back to the filename if the markdown has no top-level heading;
    # docx readers display the title in the file properties pane and we
    # want it populated.
    title="$(basename "${base}")"
  fi
  today="$(date +%Y-%m-%d)"

  echo "rendering ${md} -> ${base}.docx"
  pandoc \
    --from=gfm+pipe_tables \
    --to=docx \
    --standalone \
    --metadata=title:"${title}" \
    --metadata=date:"${today}" \
    --output="${base}.docx" \
    "${md}"

  if (( WANT_PDF == 1 )); then
    echo "rendering ${md} -> ${base}.pdf"
    pandoc \
      --from=gfm+pipe_tables \
      --to=pdf \
      --standalone \
      --metadata=title:"${title}" \
      --metadata=date:"${today}" \
      --output="${base}.pdf" \
      "${md}"
  fi
done

echo "done."

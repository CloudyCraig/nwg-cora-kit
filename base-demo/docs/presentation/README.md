# Presentation pack — NatWest Payment Platform demo

Three artefacts, in increasing operational detail:


| File                                                           | Audience                  | Use it when...                                                                                 |
| -------------------------------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------- |
| `[SLIDES.md](./SLIDES.md)`                                     | Live audience             | You need a deck on screen behind the live demo (or as a backup if Splunk is down).             |
| `[TALK_TRACK.md](./TALK_TRACK.md)`                             | Presenter                 | You're rehearsing or driving the demo — Tell-Show-Tell, Ask Beats, Objections, Champion Brief. |
| `[EXEC_DEMO_30MIN_TOPDOWN.md](./EXEC_DEMO_30MIN_TOPDOWN.md)`   | Presenter (C-level cut)   | You're running the 30-minute top-down exec flow — Glass Table → ITSI episode → APM root cause → live Madrid inject → RUM → SLO burn, with pre-flight and fallbacks. |
| `[../../scripts/run-of-show.md](../../scripts/run-of-show.md)` | Presenter at the keyboard | You want the exact commands and `kubectl` checks while you're driving.                         |


The deck and the talk track are deliberately **structurally aligned**:
each slide in `SLIDES.md` maps to one section in `TALK_TRACK.md`. Memorise
the slide titles; the talk track is the safety net.

---

## Render the deck

There are two paths. **Use the Splunk template path for any customer
deck.** The Marp path is kept as a fallback for fast in-browser preview
during content edits.

### Path A · Splunk template  (canonical, customer-ready)

We render the deck against the Splunk corporate PowerPoint template
(`splunk-deck-2026.pptx`) so it inherits the official master, fonts,
colours, footer, and segue layouts.

```bash
python3 scripts/generate-deck.py
# → docs/presentation/slides.pptx (engineer / bottom-up cut, default)

python3 scripts/generate-deck.py --profile exec-topdown
# → docs/presentation/slides-exec-topdown.pptx
#   (C-level 30-min top-down cut, aligned with EXEC_DEMO_30MIN_TOPDOWN.md)
```

The slide content lives declaratively in two SLIDES lists inside
`[scripts/generate-deck.py](../../scripts/generate-deck.py)`:
`ENGINEER_SLIDES` (default profile, aligned with `TALK_TRACK.md`) and
`EXEC_TOPDOWN_SLIDES` (aligned with `EXEC_DEMO_30MIN_TOPDOWN.md`).
Each entry names a layout from the template and supplies the
placeholder text + speaker notes. To preview every available layout
in the template (e.g. when adding a new slide type):

```bash
python3 scripts/generate-deck.py --list-layouts
```

Use a different template path or output destination:

```bash
python3 scripts/generate-deck.py \
  --template /path/to/another-corporate.pptx \
  --output   /tmp/preview.pptx

python3 scripts/generate-deck.py \
  --profile  exec-topdown \
  --template /path/to/another-corporate.pptx \
  --output   /tmp/exec-preview.pptx
```

### Screenshots (exec-topdown profile)

The exec-topdown deck auto-embeds UI screenshots when it finds them
under `docs/presentation/screenshots/`. Filenames must match the
fixed stems below (one PNG per slide). When a PNG is **present** the
generator switches that slide to a `bullets + picture` layout
inherited from the Splunk template; when **absent** the slide
gracefully falls back to text-only, so the deck always renders.

| Slide | Filename stem                          | Source                                      |
| ----- | -------------------------------------- | ------------------------------------------- |
| 3     | `slide-03-architecture`                | Architecture diagram (any source)           |
| 5     | `slide-05-overview-glass-table`        | ITSI Overview Glass Table                    |
| 6     | `slide-06-episode-review`              | ITSI Episode Review                          |
| 7     | `slide-07-apm-service-map`             | Splunk Observability APM service map        |
| 10    | `slide-10-rum-overview`                | Splunk Observability RUM overview            |
| 11    | `slide-11-glass-table-thousandeyes`    | Glass Table scrolled to ThousandEyes panels |
| 12    | `slide-12-slo-burn`                    | Glass Table scrolled to SLO burn panels     |

Capture against the live demo with the bundled Playwright driver:

```bash
# one-time setup
python3 -m venv .venv && .venv/bin/pip install python-pptx playwright python-dotenv
.venv/bin/python3 -m playwright install --with-deps chromium

# capture ITSI panels (slides 3, 5, 6, 11, 12) — uses
# TF_VAR_splunk_enterprise_admin_password from .env
.venv/bin/python3 scripts/capture-screenshots.py capture --only-surface enterprise

# Splunk Observability has SSO/MFA so we record cookies once,
# interactively (a real browser opens; complete SSO; press Enter)
.venv/bin/python3 scripts/capture-screenshots.py login \
  --surface observability --realm "$SPLUNK_REALM"
.venv/bin/python3 scripts/capture-screenshots.py capture --only-surface observability

# re-render the deck (auto-picks up whatever screenshots exist)
.venv/bin/python3 scripts/generate-deck.py --profile exec-topdown \
  --template /path/to/splunk-deck-2026.pptx
```

Panel URLs, viewport sizes, and wait selectors live in
`[scripts/lib/exec_topdown_screenshots.json](../../scripts/lib/exec_topdown_screenshots.json)`.
Captured PNGs are gitignored.

#### Tips & troubleshooting

**ITSI Glass Table URL.** The ITSI app expects
`/app/itsi/glass_table?savedGlassTableId=<key>&action=view`. Passing
`?id=<key>` or `?key=<key>` lands on an empty page that shows
*"Cannot view glass table. Details: Glass_table with id null not found."*
The capture config already uses the working query parameter — keep it in
sync if you copy URLs from the browser.

**ITSI admin password.** The capture script logs in as `admin` using
`$TF_VAR_splunk_enterprise_admin_password` (loaded from `.env`). If that
value drifts from the live instance the script's `enterprise auth:
still on login page after submit` error makes the mismatch obvious. To
re-seed the password to the Terraform default (`smartway`):

```bash
ssh -i terraform/splunk-enterprise.pem ec2-user@itsi.splunk-observability.com \
  'sudo systemctl stop Splunkd; \
   sudo mv /opt/splunk/etc/passwd /opt/splunk/etc/passwd.bak.$(date +%s); \
   echo -e "[user_info]\nUSERNAME = admin\nPASSWORD = smartway" \
     | sudo tee /opt/splunk/etc/system/local/user-seed.conf >/dev/null; \
   sudo chown splunk:splunk /opt/splunk/etc/system/local/user-seed.conf; \
   sudo chmod 600 /opt/splunk/etc/system/local/user-seed.conf; \
   sudo systemctl start Splunkd'
```

The reset is destructive for non-admin users (everything in the old
`passwd` is preserved at `passwd.bak.<ts>` if you need to merge entries
back). Splunk Web usually serves login within ~30 seconds; the capture
script will retry once the page is up.

**Splunk Observability login (one-time).** Cloud SSO/MFA cannot run
headless. Set `SPLUNK_REALM` (e.g. `eu0`) in `.env`, then:

```bash
.venv/bin/python3 scripts/capture-screenshots.py login \
  --surface observability --realm "$SPLUNK_REALM"
```

A real Chromium window opens. Complete SSO, return to the terminal,
press `Enter` — the session cookies land in `.playwright/observability-state.json`
(gitignored). Subsequent `capture --only-surface observability` runs
re-use that state until SSO expiry (typically 12 hours).

> **Why not Marp for the customer deck?** Marp emits its own theme
> and has no hook for consuming an external `.pptx` as a template,
> so the Splunk visual identity is unreachable from Marp. python-pptx
> opens the template *as the deck* and every new slide inherits its
> master / theme automatically.

### Path B · Marp  (preview only)

`SLIDES.md` is [Marp](https://marp.app/) Markdown — useful for fast
in-browser previews while the talk track is in flux. It will **not**
match the Splunk corporate look.

```bash
# HTML (fastest, no Chromium download)
npx --yes @marp-team/marp-cli@latest docs/presentation/SLIDES.md \
  --html -o docs/presentation/slides.html
open docs/presentation/slides.html

# Live preview while editing — `--server` requires a directory, not a
# single file (Marp serves an index of all .md inside it).
npx --yes @marp-team/marp-cli@latest docs/presentation/ \
  --watch --server
# → http://localhost:8080/  (then click SLIDES.md)
```

> **Tip.** Install the
> [Marp for VS Code](https://marketplace.visualstudio.com/items?itemName=marp-team.marp-vscode)
> extension and `SLIDES.md` previews live in the editor.

---

## Customise

The Splunk-templated deck (Path A) inherits all visual styling from
`splunk-deck-2026.pptx`. Customisation lives in two places:

1. **Slide content** — edit `ENGINEER_SLIDES` (default, bottom-up
   cut) or `EXEC_TOPDOWN_SLIDES` (30-min C-level cut) in
  `[scripts/generate-deck.py](../../scripts/generate-deck.py)`.
   Each entry is a `Slide(layout=..., placeholders={...}, notes=...)`
   record; placeholders are populated by index (run with
   `--list-layouts` to inspect available layouts and indices).
2. **Template / theme** — pass `--template /path/to/...pptx` to use a
  different corporate template. Layout names in the SLIDES lists
   must match layouts that exist in the template; missing layouts
   are flagged with an error rather than silently mis-rendering.

The Marp deck (Path B) has its own theme inside the `style:` block of
`SLIDES.md`. Edits there do not affect Path A.

---

## Variants you might need


| Variant                                 | How                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **30-minute standard**                  | Run the core flow in `TALK_TRACK.md`: full Act I + II.A/II.B/II.C + short II.D; skip optional beats.                                                                                                                                                                                                                                                                                                |
| **45-minute deep-dive**                 | Keep the 30-minute core, then add II.B.1 (trace waterfall) + II.C.1 (closed-loop ticketing), plus a short architecture aside after Slide 3.                                                                                                                                                                                                                                                         |
| **60-minute workshop**                  | Keep the 45-minute flow and add optional beats (AI assistant, AIOps clustering, WAN/BGP path visibility), then extend Q&A on customer-specific architecture.                                                                                                                                                                                                                                        |
| **Splunk-incumbent audience**           | Lead with Act I.3 (Logs in Context). Skip the LOC architecture explanation; the audience already runs the indexers.                                                                                                                                                                                                                                                                                 |
| **Greenfield audience (no Splunk yet)** | Lead with Act II.A (Service Map). Tease LOC at the end as "and your future log estate looks like this too."                                                                                                                                                                                                                                                                                         |
| **Async distribution**                  | Render `SLIDES.md` to PDF; pair with `TALK_TRACK.md` (the Champion Brief at the bottom is paste-ready for an internal email).                                                                                                                                                                                                                                                                       |
| **ITSI + ThousandEyes deep-dive**       | Add an Act III.D segment that pivots from RUM to the synthetic L2 "Digital Customer Experience" tier in ITSI. Story arc: a fired RUM detector + a green DCE tier = "this is real-user latency, not the bank being broken"; conversely a green RUM tile + red DCE tier = "we hear about this from a synthetic check before any real customer notices." See `[itsi/README.md](../../itsi/README.md)`. |


---

## Where to update numbers

If anything visible in the demo changes — RPS curve, scheme weights,
incident magnitudes — update the **same numbers in three places**:

1. The dashboard / detector configs (Splunk side).
2. `SLIDES.md` — slide bodies and tables.
3. `TALK_TRACK.md` — Tell sentences and Ask Beats.

A number that doesn't match the panel on screen breaks the spell.
Treat the deck and the talk track as an extension of the dashboard
data model.
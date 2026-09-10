# Hi Marc 👋

This repo is everything from the **AI-assistant layer** I added on top of your
payments demo, packaged so you can rebuild it from the ground up and make it
your own. Your original demo (payments services, chaos controller, traffic
generator, SPA) stays yours — this sits alongside it.

## What you end up with
A named AI banking assistant (mine was **"Cora"**) embedded in the SPA, whose
every conversation lights up:
- **Splunk AI Agent Monitoring** — agent registration, traces with full
  message content, token/latency/cost charts, LLM-as-a-judge evaluations
- **ITSI** — an "AI agents" service (request rate / hallucinations / cost
  KPIs), an agent entity with drilldowns, and the executive glass table
- **ThousandEyes** synthetics against the payment API
- A demo beat: arming the Madrid scenarios makes the assistant's traffic
  spike with hallucinated answers and a matching cost spike.

## Do this, in order
1. **Read `README.md`** — the build order. Steps 0 (org flags, LLM
   connection, the token recipe) decide success; everything else is mechanical.
2. **Copy `config/kit.env.example` → `config/kit.env`** and fill in your
   tokens (O11y, ThousandEyes, HEC, Anthropic). It's gitignored — keep it that way.
3. **Make it yours** — three env vars rename the assistant everywhere
   (`CORA_AGENT_NAME`, `CORA_AGENT_ID`, `CORA_BANK_NAME`); the SPA widget's
   display name is one file (`frontend/README.md` points at it); glass-table
   renaming/re-skinning is mapped in `itsi/RESKIN-NOTES.md`.
4. **Build up**: secrets → agent/collector/loadgen → check the agent appears
   in AI Agent Monitoring → frontend → dashboard script → ITSI script →
   TE script.
5. When something behaves oddly, check the README's gotcha list *first* —
   every one of those bullets cost us real debugging hours (the ingest-token
   role and the "histograms before first emission" rule especially).

## Two honest caveats
- `HARVEST-TODO.md` lists a few pieces that only live on the Splunk box
  (the wider ITSI tree export, the second glass table, the box's nginx
  config) — Craig will export them next time that box is powered on.
- `docs/Splunk-AI-Agent-Monitoring-Guide.docx` is the long-form annotated
  walkthrough of the agent code and the whole recipe — worth a skim before
  step 4, ideal with a coffee.

Questions → Craig. Enjoy!

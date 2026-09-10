# Observability Cloud org prerequisites (AI Agent Monitoring)

1. ORG-SCOPE feature flags (Splunk internal flag tooling — the Superpowers UI
   "Enabled" checkbox is browser-local only and does NOT count):
   apm2AIOnOlly, apm2AIOnOllyGA, apm2AIOnOllyPart2, openAiIntegration
   (+ apm2AIOnOllyCustomEvals if offered, dbMonitoring for DB Query Performance).
   Verify server-side: GET /v2/organization -> "features" array.
2. LLM Providers connection (Settings → LLM Providers): ONE per org,
   provider must match your agent's provider (Anthropic), model must be the
   EXACT DATED id (e.g. claude-haiku-4-5-20251001). Drives LLM-as-a-judge
   evaluations; sampling % is the only per-org knob.
3. Ingest token: create with INGEST **and** "API token with roles" ticked,
   role **ai_monitoring** added. Via API: POST /v2/token with
   authScopes:["INGEST","API"] and the org's ai_monitoring role id.
   An INGEST-only token ingests spans fine into APM but the AI trace store
   silently ignores them (tiles read "chat span count" -> everything 0).
4. Emission rules (already encoded in the kit's agent+collector):
   - gen_ai metrics must arrive as NATIVE OTLP histograms (signalfx exporter
     send_otlp_histograms: true) with delta temporality;
   - never let a legacy/cumulative emitter touch the standard gen_ai.* names —
     the names poison org-wide and only Splunk can reset them;
   - chat/invoke_agent spans need message content attributes to classify;
   - gen_ai.cost.* is a PROTECTED namespace (externally submitted cost series
     are dropped) — the kit uses gen_ai.cost2.* for its own cost charts.

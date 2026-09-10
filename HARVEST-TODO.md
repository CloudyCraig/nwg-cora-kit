# Still to harvest (needs the Splunk box nwg.crgpov.com powered ON)

- [ ] **ITSI full backup** — Settings → Backup/Restore (or `kvstore_op=backup`):
      captures ALL services/KPIs/entities/glass tables/correlation searches at once.
      The kit currently rebuilds the AI-agents pieces from scripts + the one
      glass-table JSON; the wider nwpay service tree (39 services, 136 KPIs,
      14+ correlation searches) is Marc's original build and only lives in ITSI.
- [ ] **craigs_digital_experience glass table** — export via
      `itoa_interface/glass_table/craigs_digital_experience` (no local copy).
- [ ] **Box nginx config** `/etc/nginx/conf.d/spa.conf` (SPA/API/HEC proxy,
      port-80 `__proxy_health` block for the watchdog) + `natwest-spa-watchdog.{service,timer,sh}`.
      GOTCHA: spa.conf hard-codes cluster node IPs (NodePorts 30598/30680) — must be
      updated on every node replacement; certbot rewrites can break the watchdog probe.
- [ ] **HEC token config + indexes** (nwpay_audit / nwpay_infra / thousandeyes / itsi_* )
      and props/transforms from cloud-init.
- [ ] Chaos-controller + payments-app manifests (Marc has the original IaC; the kit
      deliberately only covers the AI layer added on top).

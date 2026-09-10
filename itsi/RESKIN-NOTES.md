# Reskinning the executive glass table

The definition is Dashboard-Studio JSON inside the ITSI glass_table object
(`definition` field). Safe editing loop: GET full object -> edit definition ->
POST back -> HARD-RELOAD the browser tab (defn changes only load on reload;
close duplicate tabs first — stale tabs keep dispatching old queries).

Where things live in `glass_table_craigs_executive_view_v3.json`:
- **Title text**: visualization `md_003` (markdown). Logo image: `img_002`.
- **Background/canvas**: layout.layoutDefinitions.main.options (backgroundColor, 1920x1096).
- **Top-row tiles**: sv_006/011/016/021/026/031/036; colours via each tile's
  rangeValue config (e.g. `cfgFraud`, `majorColorEditorConfig`); trend = %
  deviation vs 8h median (see caption viz `md_trendnote`).
  KNOWN LIMIT: the trend number cannot carry a % glyph (five approaches tried
  and documented — the viz's "percent" mode ignores trendValue entirely).
- **Refresh**: every dataSource has options.refresh (currently "120s").
- **Quad "sparkline" images** in Business KPI Trends are PRE-BAKED SVGs chosen
  by rangeValue — recolouring means regenerating those images.
- Fraud tiles: value-driven colour rules; searches synthesise ambient fraud
  (md5-based flicker) — see ds_091/ds_025 queries.

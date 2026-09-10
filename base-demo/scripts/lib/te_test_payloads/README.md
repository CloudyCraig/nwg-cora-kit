# ThousandEyes test payload templates

Each `TE-XX-*.json` file is a v7 ThousandEyes API request body for one of the
six demo tests. They use a few `${VAR}` placeholders that
`scripts/07-configure-thousandeyes.sh` substitutes with `envsubst` at
creation time:

| Placeholder            | Set by                                             |
|------------------------|----------------------------------------------------|
| `${DEMO_HOSTNAME}`     | `secrets/thousandeyes.env`                         |
| `${DEMO_BASE_URL}`     | `secrets/thousandeyes.env`                         |
| `${TE_TX_USERNAME}`    | `secrets/thousandeyes.env`                         |
| `${TE_TX_PASSWORD}`    | `secrets/thousandeyes.env`                         |
| `${AGENTS_5}`          | JSON array of 5 enterprise / cloud agent IDs       |
| `${AGENTS_3}`          | JSON array of 3 agent IDs                          |
| `${AGENTS_2}`          | JSON array of 2 agent IDs (Web Transaction only)   |

The agent IDs are picked dynamically by the create script - it queries
`/v7/agents` filtered to cloud agents in London / Frankfurt / Amsterdam /
NYC / Singapore so re-running on a different account doesn't fail with
hardcoded IDs.

Why JSON files rather than a single bash heredoc:

- Easier to diff / version a 6-test rollout
- Non-bash humans can read and tweak the payloads
- Selenium/Web Transaction script (TE-04) is large and benefits from a
  dedicated file
- Re-applying after a config tweak is a simple PUT against the same id
  with the same JSON

Test IDs are written to `secrets/te-state.json` after the first run so
subsequent invocations can PUT-to-update rather than POST-create.

# rum-user-simulator

Playwright-driven, per-city browser sessions that produce steady Splunk RUM
signal against the NatWest Payments SPA on a 30-second cadence per city.
The **Madrid** loop polls the chaos-controller and switches to a rage-click
flow when `madrid-payment-degradation` or `madrid-network-degradation` is
armed — every other iteration runs the healthy baseline. **London** and
**Frankfurt** always run the healthy baseline.

Fully additive to the existing chart: nothing is modified, only added.
The whole thing is gated on `rumUserSimulator.enabled` in values.yaml so
scale-to-zero or a helm value flip removes it cleanly.

## What it produces in RUM

Per iteration, per city:

- `page_view` on `/send`
- `Send payment` action span with `payment.*` attrs
- `payment.completed` action span with `payment.outcome=success|error` and
  `client.duration_ms`
- If chaos-armed AND the response is slow: `payment.degraded=true` sticky
  session attribute + a `PaymentDegraded` RUM error event (fires from the
  SPA's own `rum.ts::reportPaymentDegraded`)
- If chaos-armed: Splunk RUM's built-in `frustrationSignals.rageClick` event
  (7 clicks × 150ms gap trips the detector)

Persona / geo tagging:
- Madrid → `cust-es-001` (Sofía, location=madrid, country=ES) — carries the
  ES tag that ties into the `sanctions-aml` chaos gate.
- London → `cust-uk-003` (Margaret, no location) — RUM span carries no
  `customer.location`; Splunk RUM's built-in `geoCity` (derived from the
  pod's egress IP, so eu-west-2) is the fallback pivot. Documented
  limitation — see "Known limitations" below.
- Frankfurt → `cust-de-001` (Klaus, location=frankfurt) — full tagging.

## Files

```
rum-user-simulator/
  Dockerfile           # Playwright + Chromium base, node 20
  package.json
  run.js               # entrypoint; boots poller + N city loops
  lib/
    config.js          # env parsing + logging
    chaos.js           # /chaos/api/scenarios poller w/ caching + fail-safe
    session.js         # one browser session: seed storage → /send → submit/rage
    cityLoop.js        # per-city 30s cadence
  README.md            # this file

helm/natwest-payments/
  templates/rum-user-simulator.yaml   # Deployment (new; no service)
  values.yaml                          # rumUserSimulator: block appended
```

## Build + push

Requires terraform outputs (region + registry). ECR repo must exist:

```sh
aws --profile natwest ecr create-repository \
  --repository-name natwest-payments-rum-user-simulator \
  --region eu-west-2 \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability MUTABLE
```

Then build via the existing pipeline (opt-in flag keeps old workflows
unaffected):

```sh
cd scripts
IMAGE_TAG=0.1.0 \
  SKIP_SERVICE=1 SKIP_TRAFFIC=1 SKIP_LEDGER_JAVA=1 SKIP_FRONTEND=1 SKIP_CHAOS_CONTROLLER=1 \
  BUILD_RUM_USER_SIMULATOR=1 \
  ./01-build-push.sh
```

Or build directly:

```sh
REPO=236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-rum-user-simulator
TAG=0.1.0
aws --profile natwest ecr get-login-password --region eu-west-2 \
  | docker login --username AWS --password-stdin "${REPO%/*}"
docker buildx build --platform linux/amd64 \
  --file rum-user-simulator/Dockerfile \
  --tag "${REPO}:${TAG}" --push rum-user-simulator/
```

## Deploy

> **WARNING — `helm upgrade` on this release rolls out-of-band images back to
> chart defaults.** The current helm release (`natwest-payments` revision 126,
> deployed 2026-06-20) predates several `kubectl set image` / `kubectl scale`
> changes that live on live pods but are NOT captured in helm-stored values.
> A `helm upgrade --reuse-values` will silently roll them back to older tags,
> and the AML demo goes flat until they're pinned again.
>
> Images/scales that must be pinned on every helm upgrade (as of 2026-07-10):
> - `web-frontend`: `0.7.8-nostore` (chart default is `0.1.5`, which no longer
>   exists in ECR → `ImagePullBackOff`)
> - `chaos-controller`: `0.1.12-aml-err90` (chart default `0.1.0`)
> - `sanctions-aml-service` image: `natwest-payments-service:0.1.9-madrid-rca`
>   (chart default `0.1.6`)
> - `sanctions-aml-service` replicas: `3` (chart values.yaml says 3 — but if
>   stored release values override it, respin with `--set` below)
>
> Full upgrade command that pins everything AND enables the sim:
>
> ```sh
> helm --kube-context natwest -n natwest upgrade natwest-payments helm/natwest-payments \
>   --reuse-values \
>   --set frontend.image.tag=0.7.8-nostore \
>   --set chaosController.image.tag=0.1.12-aml-err90 \
>   --set services.sanctions-aml-service.image.tag=0.1.9-madrid-rca \
>   --set services.sanctions-aml-service.replicas=3 \
>   --set rumUserSimulator.enabled=true \
>   --set rumUserSimulator.image.repository=236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-rum-user-simulator \
>   --set rumUserSimulator.image.tag=0.1.0
> ```
>
> Simpler alternative — since the sim is a new Deployment not a mutation
> of an existing one, you can apply the rendered template directly and
> skip helm entirely:
>
> ```sh
> helm template natwest-payments helm/natwest-payments \
>   --set rumUserSimulator.enabled=true \
>   --set rumUserSimulator.image.repository=236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-rum-user-simulator \
>   --set rumUserSimulator.image.tag=0.1.0 \
>   -s templates/rum-user-simulator.yaml \
>   | kubectl --context natwest -n natwest apply -f -
> ```
>
> This is how the sim was actually deployed on 2026-07-10 after the
> `--reuse-values` rollout showed the caveat above. No other deployment is
> touched.

Standard helm-integrated command (use only if the caveats above are
addressed):

```sh
helm --kube-context natwest -n natwest upgrade natwest-payments helm/natwest-payments \
  --reuse-values \
  --set rumUserSimulator.enabled=true \
  --set rumUserSimulator.image.repository=236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-rum-user-simulator \
  --set rumUserSimulator.image.tag=0.1.0
```

Verify:

```sh
kubectl --context natwest -n natwest get deploy rum-user-simulator
kubectl --context natwest -n natwest logs -f deploy/rum-user-simulator
# Expect: sim_boot → session_start (per city) → session_done every 30s
```

Then in Splunk Observability (eu0, DXA):
- Filter RUM Session Search by `customer.location=madrid` → Sofía sessions
  with clean `payment.completed` outcome=success.
- Arm the AML chaos in the SPA `/ops` tile → within one Madrid loop
  iteration the sim rage-clicks + `payment.degraded=true` + a rage-click
  frustration event appears.
- Clear the chaos → Madrid returns to healthy on next iteration.

## Rollback — quick reference card

| Intent | Command |
| --- | --- |
| Stop all sessions instantly (keep deploy) | `kubectl --context natwest -n natwest scale deploy/rum-user-simulator --replicas=0` |
| Restore | `kubectl --context natwest -n natwest scale deploy/rum-user-simulator --replicas=1` |
| Disable one city | `kubectl --context natwest -n natwest set env deploy/rum-user-simulator CITY_MADRID_ENABLED=false` (or LONDON/FRANKFURT) |
| Re-enable that city | `... CITY_MADRID_ENABLED=true` |
| Change cadence live | `... CADENCE_SECONDS=60` |
| Remove deployment via helm | `helm --kube-context natwest -n natwest upgrade natwest-payments helm/natwest-payments --reuse-values --set rumUserSimulator.enabled=false` |
| Restore via helm | `... --set rumUserSimulator.enabled=true` (image repo/tag must still be set) |
| Full nuke | `./rum-user-simulator/rollback.sh` (see script — deletes deploy + optionally the ECR repo) |
| Manifest-level fallback | `kubectl --context natwest -n natwest delete deploy rum-user-simulator` |

The `rumUserSimulator:` block in `values.yaml` is additive; deleting it and
re-running `helm upgrade` also removes the deployment.

## Backups

Prior versions of files that were touched are stored in the session scratchpad
(NOT in git):
- `values.yaml.BACKUP` (pre-block state of helm/natwest-payments/values.yaml)
- `01-build-push.sh.BACKUP` (pre-block state of scripts/01-build-push.sh)

## Local dev / smoke test

Node 20+ required. Playwright + Chromium install ~500MB.

```sh
cd rum-user-simulator
npm install
npx playwright install chromium

# Point at whatever SPA + chaos-controller are reachable from your workstation.
# (In-cluster URLs won't resolve from a laptop.)
export SPA_URL=http://itsi.splunk-observability.com
export CHAOS_URL=http://itsi.splunk-observability.com/chaos/api  # via nginx proxy
export CHAOS_PRESENTER_TOKEN=<from kubectl get secret chaos-controller-token>
export CADENCE_SECONDS=15
node run.js
```

Logs stream one JSON record per event to stdout. Grep for `session_done`
to see per-iteration outcomes.

## Known limitations

- **London customer.location is empty.** Margaret (cust-uk-003) doesn't
  have a `location` block in `personas.ts` (deliberate — see the file's
  commentary about the UK trio). The sim intentionally does NOT modify
  personas.ts, so London sessions carry no `customer.location`. If you
  need explicit London tagging, expose `SplunkRum` on `window` in
  `main.tsx` (`window.SplunkRum = SplunkRum`) and set
  `rumUserSimulator.cities.london.locationOverride=london` — the sim will
  best-effort stamp `customer.location=london` post-init. Alternatively,
  add a `location: { city: "london", country: "GB", region: "EU-WEST" }`
  block to Margaret's persona — but that DOES modify personas.ts.
- **No login form is filled** — the sim seeds `sessionStorage.nw-payments-auth`
  directly, so `auth.login.success` never fires from these sessions. The
  traffic-generator's `AUTH_BEACON_RPS=2` already produces continuous
  `auth.*` events; this is a deliberate trade-off to avoid handling the
  SPA plaintext password inside the sim.
- **RUM SDK must init on every page load.** If the SPA is behind an auth
  redirect the sim doesn't handle (e.g. an nginx BasicAuth was added
  in front of the SPA), sessions will fail. Currently no such gate
  exists — the SPA's own AuthContext is the only gate and we bypass it
  correctly.
- **Chromium boot on a t3.large.** With three concurrent city loops and a
  30 s cadence you'll see 3 × 3–5s Chromium context boots every 30 s.
  Resource request 150m CPU / 384Mi RAM matches steady-state; peak boots
  can hit 400–500m briefly. Node should have ~1 vCPU headroom.

## Design notes

- Chromium is launched ONCE per pod and reused across sessions via new
  contexts. Each context is a fresh RUM session id (localStorage cleared)
  and a fresh persona seed — no cross-city contamination.
- `context.addInitScript` runs BEFORE the SPA JS on each navigation, so
  the persona + auth marker are in place before `PersonaProvider` mounts.
- The chaos poller runs on its own timer; a slow chaos-controller can't
  stretch a session budget. Failure = fail-safe to `clear` (healthy),
  which is documented in `lib/chaos.js`.
- SIGTERM handler stops all timers, closes all contexts, then exits. Pod
  terminates well within the default 30 s grace.
- The pod runs as `pwuser` (uid 1000) with `readOnlyRootFilesystem: true`
  and writable emptyDirs mounted at `/tmp` and `/home/pwuser/.cache` for
  Chromium's shm + browser cache.

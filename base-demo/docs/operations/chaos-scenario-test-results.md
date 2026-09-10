# Chaos scenario marathon results

**Run started:** 2026-06-20T10:55:43Z  
**Run ended:** 2026-06-20T18:10:18Z  
**Dwell per scenario:** 1200s (20 min)  
**Scenarios tested:** 19  

## Summary

| Outcome | Count |
|---------|-------|
| pass | 18 |
| warn | 1 |
| fail | 0 |

## Results by scenario

### Payment-status latency creep (`latency-creep`)

- **Category:** latency | **Severity:** low
- **Target:** payment-status-service
- **Outcome:** pass
- **Window:** 2026-06-20T10:57:15Z → 2026-06-20T11:20:16Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=1/6584, target p95=Nonems, pods=1/1

### Madrid network degradation (`madrid-network-degradation`)

- **Category:** latency | **Severity:** medium
- **Target:** traffic-generator
- **Outcome:** pass
- **Window:** 2026-06-20T11:20:16Z → 2026-06-20T11:43:01Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=0/14621, target p95=Nonems, pods=1/1

### Fraud CPU regression (`fraud-cpu-regression`)

- **Category:** latency | **Severity:** medium
- **Target:** fraud-detection-service
- **Outcome:** pass
- **Window:** 2026-06-20T11:43:01Z → 2026-06-20T12:05:47Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=95/14189, target p95=Nonems, pods=1/1

### Gold fast-path disabled (`gold-fast-path-off`)

- **Category:** tier | **Severity:** medium
- **Target:** fraud-detection-service
- **Outcome:** pass
- **Window:** 2026-06-20T12:05:47Z → 2026-06-20T12:28:34Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=147/25635, target p95=Nonems, pods=1/1

### Tier throttle (`tier-throttle`)

- **Category:** tier | **Severity:** medium
- **Target:** api-gateway
- **Outcome:** pass
- **Window:** 2026-06-20T12:28:34Z → 2026-06-20T12:51:22Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=298/35466, target p95=Nonems, pods=2/2

### Cache cold (sanctions) (`cache-cold`)

- **Category:** tier | **Severity:** medium
- **Target:** sanctions-aml-service
- **Outcome:** pass
- **Window:** 2026-06-20T12:51:22Z → 2026-06-20T13:14:08Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=105/16633, target p95=Nonems, pods=1/1

### Sanctions cache disabled (`sanctions-cache-disabled`)

- **Category:** app | **Severity:** medium
- **Target:** sanctions-aml-service
- **Outcome:** pass
- **Window:** 2026-06-20T13:14:08Z → 2026-06-20T13:36:53Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=103/7259, target p95=Nonems, pods=1/1

### Bad deploy: fraud error rate (`bad-deploy-fraud`)

- **Category:** app | **Severity:** medium
- **Target:** fraud-detection-service
- **Outcome:** pass
- **Window:** 2026-06-20T13:36:53Z → 2026-06-20T13:59:39Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=1529/24425, target p95=Nonems, pods=1/1

### SWIFT counterparty flap (`swift-counterparty-flap`)

- **Category:** app | **Severity:** medium
- **Target:** swift-network
- **Outcome:** pass
- **Window:** 2026-06-20T13:59:39Z → 2026-06-20T14:22:26Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=382/1298, target p95=Nonems, pods=1/1

### SWIFT scheme outage (fraud check) (`swift-scheme-outage`)

- **Category:** app | **Severity:** medium
- **Target:** fraud-detection-service
- **Outcome:** pass
- **Window:** 2026-06-20T14:22:26Z → 2026-06-20T14:45:14Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=166/25134, target p95=Nonems, pods=1/1

### Ledger DB slow (`db-slow`)

- **Category:** latency | **Severity:** medium
- **Target:** ledger-service
- **Outcome:** pass
- **Window:** 2026-06-20T14:45:14Z → 2026-06-20T15:08:02Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=23/28427, target p95=Nonems, pods=1/1

### Gateway timeout squeeze (`gateway-timeout-squeeze`)

- **Category:** latency | **Severity:** high
- **Target:** api-gateway
- **Outcome:** pass
- **Window:** 2026-06-20T15:08:02Z → 2026-06-20T15:30:55Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=12954/52785, target p95=Nonems, pods=2/2

### Settlement producer offline (`settlement-producer-off`)

- **Category:** app | **Severity:** medium
- **Target:** payment-initiation-service
- **Outcome:** pass
- **Window:** 2026-06-20T15:30:55Z → 2026-06-20T15:53:45Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=78/54899, target p95=Nonems, pods=3/3

### Pod restart (api-gateway) (`pod-restart-gateway`)

- **Category:** infra | **Severity:** medium
- **Target:** api-gateway
- **Outcome:** warn
- **Window:** 2026-06-20T15:53:45Z → 2026-06-20T16:16:32Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=clear → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=218/33786, target p95=Nonems, pods=2/2

### Kill service (scale to 0) (`kill-service`)

- **Category:** infra | **Severity:** high
- **Target:** (parameterised)
- **Outcome:** pass
- **Window:** 2026-06-20T16:16:32Z → 2026-06-20T16:39:11Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=None/None, target p95=Nonems, pods=None

### Bad deploy: payment-initiation-service v0.2.0 (`bad-deploy-payment-initiation`)

- **Category:** deploy | **Severity:** high
- **Target:** payment-initiation-service
- **Outcome:** pass
- **Window:** 2026-06-20T16:39:11Z → 2026-06-20T17:02:00Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=6841/62286, target p95=Nonems, pods=3/3

### Redis outage (`redis-outage`)

- **Category:** infra | **Severity:** high
- **Target:** redis
- **Outcome:** pass
- **Window:** 2026-06-20T17:02:01Z → 2026-06-20T17:24:45Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=0/0, target p95=Nonems, pods=/0

### Kafka outage (`kafka-outage`)

- **Category:** infra | **Severity:** high
- **Target:** kafka
- **Outcome:** pass
- **Window:** 2026-06-20T17:24:45Z → 2026-06-20T17:47:30Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=0/0, target p95=Nonems, pods=/0

### Postgres outage (`postgres-outage`)

- **Category:** infra | **Severity:** high
- **Target:** postgres
- **Outcome:** pass
- **Window:** 2026-06-20T17:47:30Z → 2026-06-20T18:10:18Z
- **Inject:** OK | **Clear:** OK
- **Status:** inject=armed → clear=clear
- **Final sample (5m window):** gateway 5xx=0.0%, target errors=0/0, target p95=Nonems, pods=/0

## Observations

Metrics are sampled from `index=otel_traces` on Splunk Enterprise. A **pass** means inject/clear succeeded and trace data showed elevated errors, latency, or an armed scenario state during the dwell window. **warn** usually means the scenario ran but symptoms were subtle in the 5-minute Splunk lookback (e.g. transient pod restarts). **fail** means inject or clear did not complete.

# EKS cluster spec (as running, 2026-09-10)

- Cluster: `nwg-demo`, eu-west-1, acct 445740536021, eksctl-created (v0.225.0),
  Kubernetes **1.31**. Tags include `splunk-demo=NWG-demo`.
- Nodegroup: `ng-nwg-m5` — **m5.xlarge x2** (min 2 / max 3), ON_DEMAND,
  AL2023_x86_64_STANDARD, launch template: 40GB gp3 (3000 IOPS), IMDSv2
  required. DO NOT use t3/burstable: sustained ~60% CPU exhausts credits and
  the hypervisor clamps to baseline (took the demo down 2026-09-04).
- Original terraform/eksctl in base-demo/terraform predates this: update
  instance type + k8s version when rebuilding from it.
- Namespaces: `natwest` (demo + AI layer; live manifests in
  cluster-snapshot/natwest-namespace-live.yaml, tokens redacted),
  `splunk-monitoring` (Splunk OTel collector chart; values in
  cluster-snapshot/splunk-monitoring-namespace-live.yaml).
- Splunk box: EC2 m6i.4xlarge "nwg-demo-splunk" (Splunk Enterprise 10.4 + ITSI
  10.4 + nginx front proxy + HEC :8088 + web :8000 + REST :8089). Custom
  indexes + HEC inputs: splunk-box/indexes-and-hec.conf.txt. Build from
  base-demo/terraform/cloud-init, then apply splunk-box/ nginx+watchdog files.

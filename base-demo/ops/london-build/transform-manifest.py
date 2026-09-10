#!/usr/bin/env python3
# Transform the captured live natwest manifest into an appliable one for London:
#  - unwrap List, drop auto-managed/live-only fields
#  - repoint custom images from Marc's ECR (eu-west-2) to Craig's ECR (eu-west-1)
#  - drop cluster-injected objects (kube-root-ca.crt, default SA)
# Public images (kafka/postgres/redis/python/curl/exporters) are left untouched.
import sys, yaml

SRC_ECR = "236881431638.dkr.ecr.eu-west-2.amazonaws.com"
DST_ECR = "445740536021.dkr.ecr.eu-west-1.amazonaws.com"

infile, outfile = sys.argv[1], sys.argv[2]
docs = list(yaml.safe_load_all(open(infile)))
items = []
for d in docs:
    if not isinstance(d, dict):
        continue
    if d.get("kind") == "List" or "items" in d:
        items.extend(d.get("items", []) or [])
    else:
        items.append(d)

SKIP = {("ConfigMap", "kube-root-ca.crt"), ("ServiceAccount", "default")}

def clean_meta(md):
    for k in ("resourceVersion", "uid", "creationTimestamp", "generation",
              "managedFields", "selfLink"):
        md.pop(k, None)
    ann = md.get("annotations") or {}
    for k in ("kubectl.kubernetes.io/last-applied-configuration",
              "deployment.kubernetes.io/revision"):
        ann.pop(k, None)
    if ann:
        md["annotations"] = ann
    else:
        md.pop("annotations", None)
    return md

def repoint(o):
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == "image" and isinstance(v, str) and v.startswith(SRC_ECR):
                o[k] = v.replace(SRC_ECR, DST_ECR, 1)
            else:
                repoint(v)
    elif isinstance(o, list):
        for x in o:
            repoint(x)

out = []
for it in items:
    if not isinstance(it, dict):
        continue
    kind = it.get("kind")
    name = (it.get("metadata") or {}).get("name")
    if (kind, name) in SKIP:
        continue
    it.pop("status", None)
    if "metadata" in it:
        clean_meta(it["metadata"])
    spec = it.get("spec")
    if kind == "Service" and isinstance(spec, dict):
        for k in ("clusterIP", "clusterIPs", "ipFamilies", "ipFamilyPolicy",
                  "internalTrafficPolicy", "sessionAffinity"):
            spec.pop(k, None)
    repoint(it)
    out.append(it)

with open(outfile, "w") as f:
    yaml.safe_dump_all(out, f, default_flow_style=False, sort_keys=False)
print(f"wrote {len(out)} objects -> {outfile}")

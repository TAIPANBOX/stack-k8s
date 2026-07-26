#!/usr/bin/env bash
# Re-read every price in ../COSTS.md section 7 from Google's own price list.
#
#   ./prices.sh                 # the numbers this deployment depends on
#   ./prices.sh --region europe-west3
#
# Free, and it needs no project: the Cloud Billing Catalog API answers any
# authenticated caller. It creates nothing, reads nothing about your account,
# and touches no resource. `gcloud auth login` is the only prerequisite.
#
# This exists so no number in COSTS.md has to be trusted. A price list changes;
# a claim in a document does not. Run this before quoting any of them.
set -euo pipefail

REGION="${REGION:-europe-west3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --region)  REGION="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

command -v gcloud >/dev/null || { echo "gcloud not found" >&2; exit 1; }
TOKEN="$(gcloud auth print-access-token 2>/dev/null)" || { echo "gcloud auth login first" >&2; exit 1; }

COMPUTE_SVC="6F81-5844-456A"   # Compute Engine
NET_SVC="E505-1604-58F8"       # Networking
FS_SVC="D97E-AB26-5D95"        # Cloud Filestore
GKE_SVC="CCD8-9BF1-090E"       # Kubernetes Engine

python3 - "$TOKEN" "$REGION" "$COMPUTE_SVC" "$NET_SVC" "$FS_SVC" "$GKE_SVC" <<'PY'
import json, sys, urllib.request

tok, region, compute_svc, net_svc, fs_svc, gke_svc = sys.argv[1:7]

def skus(svc):
    out, page = [], ""
    while True:
        url = f"https://cloudbilling.googleapis.com/v1/services/{svc}/skus?pageSize=5000&currencyCode=USD"
        if page:
            url += "&pageToken=" + page
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
        d = json.loads(urllib.request.urlopen(req, timeout=60).read())
        out += d.get("skus", [])
        page = d.get("nextPageToken", "")
        if not page:
            return out

def rate(s):
    # Not the LAST tier: egress is tiered (0.12 up to 1 TiB, 0.11 to 10 TiB,
    # 0.08 beyond) and tieredRates[-1] would quote the volume discount as if it
    # were the price. Not blindly the FIRST either: several SKUs open with a
    # zero-priced tier that is a real free allowance, and quoting 0.00 for an
    # external IP address is just as wrong in the other direction.
    #
    # So: the first tier that actually charges, plus the size of any free tier
    # in front of it, which is a number worth seeing rather than averaging away.
    # Both halves of this were found by running the script and disbelieving it.
    pe = s["pricingInfo"][0]["pricingExpression"]
    free = 0.0
    for t in pe["tieredRates"]:
        up = t["unitPrice"]
        p = int(up.get("units", 0)) + up.get("nanos", 0) / 1e9
        if p == 0:
            free = float(pe["tieredRates"][min(pe["tieredRates"].index(t) + 1, len(pe["tieredRates"]) - 1)].get("startUsageAmount", 0))
            continue
        return p, pe["usageUnit"], free
    return 0.0, pe["usageUnit"], free

def find(pool, *words, usage="OnDemand", exclude=()):
    # Substring matching on a description is how this API is searched, and it
    # is a trap: "Balanced PD Capacity" is a substring of "REGIONAL Balanced PD
    # Capacity", which is the replicated product at exactly double the price.
    # Anything that has a dearer superset needs its exclusions listed.
    for s in pool:
        d = s["description"]
        if s["category"]["usageType"] != usage:
            continue
        if region not in s.get("serviceRegions", []) and "global" not in s.get("serviceRegions", []):
            continue
        if any(x.lower() in d.lower() for x in exclude):
            continue
        if all(w.lower() in d.lower() for w in words):
            return s
    return None

def show(label, s, mult=1.0, unit=""):
    if s is None:
        print(f"   {label:44s} {'NOT FOUND':>14s}   (the SKU description changed, fix prices.sh)")
        return None
    p, u, free = rate(s)
    tail = s["description"][:40]
    if free:
        tail = f"first {free:g} {u} FREE, then: {tail}"
    print(f"   {label:44s} {p*mult:14.8f} {unit or u:12s} {tail}")
    return p

print(f"\n== compute, {region}, on demand, USD")
compute = skus(compute_svc)
core_d = show("C3D core, per hour",            find(compute, "C3D Instance Core"))
ram_d  = show("C3D RAM, per GiB-hour",         find(compute, "C3D Instance Ram"))
core_i = show("C3 core, per hour",             find(compute, "C3 Instance Core"))
ram_i  = show("C3 RAM, per GiB-hour",          find(compute, "C3 Instance Ram"))
pd     = show("pd-balanced, per GiB-month",    find(compute, "Balanced PD Capacity", exclude=("Regional", "Snapshot")))
ip_use = show("external IPv4 in use, per hour", find(compute, "External IP Charge on a Standard VM"))
ip_idle= show("reserved idle address, per hour", find(compute, "Static Ip Charge"))

if core_d and ram_d:
    node = core_d * 8 + ram_d * 16
    print(f"\n   c3d-highcpu-8 = 8 cores + 16 GiB   = {node:.6f} USD/hour   ({node*730:.2f}/month)")
    print(f"   5 nodes                             = {node*5:.6f} USD/hour   ({node*5*730:.2f}/month)")
if core_i and ram_i:
    node_i = core_i * 8 + ram_i * 16
    print(f"   c3-highcpu-8  (Intel, needs a quota) = {node_i:.6f} USD/hour   ({node_i*730:.2f}/month)")
if pd:
    print(f"   5 x 100 GB pd-balanced              = {pd*500/730:.6f} USD/hour   ({pd*500:.2f}/month)")

print(f"\n== network, {region}")
net = skus(net_svc)
show("forwarding rule, per hour",   find(net, "Cloud Load Balancer Forwarding Rule Minimum for"))
show("LB data processing, per GiB", find(net, "Regional External Passthrough Network Load Balancer Inbound Data"))
show("egress to western Europe, per GiB", find(compute, "Network Internet Data Transfer Out from Frankfurt to Western Europe"))

print(f"\n== filestore, {region}  (minimums are a product constraint, not a SKU)")
fs = skus(fs_svc)
hdd = show("BASIC_HDD, per GiB-month",  find(fs, "Filestore Capacity Basic HDD"))
show("BASIC_SSD, per GiB-month",        find(fs, "Filestore Capacity Basic SSD"))
show("ZONAL, per GiB-month",            find(fs, "Filestore Capacity Zonal"))
show("REGIONAL, per GiB-month",         find(fs, "Filestore Capacity Regional"))
if hdd:
    print(f"\n   BASIC_HDD minimum is 1 TiB          = {hdd*1024:.2f} USD/month for ANY size below it")
    print(f"   the 5 GiB event log therefore costs   {hdd*1024:.2f} against 1.80 on AWS EFS")

print("\n== managed kubernetes")
show("GKE cluster fee, per hour", find(skus(gke_svc), "Zonal Kubernetes Clusters"))
print("   first zonal cluster is covered by a USD 74.40/month free-tier credit")
print()
PY

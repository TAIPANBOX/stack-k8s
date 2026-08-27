#!/usr/bin/env bash
# An independent sweep of the whole project, not a re-read of teardown's report.
# Anything that can bill, plus the things that block a VPC from being deleted.
P="${1:-stack-k8s-gcp}"
row() { printf '  %-26s %s\n' "$1" "${2:-none}"; }
echo "== billable =="
row "instances"        "$(gcloud compute instances list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "disks"            "$(gcloud compute disks list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "snapshots"        "$(gcloud compute snapshots list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "custom images"    "$(gcloud compute images list --project $P --no-standard-images --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "reserved IPs"     "$(gcloud compute addresses list --project $P --format='value(name,status)' 2>/dev/null | tr '\n' ' ')"
row "forwarding rules" "$(gcloud compute forwarding-rules list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "target pools"     "$(gcloud compute target-pools list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "GKE clusters"     "$(gcloud container clusters list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "filestore"        "$(gcloud filestore instances list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "storage buckets"  "$(gcloud storage buckets list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "SQL instances"    "$(gcloud sql instances list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
echo "== free, but leftovers that block a clean VPC =="
row "networks"         "$(gcloud compute networks list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "firewall rules"   "$(gcloud compute firewall-rules list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"
row "service accounts" "$(gcloud iam service-accounts list --project $P --format='value(email)' 2>/dev/null | tr '\n' ' ')"
row "custom roles"     "$(gcloud iam roles list --project $P --format='value(name)' 2>/dev/null | tr '\n' ' ')"

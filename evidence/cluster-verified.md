# The cluster, verified (2026-07-25)

Five Hetzner CPX42 in fsn1, k3s v1.36.2 with embedded etcd on three of them,
Calico v3.29.1, Longhorn v1.7.2. Everything below is a command's output, not a
claim about one.

## Nodes
NAME                 ROLES    PROVIDER                   INTERNAL-IP   VERSION
ubuntu-16gb-fsn1-1   <none>   k3s://ubuntu-16gb-fsn1-1   10.10.0.2     v1.36.2+k3s1
ubuntu-16gb-fsn1-2   <none>   k3s://ubuntu-16gb-fsn1-2   10.10.0.3     v1.36.2+k3s1
ubuntu-16gb-fsn1-3   <none>   k3s://ubuntu-16gb-fsn1-3   10.10.0.4     v1.36.2+k3s1
ubuntu-16gb-fsn1-4   <none>   hcloud://<server-id>         10.10.0.5     v1.36.2+k3s1
ubuntu-16gb-fsn1-5   <none>   hcloud://<server-id>         10.10.0.6     v1.36.2+k3s1

The providerIDs are the interesting column, and they are deliberately MIXED on
this cluster.

`hcloud://<server-id>` is what lets the cloud controller map a Node to a
Hetzner server. Without it the controller skips the node silently (one
`UnknownProviderIDPrefix` event on the Node object and nothing in the CCM log
at default verbosity), so a load balancer gets provisioned, gets an IP, and
gets zero targets: it answers connections and closes them. See GOTCHAS 10.

This cluster was already running when that was diagnosed, so only the two
AGENTS were retrofitted. The three servers keep `k3s://<name>`, on purpose:
changing a providerID means deleting the Node object (the field is immutable),
and deleting a k3s SERVER's Node object also removes its etcd member and
detaches its Longhorn volumes. Not a trade worth making on a live etcd quorum
to tidy up a column. `install.sh` sets the flag on every node at install time,
where it costs nothing, which is the whole point of that script existing.

## The workload, spread across the cluster
POD                                 NODE                 IP              READY
genaryx-console-75678dbc69-q775b    ubuntu-16gb-fsn1-1   10.42.229.142   true
idryx-7fbdf87d4c-hcpmb              ubuntu-16gb-fsn1-2   10.42.248.15    true
policy-db-0                         ubuntu-16gb-fsn1-5   10.42.181.146   true
tokenfuse-cloud-6c67877df7-hcjvr    ubuntu-16gb-fsn1-5   10.42.181.151   true
tokenfuse-gateway-56c7895d4-2tltz   ubuntu-16gb-fsn1-3   10.42.154.78    true
wardryx-79cbdcb445-v4k9m            ubuntu-16gb-fsn1-4   10.42.110.18    true

## Storage: the shared event log is genuinely ReadWriteMany
CLAIM              MODE              CLASS       STATUS   SIZE
cloud-state        [ReadWriteOnce]   longhorn    Bound    2Gi
console-state      [ReadWriteOnce]   longhorn    Bound    2Gi
data-policy-db-0   [ReadWriteOnce]   longhorn    Bound    5Gi
stack-events       [ReadWriteMany]   stack-rwx   Bound    5Gi

VOLUME                                     STATE      ROBUSTNESS   MODE   REPLICAS
pvc-031932fb-c01a-46b3-a8c4-8a98b6ad8dce   attached   healthy      rwx    3
pvc-4767c233-326b-4280-bcdf-a63bc2ad04ae   attached   healthy      rwo    3
pvc-5c254438-1bce-417d-8756-069a2a014287   attached   healthy      rwo    3
pvc-a92b61d5-58b5-47af-bed2-d51da626d2f2   attached   healthy      rwo    3

## Every plane answers, from inside the cluster
cloud 8080     200 ok
gateway 4100   200 ok
wardryx 8090   200 ok
idryx 8081     200 ok
console 7420   200 ok

## The data the console governs
money   : 9288 runs, $4254.67 settled spend, 9 budget alerts
policy  : 7 policies (1 written by the console as blocks), 5 approvals
identity: 29 identities, 43 detector alerts

## And the freeze is still in force, after both planes were restarted
DENY - policy "console-block:agent:agent://meridian.example/treasury/reconciliation-batch" requires a live attestation; agent attestation is "none"

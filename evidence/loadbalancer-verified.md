# Load balancer: verified evidence (2026-07-25, cluster e02, fsn1)

## kubectl -n agent-stack get svc genaryx-console-lb
NAME                 TYPE           CLUSTER-IP      EXTERNAL-IP                                     PORT(S)                      AGE   SELECTOR
genaryx-console-lb   LoadBalancer   10.43.144.116   10.10.0.7,142.132.242.94,2a01:4f8:c01e:831::1   443:31306/TCP,80:31838/TCP   40m   app=genaryx-console

## Hetzner API: the balancer the CCM created, with its targets
id            : 7333342
name          : agent-stack
type          : lb11 (EUR 7.4900 /month net, EUR 0.0120 /hour)
public ipv4   : 142.132.242.94
private ip    : 10.10.0.7
labels        : {'hcloud-ccm/service-uid': '1f9948a7-1b81-4b60-94d6-56f3f21a34cf'}
service       : tcp/80 -> nodePort 31838, health http /healthz every 15s
service       : tcp/443 -> nodePort 31306, health http /healthz every 15s
target        : server 154920115 (10.10.0.5) private=True health=[(80, 'healthy'), (443, 'healthy')]
target        : server 154920155 (10.10.0.6) private=True health=[(80, 'unhealthy'), (443, 'unhealthy')]

## The console answering through the balancer, from the Mac
$ curl -s -o /dev/null -w '%{http_code}' http://142.132.242.94/healthz
200
$ curl -s http://142.132.242.94/healthz
ok
$ curl -s http://142.132.242.94/ | grep title
<title>Genaryx</title>

## Why only one target is healthy
externalTrafficPolicy: Local, one console replica: the node WITHOUT the pod
must fail its health check, and does. That is the policy working, not a fault.

# The Freeze test, on Kubernetes (2026-07-25)

The last unverified leg of the lifecycle work: wardryx enforcement was proven
live on the old single box, but nobody had ever clicked Freeze in a UI and
followed it all the way to a denied decision. Done here, in the browser, over
an ssh tunnel to a console pod on a five-node cluster.

## 1. In the console

Watch dock, agent `treasury/reconciliation-batch` (OVER CAP, $93):
  Freeze -> the button becomes CONFIRM FREEZE / Cancel (no single-click
  enforcement change), confirm -> the card reads FROZEN, Kill greys out,
  and the action becomes Unfreeze.

## 2. What that wrote into the policy plane

{
  "id": "console-block-agent-agent---meridian-example-treasury-reconciliation-batch",
  "name": "console-block:agent:agent://meridian.example/treasury/reconciliation-batch",
  "target": "agent://meridian.example/treasury/reconciliation-batch",
  "allow_domains": [
    "console.blocked.invalid"
  ],
  "deny_above_usd": 0.001,
  "max_steps": 1,
  "deny_if_unattested": true,
  "updated_at": "2026-07-25T01:26:35Z"
}

Note the shape: deny_above_usd a tenth of a cent, max_steps 1,
deny_if_unattested, and an allow_domains sentinel nothing can match.
wardryx has no single deny-everything primitive - its PDP denies per
DIMENSION - so a block has to close every dimension at once.

## 3. The PDP's own answer, frozen agent versus an untouched one

FROZEN  agent: {"decision": "deny", "policy_version": "90938aa80443", "reason": "policy \"console-block:agent:agent://meridian.example/treasury/reconciliation-batch\" requires a live attestation; agent attestation is \"none\"", "approval_token_required": false, "cacheable": false}

UNTOUCHED agent: {"decision": "allow", "policy_version": "90938aa80443", "reason": "allowed: request satisfies all matched policy rules", "approval_token_required": false, "cacheable": true}

## 4. Where this ran

POD                                  NODE                 IP
genaryx-console-6b56f6cf95-lrtl4     ubuntu-16gb-fsn1-5   10.42.181.144
idryx-b76d8654-5xljj                 ubuntu-16gb-fsn1-5   10.42.181.138
tokenfuse-cloud-dc4fc5ffc-hkrs9      ubuntu-16gb-fsn1-5   10.42.181.142
tokenfuse-gateway-66f844d75c-vp2wf   ubuntu-16gb-fsn1-5   10.42.181.136
wardryx-5d57756789-5s5tj             ubuntu-16gb-fsn1-5   10.42.181.137

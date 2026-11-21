# Production install guide

This takes the Inference Gateway from the lab into Lambda's own environment. It follows the order you'd
hit things in: BNK first, then the adapter and its two helpers, then Lambda's API gateway, key service,
console and billing.

Every command runs against the target cluster with `kubectl` and `helm` pointed at it, from the root of
this kit.

| Step | What | Owner |
|---|---|---|
| 1 | [BNK 2.4 prerequisites](#1-bnk-24-prerequisites) | Platform |
| 2 | [Namespace and pull secret](#2-namespace-and-pull-secret) | Platform |
| 3 | [Publish instances](#3-publish-instances) | Lambda inventory |
| 4 | [Key introspection](#4-key-introspection) | Lambda identity |
| 5 | [Helpers: guardrails and frontier models](#5-helpers-guardrails-and-frontier-models) | Platform |
| 6 | [Install the adapter](#6-install-the-adapter) | Platform |
| 7 | [Route the API](#7-route-the-api) | Lambda API gateway |
| 8 | [Wire the console](#8-wire-the-console) | Lambda frontend |
| 9 | [Usage into billing](#9-usage-into-billing) | Lambda billing |
| 10 | [Verify](#10-verify) | Platform |
| | [Security hardening](#security-hardening-for-production) | Platform |

## Lab vs production

The lab stands in for parts of Lambda's stack. This is everything that changes.

| Concern | In the lab | In production |
|---|---|---|
| BNK install | `bnk-deploy` on a 3-node kubeadm cluster, gretap overlay, TMM on a software node | Your BNK 2.4 install (host or BlueField DPU), real VLANs and self-IPs |
| Instances | A GPU provisioner creates GCP T4 VMs and relay pods; a ConfigMap lists them | Your inventory writes the instance list and labels model-server pods (or relays) |
| API keys | `lambda-api-mock` issues keys and answers `/internal/v1/introspect` | Your key service answers the same introspection contract |
| API routing | nginx in the console container routes `/api/v1/inference-*` to the adapter | Your API gateway routes the same prefixes, after its own checks |
| Console | React portal that replicates the Lambda console | Your console calls the same paths; the portal is a reference UI |
| Guardrails | calypso-relay with the track's Calypso token, or a mock scanner | calypso-relay with your F5 AI Guardrails project |
| Frontier models | frontier-proxy with the sandbox AWS account | frontier-proxy with your AWS account (or another OpenAI-compatible provider) |
| Usage | SQLite in the adapter, shown in the usage view | Same records, drained into your billing pipeline |
| Image tags | Re-pushed `0.1.0`, `pullPolicy: Always` | Mirrored into your registry, pinned by digest |
| TMM watchdog | `TMM_WATCHDOG=1` restarts a stalled TMM | `0`: the adapter reports, your on-call decides |
| Placement | Everything on the `app: workload` node, so TMM reaches it | Any node TMM can reach on 5514/TCP, 5515/UDP and the sideband ports |

## Two rules that shape everything

**The iRule has no DNS and no TLS.** BNK iRules open sidebands as plain TCP to an IP. Give the
introspection and guardrail URLs as `http://<ClusterIP>:<port>/path`, the form the lab ran. The target has to
speak plain HTTP and be reachable from TMM. Anything that needs HTTPS (your key
service, F5 AI Guardrails, Bedrock) gets a small relay inside the cluster. That's why calypso-relay and
frontier-proxy exist.

**The Kubernetes objects are the truth.** The adapter keeps no data-path state. Gateways, routes, pools and
iRules are the state of every endpoint and policy. SQLite holds only what Kubernetes can't: policy config,
usage records and benchmark runs. Delete endpoints through the API, never by hand, and never uninstall the
chart with endpoints still running (their Gateways and iRules stay behind).

## 1. BNK 2.4 prerequisites

You need BNK 2.4 with the Gateway API and Gateway API Inference Extension (GAIE v1.4.0) CRDs. Two install-
time details matter, and both are easy to get wrong:

- **Install the GAIE CRDs before BNK.** If they land after the BNK control plane, the controller never
  watches InferencePool and the F5 Endpoint Picker logs `could not find InferencePool` forever.
  ```sh
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.4.0/manifests.yaml
  ```
- **Set `eppNamespaces` at install time.** BNK only runs endpoint pickers in namespaces listed in
  `CNEInstance.spec.eppNamespaces`. Include `lambda-ie` when you install. Patching it later rolls the
  controller. Without it, endpoints sit in `provisioning` and go to `error` after 120 s.

Check the cluster:

```sh
for r in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io \
         inferencepools.inference.networking.k8s.io f5-epps.inference.k8s.f5.com \
         f5-big-cne-irules.k8s.f5net.com netpolicies.gateway.k8s.f5.com; do
  kubectl get crd "$r" >/dev/null 2>&1 && echo "ok       $r" || echo "MISSING  $r"
done
kubectl get gatewayclass f5-gateway-class
kubectl get cneinstance -n f5-bnk -o jsonpath='{.items[0].spec.eppNamespaces}{"\n"}'   # must list lambda-ie
kubectl get license.k8s.f5net.com -n f5-cne-core                                       # state Active
kubectl get ds f5-tmm -n f5-bnk                                                        # TMM ready
```

Also plan:

- **A VIP range.** One address per endpoint, two when it serves frontier models. Clients must route to it
  through TMM's external self-IP. That's `VIP_RANGE` in step 6.
- **TMM's sideband source.** BNK 2.4 opens iRule sidebands from the TMM pod IP. The NetworkPolicies here
  admit TMM by pod label (`app: f5-tmm` in `f5-bnk`). If your build sources from the internal self-IP, add
  it as an `ipBlock` too.

The lab built BNK with [`bnk-deploy`](https://github.com/iracic82/bnk-deploy), which pins every version and
handles these ordering traps. It's a reasonable reference if you're installing BNK from scratch.

## 2. Namespace and pull secret

The F5 Endpoint Picker pulls its image from F5's registry, so the endpoint namespace needs the pull secret.

```sh
kubectl create namespace lambda-ie
kubectl label namespace lambda-ie pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
kubectl get secret far-pull-secret -n f5-bnk -o json \
  | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences)
        | .metadata.namespace="lambda-ie"' \
  | kubectl apply -f -
```

The adapter, helpers and relays meet Pod Security `restricted`. Keep `enforce` at `baseline`: the F5 Endpoint
Picker pods that BNK creates in this namespace haven't been checked against `restricted`. Raise it once you've
confirmed they comply.

## 3. Publish instances

The adapter never creates model servers. It needs two things from your inventory:

**The instance list.** ConfigMap `lambda-instances` in `lambda-ie`, key `instances.json`: a JSON array of
Lambda `Instance` objects. The adapter reads `id`, `status` (`active` or `booting` can join an endpoint),
and two tags: `source` (`gpu` or `simulated`; one endpoint can't mix them) and `models` (comma-separated;
the first is the model the endpoint serves and the tokenizer its endpoint picker loads). Full Instance
objects are fine.

```json
[{"id": "0920582c3f4e4b1d8a7c", "name": "gpu-1", "status": "active",
  "tags": [{"key": "source", "value": "gpu"},
           {"key": "models", "value": "Qwen/Qwen2.5-7B-Instruct-AWQ"}]}]
```

**Labelled pods in `lambda-ie`.** One Deployment per instance, with these labels on the Deployment and its
pods. Pool members must share a namespace with the InferencePool and its endpoint picker.

| Label | Value |
|---|---|
| `lambda.ai/instance` | the instance `id` |
| `lambda.ai/role` | `main` (or `fallback` for a downgrade model on the same instance) |
| `lambda.ai/model` | the model name, lowercased with `/` and `.` as `-` |

The adapter adds `lambda.ai/ie-<endpoint-id>: main|fallback` to pick pool members. It owns that label;
don't set it yourself.

If the model servers are pods in `lambda-ie`, label them and you're done. If they're VMs or pods elsewhere
(the lab's case), run one relay per instance: `relay/` is a 10-line socat image that forwards the OpenAI API
on 8000 and the vLLM KV-event streams on 20080 and 20081, so the endpoint picker can do cache-aware routing.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: relay-gpu-1
  namespace: lambda-ie
  labels: &labels
    app: lambda-relay
    lambda.ai/instance: "0920582c3f4e4b1d8a7c"
    lambda.ai/model: qwen-qwen2-5-7b-instruct-awq
    lambda.ai/role: main
spec:
  replicas: 1
  selector: {matchLabels: {lambda.ai/instance: "0920582c3f4e4b1d8a7c", lambda.ai/role: main}}
  template:
    metadata: {labels: *labels}
    spec:
      automountServiceAccountToken: false
      containers:
        - name: relay
          image: <your-registry>/bnk-gpu-relay:0.1.0        # build from relay/
          env: [{name: TARGET, value: "10.20.0.15"}]         # the model server's IP
          ports: [{containerPort: 8000, name: http}, {containerPort: 20080}, {containerPort: 20081}]
          readinessProbe: {tcpSocket: {port: 8000}, periodSeconds: 5}
          securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 10001,
                            capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
```

Model servers need vLLM's KV-event publishing on (`--kv-events-config`) for cache-aware routing. Without it,
AI load balancing still balances by queue depth.

## 4. Key introspection

The adapter never stores keys. One contract covers both callers:

```
POST /introspect            {"token": "<key>"}
200 {"active":true,"sub":"<user>","role":"admin"|"member"}      valid key
200 {"active":false}                                            anything else
```

- **The adapter** calls `ADAPTER_API_KEY_INTROSPECT_URL` for every API call. `role: admin` may change
  things; `member` may only read (403 `global/forbidden` on changes). This one can be HTTPS.
- **The auth iRule** calls `AUTH_INTROSPECT_URL` from TMM for every data-path request when `api_auth` is on.
  Plain HTTP, by ClusterIP, reachable from TMM. `sub` becomes the user that usage is metered against. The iRule matches
  the reply as text, so keep the JSON compact (`"active":true` with no spaces is safest).

Errors and timeouts (3 s) fail closed: the request gets 401.

If your key service is HTTPS-only, put a plain-HTTP proxy in `lambda-ie` in front of it and point
`AUTH_INTROSPECT_URL` at the proxy's ClusterIP. Lock the proxy down to TMM and the adapter with a
NetworkPolicy, the same way `manifests/calypso-relay.yaml` does.

**Trial key service.** `manifests/introspect-stub.yaml` is a 60-line server that answers exactly this
contract from a Secret of keys. Use it to try the install before your key service is wired, never in
production. Instructions are in the file's header.

## 5. Helpers: guardrails and frontier models

Both helpers run the adapter image with a different entry point. Each has a NetworkPolicy that admits only
TMM and the adapter, because each one spends a paid credential.

**Guardrails (F5 AI Guardrails, CalypsoAI).** The guardrail iRule scans every prompt through
calypso-relay, which holds the token and calls Calypso over HTTPS. `CALYPSO_PROJECT` must be the project
id (a UUID); a project name gets `Project not found`.

```sh
kubectl -n lambda-ie create secret generic calypso-api \
  --from-literal=CALYPSO_API_TOKEN='<token>' \
  --from-literal=CALYPSO_URL=https://us1.calypsoai.app \
  --from-literal=CALYPSO_PROJECT='<project uuid>'
kubectl apply -f manifests/calypso-relay.yaml
```

Any scan service that answers the same `POST /backend/v1/scans` contract works in its place.

**Frontier models (Amazon Bedrock).** frontier-proxy exposes an OpenAI-compatible
`/v1/chat/completions` and signs Bedrock calls. BNK routes an endpoint's frontier listener (:8002) to it,
so frontier requests pass the same auth, guardrail, quota and metering as the GPUs. Prefer IRSA or a
workload identity over static keys where your cluster supports it.

```sh
kubectl -n lambda-ie create secret generic frontier-aws \
  --from-literal=AWS_ACCESS_KEY_ID='<id>' --from-literal=AWS_SECRET_ACCESS_KEY='<secret>' \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 --from-literal=BEDROCK_REGION=us-east-1
kubectl -n lambda-ie create configmap frontier-models \
  --from-literal=FRONTIER_MODELS=us.amazon.nova-pro-v1:0,us.amazon.nova-lite-v1:0
kubectl apply -f manifests/frontier-proxy.yaml
```

In both manifests, replace the image with your mirrored copy and check the TMM `ipBlock`.

## 6. Install the adapter

Start from `values-production.yaml`. Every line marked `CHANGE` needs your value. Create the Secret it
references first:

```sh
kubectl -n lambda-ie create secret generic bnk-adapter \
  --from-literal=USAGE_FLUSH_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)"
KEY_IP="$(kubectl get svc <your-introspect-proxy> -n lambda-ie -o jsonpath='{.spec.clusterIP}')"
CALYPSO_IP="$(kubectl get svc calypso-relay -n lambda-ie -o jsonpath='{.spec.clusterIP}')"
helm upgrade --install bnk-inference-adapter ./chart -n lambda-ie -f values-production.yaml \
  --set config.AUTH_INTROSPECT_URL="http://${KEY_IP}:8080/introspect" \
  --set config.GUARDRAIL_URL="http://${CALYPSO_IP}:8080/backend/v1/scans" \
  --wait --timeout 5m
```

The chart installs a Deployment (one replica, `Recreate`: SQLite has one writer), a Service (8080 API,
5514/TCP usage, 5515/UDP firewall events), a PVC, a ServiceAccount, RBAC scoped to `lambda-ie` and
`f5-bnk` (plus cluster-wide read of Gateways, so a new endpoint never takes a VIP that's already in use), and a NetworkPolicy.

What each value does:

| Value | Production setting |
|---|---|
| `image.*` | Your registry, an immutable tag or digest |
| `config.VIP_RANGE` | Your routable range |
| `config.AUTH_INTROSPECT_URL` | `http://<ClusterIP>:<port>/introspect`, reachable from TMM (step 4) |
| `config.ADAPTER_API_KEY_INTROSPECT_URL` | Your key service (HTTPS fine) |
| `config.ADMIN_USERS` | Empty: roles come from introspection |
| `config.GUARDRAIL_URL` | `http://<calypso-relay ClusterIP>:8080/backend/v1/scans` |
| `config.USAGE_COLLECTOR_ADDR` | `bnk-inference-adapter.lambda-ie.svc:5514` |
| `config.FRONTIER_MODELS` | Same list as the frontier-models ConfigMap, or empty |
| `config.TOKEN_PRICES_USD_PER_1M` | `model=price,...` for the usage view's cost column |
| `config.AUDIT_WEBHOOK_URL` + `secretEnv.AUDIT_WEBHOOK_TOKEN` | Your audit service |
| `config.FIREWALL_PLATFORM_CIDRS` | The adapter's own sources to the VIPs, as narrow as possible |
| `config.TMM_WATCHDOG` | `0` |
| `usageFlushToken` | Secret from above; without it usage never leaves TMM |
| `persistence.*` | A class with snapshots |
| `networkPolicy.apiClients` | Only your API gateway |
| `networkPolicy.tmmPods` / `tmmSelfIPs` | How TMM reaches the collectors |

Check it:

```sh
kubectl -n lambda-ie port-forward svc/bnk-inference-adapter 8080:8080 &
curl -s localhost:8080/api/v1/inference-gateway/status -H "Authorization: Bearer $ADMIN_KEY"
# {"data":{"mode":"live","data_plane_healthy":true, ...}}
```

`data_plane_healthy: false` means the adapter's health check saw TMM stop passing traffic, or can't read the cluster: check RBAC, the CRDs and the TMM pods. A 401 means the
adapter can't reach the key service or the key isn't active. With `apiClients` locked to your gateway, run
this check from a pod the policy admits, or add a temporary rule.

## 7. Route the API

Two prefixes go to the adapter. Everything else stays where it is.

| Prefix | Upstream |
|---|---|
| `/api/v1/inference-*` (endpoints, operations, gateway status) | `bnk-inference-adapter.lambda-ie.svc:8080` |
| `/api/v1/network-firewall-*` | `bnk-inference-adapter.lambda-ie.svc:8080` |

- **Forward `Authorization` unchanged.** The adapter introspects it. Your gateway may check the key first;
  the adapter checks again.
- **Don't buffer** `/api/v1/inference-endpoint-operations/chat`, and allow a 300 s read timeout. A
  benchmark start returns immediately.
- **Never expose** the adapter's 5514 and 5515, or `/introspect`, outside the cluster.

`frontend/nginx.reference.conf` is the lab's working version of this routing. Its `location` blocks are the
part to copy.

## 8. Wire the console

The console needs no new backend. It calls the public paths above with the user's own session, and reads
the same envelopes as the rest of the Lambda API:

```
success   {"data": <payload>}
failure   {"error": {"code": "global/...", "message": "...", "suggestion": "..."}}
```

`frontend/` has what the lab console used:

| File | What it is |
|---|---|
| `frontend/schema/gateway.ts`, `firewall.ts` | TypeScript types generated from the contracts with `openapi-typescript` |
| `frontend/src-api/client.ts` | Fetch wrapper: envelope parsing, `ApiError` with `code` and `suggestion` |
| `frontend/src-api/gateway.ts` | Every call the console makes, with polling rules (TanStack Query hooks) |
| `frontend/src-api/firewall.ts` | The same for the network firewall |
| `frontend/README.md` | Screens, calls and polling, and the auth note below |

**Auth in the lab vs production.** The lab console never holds a key in the browser: its nginx injects a
console key server-side, only for same-origin requests carrying `X-Lambda-Console: 1`. In production your
console already has a session. Forward whatever your gateway turns that into, as long as the introspection
endpoint returns the right `sub` and `role` for it.

Regenerate the types when the contract changes:

```sh
npx openapi-typescript contracts/inference-gateway.openapi.yaml -o src/api/schema/gateway.ts
npx openapi-typescript contracts/network-firewall.openapi.yaml -o src/api/schema/firewall.ts
```

## 9. Usage into billing

The metering fragment is always in every endpoint's iRule. TMM queues one line per request and the adapter
drains the queue over TCP to its collector:

```
v1|<endpoint>|<user>|<model>|<prompt_tokens>|<completion_tokens>|<total_tokens>|<outcome>|<member>|<http_status>|<epoch_ms>
v1|ie-3f9a1c0b7d2e|alice|Qwen/Qwen2.5-7B-Instruct-AWQ|412|64|476|served|10.244.1.17:8000|200|1763712000123
```

`outcome` is `served`, `downgraded`, `auth_rejected`, `guardrail_blocked`, `quota_blocked` or `error`.
Refused requests are recorded too, with zero tokens.

The adapter stores these in SQLite and serves them as `GET /api/v1/inference-endpoints/{id}/usage`
(per user and model, with cost when prices are set). For billing, either poll that endpoint per endpoint
id, or point `USAGE_COLLECTOR_ADDR` at your own TCP collector that reads the same lines. In that second
case the console's usage view and token quotas no longer see the records, so keep the adapter as the
collector unless you're replacing both.

Token quotas count in TMM (per endpoint, per user, in a session table). `POST
/api/v1/inference-endpoint-operations/reset-usage` resets them, which is the hook for a billing period.

## 10. Verify

`scripts/conformance.sh` runs every operation in the contract and prints one PASS or FAIL per check. It
creates and deletes its own endpoint, so it holds one VIP for about a minute.

```sh
export ADAPTER_URL=http://localhost:8080   # or your API gateway origin
export ADMIN_KEY=<an admin key>  MEMBER_KEY=<a member key>
export CONFORMANCE_INSTANCE_IDS=<instance-id>[,<instance-id>]
bash scripts/conformance.sh                # exit 0: every check passed
```

Then the whole flow, step by step: `scripts/api-walkthrough.sh` (instances, create, wait, chat, each
policy, usage, benchmark, delete). Check the BNK side with one label:

```sh
kubectl get gateways,httproutes,inferencepools,f5-epps,f5-big-cne-irules,netpolicies,svc -A -l lambda.ai/endpoint=<id>
```

## Security hardening for production

The chart is the one the lab ran. Before production, review these two points. Neither needs a chart change.

**1. Keep `lambda-ie` for model-server pods only.** The adapter's Role in `lambda-ie` may `patch` Pods and
Deployments there, because it moves endpoint-membership labels on the relay or model-server pod templates.
A patch on a Deployment can change more than labels. So:

- Run nothing else in `lambda-ie`: no workloads that hold credentials, and no other teams' pods. The helpers
  (calypso-relay, frontier-proxy) hold paid credentials, so consider their own namespace in production, and
  point the adapter at their ClusterIPs as before.
- Add an admission policy that lets the adapter's ServiceAccount change only labels. On Kubernetes 1.30+ a
  ValidatingAdmissionPolicy does it:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: bnk-adapter-labels-only}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - {apiGroups: [apps], apiVersions: [v1], operations: [UPDATE], resources: [deployments]}
      - {apiGroups: [""], apiVersions: [v1], operations: [UPDATE], resources: [pods]}
    namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lambda-ie}}
  matchConditions:
    - name: from-adapter
      expression: request.userInfo.username == "system:serviceaccount:lambda-ie:bnk-inference-adapter"
  validations:
    - expression: >-
        object.kind == "Pod"
          ? object.spec == oldObject.spec
          : object.spec.replicas == oldObject.spec.replicas
            && object.spec.selector == oldObject.spec.selector
            && object.spec.template.spec == oldObject.spec.template.spec
      message: bnk-inference-adapter may only change labels in lambda-ie
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: bnk-adapter-labels-only}
spec:
  policyName: bnk-adapter-labels-only
  validationActions: [Deny]
```

Apply it in a test cluster first and run `scripts/conformance.sh`: creating, changing and deleting endpoints
must still pass. The lab didn't run this policy, so treat it as a starting point.

**2. Gateways accept routes from any namespace.** Each endpoint's Gateway is rendered with
`allowedRoutes.namespaces.from: All` (see `docs/samples/endpoint-objects.yaml`). Anyone who can create an
HTTPRoute in any namespace could attach it to an endpoint's listener. Limit who may create HTTPRoutes:
grant `httproutes` create only to the adapter and to platform admins, in every namespace. Narrowing this
in the adapter itself (to `Selector` on `lambda-ie`) is a small code change for a later version; it isn't
in the tested build.

## Operating it

| Look at | For |
|---|---|
| `GET /api/v1/inference-gateway/status` | Mode and data-plane health; alert on `data_plane_healthy:false` |
| Endpoint and policy `status` / `status_reason` | `error` with the reason BNK gave |
| `kubectl logs -n lambda-ie deploy/bnk-inference-adapter` | `apply failed for`, `reconcile pass failed`, `cannot read ConfigMap lambda-instances` |
| `kubectl logs -n f5-bnk -l app=f5-tmm` | `BNK usage flush failed`, `Auth: introspection error, failing closed` |

**Backups.** Snapshot the PVC. Policy config is in SQLite, and the adapter's reconcile loop keeps the
cluster objects in line with it, so a restored volume brings endpoints back to their last configuration.

**Upgrades.** `helm upgrade` with a new image. The pod is replaced (Recreate), so the API is down for a few
seconds; the data path isn't, because BNK keeps serving the objects already applied. A new adapter version
re-renders the iRules through the reconcile loop.

**Removing it.** Delete every endpoint through the API, then `helm uninstall`. The adapter removes its
Gateways, routes, pools and iRules. Nothing else will.

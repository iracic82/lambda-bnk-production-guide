# Try it in a lab

This is the quick trial: `bnk-inference-adapter` alone on a **test** BNK 2.4 cluster, with no portal, no
Lambda services and no GPU provisioner. Everything is driven with `curl`, the way Lambda's own console or
CLI would call it. The target is a working endpoint in under an hour. For Lambda's environment, use
[INSTALL.md](INSTALL.md) instead.

These steps were run on the reference lab (a bnk-ai-demos-kv sandbox, where three `vllm-sim` pods in
namespace `sim` stand in for GPUs). On your own test cluster, swap those pods for your model servers in
step 3. Run every command from the root of this kit.

| Step | What | Took |
|---|---|---|
| 1 | Prerequisites check | |
| 2 | Namespace and pull secret | |
| 3 | Instances and relay Deployments | |
| 4 | Key-introspection stub | |
| 5 | Helm install | |
| 6 | Create an endpoint | |
| 7 | Toggle each policy | |
| 8 | Chat through it | |
| 9 | Conformance script | |
| | **Total (target: under 60 min)** | |

## 1. Prerequisites check

```sh
export KUBECONFIG=/etc/kubernetes/admin.conf
for r in gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io \
         inferencepools.inference.networking.k8s.io f5-epps.inference.k8s.f5.com \
         f5-big-cne-irules.k8s.f5net.com netpolicies.gateway.k8s.f5.com; do
  kubectl get crd "$r" >/dev/null 2>&1 && echo "ok       $r" || echo "MISSING  $r"
done
kubectl get gatewayclass f5-gateway-class
kubectl get cneinstance -n f5-bnk -o jsonpath='{.items[0].spec.eppNamespaces}{"\n"}'
kubectl get secret far-pull-secret -n f5-bnk
kubectl get pods -n sim -l app=vllm-sim -o wide
```

You want six `ok` lines and a GatewayClass, plus three `vllm-sim` pods Running. Those pods are the lab's
simulated GPUs, serving `NousResearch/Meta-Llama-3.1-8B-Instruct`.

`eppNamespaces` has to include `lambda-ie`. A stock bnk-ai-demos-kv build lists only `sim`. BNK takes this
list at install time; patching it afterwards rolls the controller, which can leave the new pod Pending on
a CPU-tight sandbox. So build the sandbox with `BNK_EPP_NAMESPACES="sim,lambda-ie"` exported before the
lab's `setup-bnk` runs. If it's already built with only `sim`, patch it and watch the controller come back:

```sh
CNE="$(kubectl get cneinstance -n f5-bnk -o name | head -1)"
kubectl patch -n f5-bnk "$CNE" --type merge -p '{"spec":{"eppNamespaces":["sim","lambda-ie"]}}'
kubectl get pods -n f5-bnk -w      # until the controller pod is Running again
```

Without it, endpoints stay `provisioning` and go to `error` after 120 s.

## 2. Namespace and pull secret

The endpoint picker pulls its image from F5's registry, so `lambda-ie` needs a copy of the pull secret.

```sh
kubectl create namespace lambda-ie
kubectl get secret far-pull-secret -n f5-bnk -o json \
  | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences)
        | .metadata.namespace="lambda-ie"' \
  | kubectl apply -f -
```

## 3. Instances and relay Deployments

The adapter needs two things it never creates itself: the ConfigMap `lambda-instances` listing your
instances, and one Deployment per instance in `lambda-ie`, labelled as [INSTALL.md step 3](INSTALL.md#3-publish-instances) describes. In
the full lab the GPU provisioner writes both. Here you write them by hand, which is what your own
inventory system would do.

Pool members have to share a namespace with the InferencePool, and the sim pods live in `sim`. So each
instance gets a small TCP relay in `lambda-ie` (the `bnk-gpu-relay` image) that forwards the API on 8000
and the KV-event streams on 20080 and 20081 to one sim pod. The sim Services only expose 8000, so the
relays target pod IPs. If a sim pod restarts, re-run this step.

```sh
cat > /tmp/relays.sh <<'EOF'
set -eu
instances="["
for profile in fast medium; do
  ip="$(kubectl get pod -n sim -l app=vllm-sim,profile=$profile -o jsonpath='{.items[0].status.podIP}')"
  id="$(printf 'sim/%s' "$profile" | sha256sum | cut -c1-32)"
  echo "$profile -> $ip (instance $id)"
  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: relay-sim-$profile
  namespace: lambda-ie
  labels: &labels
    app: lambda-relay
    lambda.ai/instance: "$id"
    lambda.ai/model: nousresearch-meta-llama-3-1-8b-instruct
    lambda.ai/role: main
spec:
  replicas: 1
  selector: {matchLabels: {lambda.ai/instance: "$id", lambda.ai/role: main}}
  template:
    metadata: {labels: *labels}
    spec:
      automountServiceAccountToken: false
      containers:
        - name: relay
          image: iracic82/bnk-gpu-relay:0.1.0
          env: [{name: TARGET, value: "$ip"}]
          ports: [{containerPort: 8000, name: http}, {containerPort: 20080}, {containerPort: 20081}]
          readinessProbe: {tcpSocket: {port: 8000}, periodSeconds: 5}
          securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 10001,
                            capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
YAML
  instances="$instances$( [ "$instances" = "[" ] || echo ,){\"id\":\"$id\",\"name\":\"sim-$profile\",\"status\":\"active\",
    \"tags\":[{\"key\":\"source\",\"value\":\"simulated\"},{\"key\":\"models\",\"value\":\"NousResearch/Meta-Llama-3.1-8B-Instruct\"}]}"
done
instances="$instances]"
kubectl create configmap lambda-instances -n lambda-ie --from-literal=instances.json="$instances" \
  --dry-run=client -o yaml | kubectl apply -f -
EOF
bash /tmp/relays.sh
kubectl -n lambda-ie wait --for=condition=Available deploy -l app=lambda-relay --timeout=120s
export INSTANCE_IDS="$(kubectl get deploy -n lambda-ie -l app=lambda-relay \
  -o jsonpath='{range .items[*]}{.metadata.labels.lambda\.ai/instance}{","}{end}' | sed 's/,$//')"
echo "$INSTANCE_IDS"
```

The adapter reads only `id`, `status` and the `source` and `models` tags. A real inventory would publish
the full Lambda `Instance` shape; the extra fields don't hurt.

## 4. Key-introspection stub

The adapter never stores keys. It asks a key service, with one call:

```
POST /introspect   {"token": "<key>"}
200 {"active":true,"sub":"<user>","role":"admin"|"member"}   or   200 {"active":false}
```

`manifests/introspect-stub.yaml` is a 60-line Python server that answers exactly that from a Secret
of keys you create (the manifest ships none, and keys shorter than 24 characters are refused). It is the contract your own key service has to meet, and nothing more. Make two keys, load
them and start it:

```sh
export ADMIN_KEY="adm-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
export MEMBER_KEY="mem-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
kubectl -n lambda-ie create secret generic introspect-keys --dry-run=client -o yaml \
  --from-literal=keys="$(printf '%s platform-admin admin\n%s alice member\n' "$ADMIN_KEY" "$MEMBER_KEY")" \
  | kubectl apply -f -
kubectl apply -f manifests/introspect-stub.yaml
kubectl -n lambda-ie rollout status deploy/introspect-stub
STUB_IP="$(kubectl get svc introspect-stub -n lambda-ie -o jsonpath='{.spec.clusterIP}')"
echo "$STUB_IP"
```

The adapter pod calls it by DNS name. The BNK auth iRule calls it from inside TMM, which can't resolve
DNS, so it gets the ClusterIP. The stub's NetworkPolicy lets in only the adapter pods and TMM's internal
self-IP (`10.1.20.201` in the lab; change it if yours differs).

## 5. Helm install

Minimal values: live mode, both introspection URLs, the lab's VIP range, and the TMM self-IP. Guardrails
and the usage collector are left out; those policies report `error` until you set `GUARDRAIL_URL` and
`USAGE_COLLECTOR_ADDR`.

```sh
cat > /tmp/adopt-values.yaml <<EOF
mode: live
config:
  IE_NAMESPACE: lambda-ie
  GATEWAY_NAMESPACE: f5-bnk
  VIP_RANGE: "172.16.201.110-172.16.201.129"
  ADAPTER_API_KEY_INTROSPECT_URL: "http://introspect-stub.lambda-ie.svc:8080/introspect"
  AUTH_INTROSPECT_URL: "http://${STUB_IP}:8080/introspect"
networkPolicy:
  tmmSelfIPs: ["10.1.20.201/32"]
  apiClients: [{podSelector: {}}]      # anything in lambda-ie; port-forward below goes through the kubelet
EOF
helm upgrade --install bnk-inference-adapter ./chart \
  -n lambda-ie -f /tmp/adopt-values.yaml --wait --timeout 5m
kubectl -n lambda-ie port-forward svc/bnk-inference-adapter 8080:8080 >/dev/null 2>&1 &
sleep 2
export ADAPTER_URL=http://localhost:8080
curl -s "$ADAPTER_URL/api/v1/inference-gateway/status" -H "Authorization: Bearer $ADMIN_KEY"
```

You want `"mode":"live"` and `"data_plane_healthy":true`. If it's `false`, check RBAC and the CRDs
from step 1. A 401 here means the adapter can't reach the stub or the key isn't in the Secret.

## 6. Create an endpoint

```sh
IDS_JSON="$(printf '%s' "$INSTANCE_IDS" | jq -R 'split(",")')"
curl -s "$ADAPTER_URL/api/v1/inference-endpoints" -H "Authorization: Bearer $ADMIN_KEY" \
  -H 'Content-Type: application/json' -d "{\"name\":\"adopt-demo\",\"instance_ids\":$IDS_JSON}" | jq .
export IE_ID="$(curl -s "$ADAPTER_URL/api/v1/inference-endpoints" -H "Authorization: Bearer $ADMIN_KEY" \
  | jq -r '.data[] | select(.name=="adopt-demo") | .id')"
until curl -s "$ADAPTER_URL/api/v1/inference-endpoints/$IE_ID" -H "Authorization: Bearer $ADMIN_KEY" \
      | jq -e '.data.status=="active"' >/dev/null; do sleep 5; done; echo active
kubectl get gateways,httproutes,inferencepools,f5-epps,f5-big-cne-irules,netpolicies,svc -A -l lambda.ai/endpoint=$IE_ID
```

The last command lists every object the endpoint owns. The member key can read all of this but gets
403 `global/forbidden` on any change:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$ADAPTER_URL/api/v1/inference-endpoints" \
  -H "Authorization: Bearer $MEMBER_KEY" -H 'Content-Type: application/json' \
  -d "{\"name\":\"nope\",\"instance_ids\":$IDS_JSON}"
```

## 7. Toggle each policy

Each `PATCH` returns the policy with status `applying`, which turns `on` once BNK accepts the change.

```sh
pol() {  # pol KIND JSON
  curl -s -X PATCH "$ADAPTER_URL/api/v1/inference-endpoints/$IE_ID/policies/$1" \
    -H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' -d "$2" | jq -c .data
}
state() { curl -s "$ADAPTER_URL/api/v1/inference-endpoints/$IE_ID" -H "Authorization: Bearer $ADMIN_KEY" \
  | jq -c '[.data.policies[] | {kind, enabled, status, status_reason}]'; }

pol ai_load_balancing '{"enabled":true}'
pol api_auth          '{"enabled":true}'
pol token_quota       '{"enabled":true,"config":{"tokens_per_user":2000,"fallback_model":"NousResearch/Meta-Llama-3.1-8B-Instruct","mode":"block"}}'
sleep 20; state
```

`guardrails` needs `GUARDRAIL_URL`; to try it, apply `manifests/mock-guardrail.yaml`, set
`config.GUARDRAIL_URL=http://<mock-calypso-svc ClusterIP>:8080/backend/v1/scans`, run `helm upgrade` again,
then `pol guardrails '{"enabled":true}'`. Turn any policy off with `'{"enabled":false}'`.

## 8. Chat through it

The chat operation sends one request to the endpoint's VIP and reports what BNK did with it. With
`api_auth` on, pass a key for the data path in `api_key`:

```sh
chat() {  # chat KEY_FOR_THE_VIP
  curl -s "$ADAPTER_URL/api/v1/inference-endpoint-operations/chat" -H "Authorization: Bearer $ADMIN_KEY" \
    -H 'Content-Type: application/json' \
    -d "{\"endpoint_id\":\"$IE_ID\",\"api_key\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in five words.\"}],\"max_tokens\":16}" \
    | jq -c '.data | {outcome, status_code, model, instance_id, latency_ms}'
}
chat "$MEMBER_KEY"         # outcome served, metered against alice
chat "not-a-real-key"      # outcome auth_rejected: the iRule asked the stub and got active:false
```

These outcomes come from BNK. A dry run against the adapter in mock mode answers `served` to both,
because mock mode doesn't simulate `api_auth`.

## 9. Conformance script

`scripts/conformance.sh` exercises every operation in the contract and prints one PASS or FAIL
per check. It creates and deletes its own endpoint, so on a live install it holds one VIP for about a
minute.

```sh
export CONFORMANCE_INSTANCE_IDS="$INSTANCE_IDS"
bash scripts/conformance.sh
```

Exit code 0 means every check passed.

## Clean up

```sh
curl -s -X DELETE "$ADAPTER_URL/api/v1/inference-endpoints/$IE_ID" -H "Authorization: Bearer $ADMIN_KEY"
helm uninstall bnk-inference-adapter -n lambda-ie
kubectl delete -f manifests/introspect-stub.yaml
kubectl delete deploy -n lambda-ie -l app=lambda-relay
kubectl delete configmap lambda-instances -n lambda-ie
```

Delete the endpoint before uninstalling: the adapter removes its Gateway and iRule, and nothing else
will.

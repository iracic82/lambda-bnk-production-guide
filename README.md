# Lambda Inference Gateway on F5 BIG-IP Next for Kubernetes: production guide

This kit takes the Inference Gateway from the Lambda Cloud POC lab into Lambda's production environment.
It has everything an engineer needs without starting the lab: the API contracts, the Helm chart, production
values, the helper services, the console integration, and a step-by-step install.

## Start here

**[Open the visual guide →](https://iracic82.github.io/lambda-bnk-production-guide/)**

The visual guide is one page with everything: architecture, contracts and envelopes, what each API call does
in BNK, who owns what, lab vs production, and the install with a copy button on every command. It's the
same file as `index.html` in this repo, which also works offline: download the repo and open it in a browser.

The install comes in two views. Pick one:

| View | For | Steps | Values |
|---|---|---|---|
| **Production** | Lambda's environment: your BNK, key service, API gateway, console and billing | [INSTALL.md](INSTALL.md) | [values-production.yaml](values-production.yaml) |
| **Try it in a lab** | A quick trial on a test BNK cluster with a trial key service, before anything is wired | [LAB.md](LAB.md) | [values-lab.yaml](values-lab.yaml) |

The lab view is the procedure that was run on the reference lab. The production view replaces every lab
stand-in with the Lambda system that takes its place.

## How it works

### Architecture: control path and request path

```mermaid
flowchart TB
    Client["Customer app · OpenAI SDK"]
    subgraph Lambda["Lambda Cloud"]
        direction LR
        C["Console / Cloud API"]
        K["Key service · /introspect"]
        B["Billing"]
    end
    subgraph Cluster["BNK 2.4 cluster"]
        A["bnk-inference-adapter · this chart"]
        API[("Kubernetes API · Gateway API, GAIE, BNK objects")]
        CTRL["BNK CNE controller"]
        TMM["TMM · data plane · iRule policies"]
        EPP["F5 Endpoint Picker · one per pool"]
        GPU["GPU model servers · vLLM"]
    end
    C -->|"1 · Inference and firewall API"| A
    A -->|"2 · writes objects"| API
    API -->|"3 · watched by"| CTRL
    CTRL -->|"4 · programs over gRPC"| TMM
    Client ==>|"chat request"| TMM
    TMM ==>|"ext_proc · which GPU?"| EPP
    TMM ==>|"forwards"| GPU
    GPU -.->|"KV-cache events"| EPP
    TMM -.->|"key check"| K
    TMM -.->|"usage records"| A
    A -.->|"usage"| B
```

### One chat request

```mermaid
sequenceDiagram
    autonumber
    participant App as Customer app
    participant TMM as TMM + iRule
    participant Key as Lambda key service
    participant G as Guardrail service
    participant EPP as F5 Endpoint Picker
    participant GPU as GPU (vLLM)
    participant AD as Adapter (usage)
    App->>TMM: POST /v1/chat/completions
    Note over TMM: network firewall (L3/L4)
    TMM->>Key: is this key active?
    Key-->>TMM: active, user, role
    TMM->>G: scan the prompt
    G-->>TMM: allowed
    Note over TMM: token budget and model choice
    TMM->>EPP: ext_proc: which endpoint?
    EPP-->>TMM: GPU with the prefix in KV cache
    TMM->>GPU: request
    GPU-->>TMM: answer + token usage
    TMM-)AD: usage record (tenant, user, model, tokens, GPU)
    TMM-->>App: answer
```

### API calls to BNK objects

```mermaid
flowchart LR
    subgraph Create["Create endpoint"]
        direction TB
        GW["Gateway · own address"] --> RT["HTTPRoute · /v1"] --> IP["InferencePool · chosen instances"] --> EPPO["F5EPP · Endpoint Picker"]
    end
    subgraph Policies["Enable a policy"]
        direction TB
        IR["F5BigCneIrule · composite policy iRule"] --> NP["NetPolicy · binds iRule to the listener"]
    end
    subgraph Firewall["Attach a firewall"]
        direction TB
        FW["F5BigFwPolicy · address and port lists"] --> SP["SecPolicy · binds firewall to the Gateway"]
    end
    NP -.-> GW
    SP -.-> GW
```

### Two install paths

```mermaid
flowchart LR
    S(["Start"]) --> Q{"Lambda systems<br/>ready to wire?"}
    Q -->|"not yet"| L["Try it in a lab<br/>LAB.md · values-lab.yaml<br/>trial key service · curl"]
    Q -->|"yes"| P["Production<br/>INSTALL.md · values-production.yaml"]
    L -->|"swap stand-ins"| P
    P --> P1["1 · BNK 2.4 + GAIE"] --> P2["2 · lambda-ie + pull secret"] --> P3["3 · instances"] --> P4["4 · key introspection"]
    P4 --> P5["5 · helpers"] --> P6["6 · Helm install"] --> P7["7 · API gateway routes"] --> P8["8 · console"] --> P9["9 · billing"] --> P10["10 · conformance"]
```

## What's in the kit

| Path | Contents |
|---|---|
| `index.html` | Visual guide, self-contained |
| `INSTALL.md` | Production install, step by step, with the lab vs production differences |
| `LAB.md` | Trial install on a test BNK cluster, about an hour |
| `values-production.yaml` | Production Helm values; every `CHANGE` line needs your value |
| `values-lab.yaml` | Trial Helm values |
| `chart/` | Helm chart for `bnk-inference-adapter`, the service that implements both APIs |
| `contracts/inference-gateway.openapi.yaml` | Inference Gateway API (OpenAPI 3.1) |
| `contracts/network-firewall.openapi.yaml` | Network firewall API (OpenAPI 3.1) |
| `manifests/calypso-relay.yaml` | Guardrail relay in front of F5 AI Guardrails |
| `manifests/frontier-proxy.yaml` | OpenAI-compatible proxy in front of Amazon Bedrock |
| `manifests/introspect-stub.yaml` | Trial key service that meets the introspection contract (lab only) |
| `manifests/mock-guardrail.yaml` | Keyword guardrail scanner for trying the guardrails policy (lab only) |
| `relay/` | TCP relay image that makes a model server outside the cluster a pool member |
| `frontend/` | Console integration: calls per screen, the fetch client, generated types, routing reference |
| `docs/bnk-objects.md` | The BNK and Gateway API objects behind every call |
| `docs/samples/` | Rendered objects for one endpoint, and a rendered iRule |
| `scripts/conformance.sh` | Checks any install against the contract, one PASS or FAIL per check |
| `scripts/api-walkthrough.sh` | The whole flow in `curl`: create, policies, chat, usage, benchmark, delete |
| `tools/` | Rebuilds `index.html` from the kit's files: `python3 tools/build-kit.py` |

## The integration surface

- **One Helm chart** in a `lambda-ie` namespace, plus two small helpers.
- **Two prefixes on Lambda's API gateway:** `/api/v1/inference-*` and `/api/v1/network-firewall-*`.
- **One introspection endpoint:** `POST {"token"}` returns `{"active", "sub", "role"}`.
- **Usage records** for billing, one line per request.

Both APIs follow Lambda Cloud API v1.10.0 conventions: Bearer keys, `{"data": ...}` and
`{"error": {...}}` envelopes, and `-operations` paths for actions. They drop into the existing spec.

## Requirements

- F5 BIG-IP Next for Kubernetes 2.4, licensed, with TMM running
- Gateway API CRDs and Gateway API Inference Extension v1.4.0 CRDs
- `lambda-ie` in `CNEInstance.spec.eppNamespaces`, with the F5 registry pull secret
- vLLM model servers (KV-cache events on for cache-aware routing)
- Helm 3.x, kubectl

## Versions

| Component | Version |
|---|---|
| Chart / adapter image | 0.1.0 (`iracic82/bnk-inference-adapter:0.1.0`) |
| BNK | 2.4.0 |
| GAIE | v1.4.0 |
| Benchmark engine | NVIDIA AIPerf 0.13.0 (inside the adapter image) |

License: Apache-2.0.

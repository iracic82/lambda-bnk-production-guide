# Console integration

The lab console is a React app that replicates the Lambda console and adds an Inference section. These
files are the part of it Lambda's frontend team needs. They're a reference, not a package: copy the
patterns into your own console.

## Calls each screen makes

All paths are relative to your API origin. Every response is `{"data": ...}`; every failure is
`{"error": {"code", "message", "suggestion"}}`.

| Screen | Calls | Refresh |
|---|---|---|
| Endpoints list | `GET /api/v1/inference-endpoints` | every 3 s while any endpoint is `provisioning`, `deleting` or has a policy `applying` |
| Create endpoint | `GET /api/v1/instances` (existing API), `POST /api/v1/inference-endpoints` | on success |
| Endpoint detail | `GET /api/v1/inference-endpoints/{id}` | every 3 s while busy |
| Rename / change instances | `POST /api/v1/inference-endpoints/{id}` | on success |
| Delete | `DELETE /api/v1/inference-endpoints/{id}` | list refetch |
| Policies | `PATCH /api/v1/inference-endpoints/{id}/policies/{kind}` | detail polls until status leaves `applying` |
| Token usage | `GET …/{id}/usage`, `POST /api/v1/inference-endpoint-operations/reset-usage` | every 10 s |
| GPU utilization | `GET …/{id}/utilization` | every 5 s |
| Benchmark | `POST /api/v1/inference-endpoint-operations/benchmark`, `GET …/{id}/benchmarks` | every 3 s while the latest run isn't `completed` or `failed` |
| Playground | `POST /api/v1/inference-endpoint-operations/chat` | none |
| Header badge | `GET /api/v1/inference-gateway/status` | every 30 s |
| Network firewall | `GET/POST/PATCH/DELETE /api/v1/network-firewall-{policies,address-lists,port-lists,log-destinations}`, `GET …/policies/{id}/rule-hits`, `GET /api/v1/network-firewall-events` | on demand |

## Handling errors

`client.ts` turns every failure into an `ApiError` with `status`, `code`, `message` and `suggestion`.
Show `message`, and `suggestion` under it when present. Two codes change the UI:

- `global/forbidden` (403 on a change): the user is a `member`. Disable the controls instead of showing an
  error on every click (`isForbidden()` in `client.ts`).
- `global/invalid-api-key` (401): the session's key is no longer active. Send the user to sign in.

The chat operation returns gateway refusals (`auth_rejected`, `guardrail_blocked`, `quota_blocked`) as 200
results, not errors. Show them as outcomes, with `gateway_headers` for detail.

## Auth: lab vs production

In the lab the browser never holds a key. `nginx.reference.conf` injects a console key server-side, and
only for requests that:

1. carry no `Authorization` header,
2. carry `X-Lambda-Console: 1` (set by `client.ts`), and
3. are same-origin by `Sec-Fetch-Site`.

A cross-site page can't send the custom header without a CORS preflight, which nginx never approves. In
production, use your console's existing session. Whatever your API gateway turns it into, the adapter
introspects the resulting key and needs `sub` and `role` back.

## Types

`schema/gateway.ts` and `schema/firewall.ts` are generated from `../contracts/` with
[openapi-typescript](https://github.com/openapi-ts/openapi-typescript) 7.x. Regenerate them rather than
editing by hand.

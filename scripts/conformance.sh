#!/usr/bin/env bash
# Conformance check for any install of the BNK inference adapter, against
# contracts/inference-gateway.openapi.yaml. Needs bash, curl, python3
# (standard library only). Prints one PASS/FAIL line per check; exit 0 only if every check passes.
#
#   export ADAPTER_URL=http://localhost:8080     # the adapter, or a console origin that proxies it
#   export ADMIN_KEY=<an admin key>
#   export MEMBER_KEY=<a non-admin key>           # optional; without it the 403 checks are skipped
#   bash scripts/conformance.sh
#
# Keys reach curl on stdin (-H @-), never on the command line, so they don't show in `ps`.
# It creates one endpoint over the instances GET /api/v1/instances lists. The adapter alone doesn't
# serve that route (the Lambda API does), so when ADAPTER_URL is the adapter itself set
# CONFORMANCE_INSTANCE_IDS (comma-separated) and deletes it at the end, also on failure or Ctrl-C. On a live
# install that is a real Gateway with a real VIP for about a minute. Chat goes through the endpoint;
# benchmark, if your instances allow one, is started and left to finish on its own.
set -uo pipefail
API="${ADAPTER_URL:?set ADAPTER_URL}"
API="${API%/}"
ADMIN="${ADMIN_KEY:?set ADMIN_KEY}"
MEMBER="${MEMBER_KEY:-}"
WAIT_SECONDS="${CONFORMANCE_WAIT_SECONDS:-180}"
NAME="conformance-$(date +%s)-$$"
TMP="$(mktemp -d)"
PASS=0 FAIL=0 SKIP=0 IE_ID=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s: %s\n' "$1" "$2"; }

# req KEY METHOD PATH [JSON] -> status code on stdout, body in $TMP/body. KEY "" sends no Authorization.
req() {
  local key="$1" m="$2" p="$3" d="${4:-}"
  local args=(-s -o "$TMP/body" -w '%{http_code}' -X "$m" "$API$p" --max-time 60)
  [ -n "$d" ] && args+=(-H 'Content-Type: application/json' --data-binary "$d")
  if [ -n "$key" ]; then
    printf 'Authorization: Bearer %s\n' "$key" | curl "${args[@]}" -H @-
  else
    curl "${args[@]}"
  fi
}

# validate SHAPE [ERROR_CODE] < body. Shapes mirror the contract's schemas; prints the problem, if any.
validate() { cat > "$TMP/validate.json"; python3 "$TMP/validate.py" "$TMP/validate.json" "$@"; }
cat > "$TMP/validate.py" <<'PY'
import json, re, sys
body_path, shape = sys.argv[1], sys.argv[2]
want_code = sys.argv[3] if len(sys.argv) > 3 else None
DT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$")
def need(cond, msg):
    if not cond: raise AssertionError(msg)
def obj(v, where, required, optional=(), closed=True):
    need(isinstance(v, dict), f"{where} is not an object")
    missing = [k for k in required if k not in v]
    need(not missing, f"{where} lacks {missing}")
    extra = set(v) - set(required) - set(optional)
    need(not closed or not extra, f"{where} has undocumented fields {sorted(extra)}")
def typ(v, t, where, nullable=False):
    if v is None and nullable: return
    ok = isinstance(v, t) and not (t in (int, float, (int, float)) and isinstance(v, bool))
    need(ok, f"{where} = {v!r} has the wrong type")
def enum(v, values, where): need(v in values, f"{where} = {v!r} not in {values}")
def dt(v, where, nullable=False):
    if v is None and nullable: return
    need(isinstance(v, str) and DT.match(v), f"{where} = {v!r} is not RFC 3339")
def policy(p, w):
    obj(p, w, ["kind", "enabled", "status", "config"], ["status_reason"])
    enum(p["kind"], ["ai_load_balancing", "token_quota", "guardrails", "api_auth"], w + ".kind")
    typ(p["enabled"], bool, w + ".enabled"); enum(p["status"], ["off", "applying", "on", "error"], w + ".status")
    typ(p.get("status_reason"), str, w + ".status_reason", True); typ(p["config"], dict, w + ".config")
    if p["config"]:
        obj(p["config"], w + ".config", ["tokens_per_user", "fallback_model"], ["mode"])
def endpoint(e, w):
    obj(e, w, ["id", "name", "instance_ids", "address", "status", "policies", "created", "models",
               "kubernetes_objects"], ["status_reason"])
    need(re.match(r"^ie-[0-9a-f]{12}$", e["id"] or ""), f"{w}.id = {e['id']!r}")
    need(re.match(r"^[a-z0-9-]{1,40}$", e["name"] or ""), f"{w}.name = {e['name']!r}")
    need(isinstance(e["instance_ids"], list) and e["instance_ids"], f"{w}.instance_ids empty")
    typ(e["address"], str, w + ".address", True)
    enum(e["status"], ["provisioning", "active", "degraded", "error", "deleting"], w + ".status")
    typ(e.get("status_reason"), str, w + ".status_reason", True); dt(e["created"], w + ".created")
    need(isinstance(e["models"], list) and all(isinstance(m, str) for m in e["models"]), f"{w}.models")
    need(isinstance(e["policies"], list) and len(e["policies"]) == 4, f"{w}.policies is not 4 items")
    for i, p in enumerate(e["policies"]): policy(p, f"{w}.policies[{i}]")
    for i, o in enumerate(e["kubernetes_objects"]):
        obj(o, f"{w}.kubernetes_objects[{i}]", ["api_version", "kind", "name", "namespace"])
def run(r, w):
    obj(r, w, ["id", "endpoint_id", "status", "workload", "results", "started"], ["finished", "error"])
    enum(r["status"], ["queued", "running_round_robin", "running_cache_aware", "restoring", "completed",
                       "failed"], w + ".status")
    need(isinstance(r["results"], list) and len(r["results"]) <= 2, f"{w}.results")
    for i, m in enumerate(r["results"]):
        obj(m, f"{w}.results[{i}]", ["mode", "requests", "ttft_p50_ms", "ttft_p99_ms", "latency_p50_ms",
            "latency_p99_ms", "output_tokens_per_s", "prefix_cache_hit_rate", "requests_per_instance"],
            ["errors"])
        need(0 <= m["prefix_cache_hit_rate"] <= 1, f"{w}.results[{i}].prefix_cache_hit_rate")
    dt(r["started"], w + ".started"); dt(r.get("finished"), w + ".finished", True)
try:
    with open(body_path) as f:
        body = json.load(f)
except ValueError:
    print("body is not JSON"); sys.exit(1)
try:
    if shape == "error":
        obj(body, "body", ["error"], closed=False)
        obj(body["error"], "error", ["code", "message"], ["suggestion", "request_id"])
        need(body["error"]["code"] == want_code, f"error.code = {body['error']['code']!r}, want {want_code!r}")
        sys.exit(0)
    obj(body, "body", ["data"])
    d = body["data"]
    if shape == "endpoint": endpoint(d, "data")
    elif shape == "endpoints":
        need(isinstance(d, list), "data is not a list (lists are plain arrays, no pagination)")
        for i, e in enumerate(d): endpoint(e, f"data[{i}]")
    elif shape == "policy": policy(d, "data")
    elif shape == "empty": need(d == {}, f"data = {d!r}, want {{}}")
    elif shape == "status":
        obj(d, "data", ["mode", "bnk_version", "data_plane_healthy", "gpu_instances", "simulated_instances"])
        enum(d["mode"], ["live", "mock"], "data.mode"); typ(d["data_plane_healthy"], bool, "data.data_plane_healthy")
        typ(d["gpu_instances"], int, "data.gpu_instances"); typ(d["simulated_instances"], int, "data.simulated_instances")
    elif shape == "usage":
        obj(d, "data", ["endpoint_id", "since", "rows", "series"]); dt(d["since"], "data.since", True)
        for i, r in enumerate(d["rows"]):
            obj(r, f"data.rows[{i}]", ["user", "model", "requests", "prompt_tokens", "completion_tokens",
                "total_tokens", "downgraded", "refused"], ["quota_remaining"])
        for i, s in enumerate(d["series"]):
            obj(s, f"data.series[{i}]", ["minute", "user", "total_tokens"], closed=False); dt(s["minute"], f"data.series[{i}].minute")
    elif shape == "benchmarks":
        need(isinstance(d, list), "data is not a list")
        for i, r in enumerate(d): run(r, f"data[{i}]")
    elif shape == "benchmark": run(d, "data")
    elif shape == "chat":
        obj(d, "data", ["outcome", "status_code", "latency_ms"], ["ttft_ms", "content", "model", "instance_id",
            "user", "usage", "gateway_headers"])
        enum(d["outcome"], ["served", "downgraded", "auth_rejected", "guardrail_blocked", "error"], "data.outcome")
        typ(d["status_code"], int, "data.status_code"); typ(d["latency_ms"], (int, float), "data.latency_ms")
        gh = d.get("gateway_headers") or {}
        need(all(isinstance(v, str) for v in gh.values()), "data.gateway_headers values must be strings")
    else:
        print(f"unknown shape {shape}"); sys.exit(2)
except AssertionError as exc:
    print(exc); sys.exit(1)
PY

# check NAME WANT_STATUS SHAPE [ERROR_CODE] -- KEY METHOD PATH [JSON]
check() {
  local name="$1" want="$2" shape="$3" code="" got problem
  shift 3
  if [ "$1" != "--" ]; then code="$1"; shift; fi
  shift
  got=$(req "$@") || { fail "$name" "curl failed (is ADAPTER_URL reachable?)"; return 1; }
  if [ "$got" != "$want" ]; then
    fail "$name" "HTTP $got, want $want: $(head -c 300 "$TMP/body")"; return 1
  fi
  if problem=$(validate "$shape" ${code:+"$code"} < "$TMP/body"); then pass "$name"; return 0; fi
  fail "$name" "$problem"; return 1
}
field() { python3 -c "import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'): v=v[int(k)] if isinstance(v, list) else v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))" "$TMP/body" "$1"; }

cleanup() {
  if [ -n "$IE_ID" ]; then
    req "$ADMIN" DELETE "/api/v1/inference-endpoints/$IE_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Conformance of $API against inference-gateway.openapi.yaml"
UNKNOWN=ie-000000000000
EP=/api/v1/inference-endpoints
OPS=/api/v1/inference-endpoint-operations

# --- getInferenceGatewayStatus, and authentication on every operation
check "getInferenceGatewayStatus 200" 200 status -- "$ADMIN" GET /api/v1/inference-gateway/status
for op in "GET /api/v1/inference-gateway/status" "GET $EP" "POST $EP" "GET $EP/$UNKNOWN" "POST $EP/$UNKNOWN" \
          "DELETE $EP/$UNKNOWN" "PATCH $EP/$UNKNOWN/policies/guardrails" "GET $EP/$UNKNOWN/usage" \
          "GET $EP/$UNKNOWN/benchmarks" "POST $OPS/benchmark" "POST $OPS/reset-usage" "POST $OPS/chat"; do
  set -- $op
  check "$1 $2 without a key -> 401" 401 error global/invalid-api-key -- "" "$1" "$2" '{}'
done
MODE=$( { req "$ADMIN" GET /api/v1/inference-gateway/status >/dev/null && field data.mode; } 2>/dev/null || echo unknown)
if [ "$MODE" = mock ]; then
  skip "garbage key -> 401" "mock mode accepts any non-empty key by design"
else
  check "garbage key -> 401" 401 error global/invalid-api-key -- "not-a-real-key-$$" GET "$EP"
fi

# --- pick instances
if [ -n "${CONFORMANCE_INSTANCE_IDS:-}" ]; then
  IDS=$(python3 -c "import json,sys; print(json.dumps([i.strip() for i in sys.argv[1].split(',') if i.strip()]))" \
        "$CONFORMANCE_INSTANCE_IDS")
else
  code=$(req "$ADMIN" GET /api/v1/instances)
  IDS=$(python3 -c "import json,sys
d=json.load(open(sys.argv[1])).get('data') or []
src=lambda i:{t['key']:t['value'] for t in i.get('tags') or []}.get('source','gpu')
ok=[i for i in d if i.get('status') in ('active','booting')]
for s in ('gpu','simulated'):
    pick=[i['id'] for i in ok if src(i)==s]
    if pick: print(json.dumps(pick)); break
else: print('[]')" "$TMP/body" 2>/dev/null || echo '[]')
  # The adapter itself does not serve /api/v1/instances; a console origin proxies it to the Lambda API.
  [ "$code" = 200 ] || echo "note: GET /api/v1/instances answered $code here (pointing at the adapter directly?); set CONFORMANCE_INSTANCE_IDS"
fi
if [ "$IDS" = "[]" ]; then
  fail "pick instances" "no active or booting instances; set CONFORMANCE_INSTANCE_IDS"
  echo; echo "$PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# --- createInferenceEndpoint and its errors
check "createInferenceEndpoint invalid name -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" POST "$EP" "{\"name\":\"Not_Valid\",\"instance_ids\":$IDS}"
check "createInferenceEndpoint empty instance_ids -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" POST "$EP" "{\"name\":\"$NAME\",\"instance_ids\":[]}"
check "createInferenceEndpoint unknown instance -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" POST "$EP" "{\"name\":\"$NAME\",\"instance_ids\":[\"no-such-instance-$$\"]}"
if check "createInferenceEndpoint 200" 200 endpoint -- "$ADMIN" POST "$EP" "{\"name\":\"$NAME\",\"instance_ids\":$IDS}"; then
  IE_ID=$(field data.id)
  [ "$(field data.status)" = provisioning ] && pass "new endpoint starts provisioning" \
    || fail "new endpoint starts provisioning" "status $(field data.status)"
else
  echo; echo "$PASS passed, $FAIL failed, $SKIP skipped (no endpoint, later checks not run)"; exit 1
fi
check "createInferenceEndpoint duplicate name -> 409" 409 error global/duplicate -- \
  "$ADMIN" POST "$EP" "{\"name\":\"$NAME\",\"instance_ids\":$IDS}"

# --- listInferenceEndpoints / getInferenceEndpoint
check "listInferenceEndpoints 200 (plain array)" 200 endpoints -- "$ADMIN" GET "$EP"
if python3 -c "import json,sys; sys.exit(0 if any(e['id']==sys.argv[2] for e in json.load(open(sys.argv[1]))['data']) else 1)" \
     "$TMP/body" "$IE_ID"; then pass "list contains the new endpoint"; else fail "list contains the new endpoint" "missing $IE_ID"; fi
check "getInferenceEndpoint 200" 200 endpoint -- "$ADMIN" GET "$EP/$IE_ID"
check "getInferenceEndpoint unknown id -> 404" 404 error global/object-does-not-exist -- "$ADMIN" GET "$EP/$UNKNOWN"

status=""
for _ in $(seq 1 $((WAIT_SECONDS / 3))); do
  req "$ADMIN" GET "$EP/$IE_ID" >/dev/null
  status=$(field data.status 2>/dev/null)
  [ "$status" = active ] || [ "$status" = error ] && break
  sleep 3
done
[ "$status" = active ] && pass "endpoint becomes active within ${WAIT_SECONDS}s" \
  || fail "endpoint becomes active within ${WAIT_SECONDS}s" "status $status $(field data.status_reason 2>/dev/null)"

# --- updateInferenceEndpoint
check "updateInferenceEndpoint rename 200" 200 endpoint -- "$ADMIN" POST "$EP/$IE_ID" "{\"name\":\"$NAME-r\"}"
[ "$(field data.name)" = "$NAME-r" ] && pass "rename took effect" || fail "rename took effect" "name $(field data.name)"
check "updateInferenceEndpoint invalid name -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" POST "$EP/$IE_ID" '{"name":"Bad Name"}'
check "updateInferenceEndpoint unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" POST "$EP/$UNKNOWN" '{"name":"x"}'

# --- updateInferenceEndpointPolicy
check "updateInferenceEndpointPolicy ai_load_balancing on 200" 200 policy -- \
  "$ADMIN" PATCH "$EP/$IE_ID/policies/ai_load_balancing" '{"enabled":true}'
check "updateInferenceEndpointPolicy ai_load_balancing off 200" 200 policy -- \
  "$ADMIN" PATCH "$EP/$IE_ID/policies/ai_load_balancing" '{"enabled":false}'
check "updateInferenceEndpointPolicy unknown kind -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" PATCH "$EP/$IE_ID/policies/no_such_policy" '{"enabled":true}'
check "updateInferenceEndpointPolicy tokens_per_user under 50 -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" PATCH "$EP/$IE_ID/policies/token_quota" '{"enabled":true,"config":{"tokens_per_user":10,"fallback_model":"m"}}'
check "updateInferenceEndpointPolicy missing enabled -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" PATCH "$EP/$IE_ID/policies/guardrails" '{}'
check "updateInferenceEndpointPolicy unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" PATCH "$EP/$UNKNOWN/policies/guardrails" '{"enabled":true}'

# --- chatThroughInferenceEndpoint
check "chatThroughInferenceEndpoint 200" 200 chat -- "$ADMIN" POST "$OPS/chat" \
  "{\"endpoint_id\":\"$IE_ID\",\"user\":\"conformance\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi.\"}],\"max_tokens\":16}"
check "chatThroughInferenceEndpoint empty messages -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" POST "$OPS/chat" "{\"endpoint_id\":\"$IE_ID\",\"messages\":[]}"
check "chatThroughInferenceEndpoint unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" POST "$OPS/chat" "{\"endpoint_id\":\"$UNKNOWN\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"

# --- getInferenceEndpointUsage / resetInferenceEndpointUsage
check "getInferenceEndpointUsage 200" 200 usage -- "$ADMIN" GET "$EP/$IE_ID/usage"
check "getInferenceEndpointUsage group_by=user 200" 200 usage -- "$ADMIN" GET "$EP/$IE_ID/usage?group_by=user"
check "getInferenceEndpointUsage unknown id -> 404" 404 error global/object-does-not-exist -- "$ADMIN" GET "$EP/$UNKNOWN/usage"
check "resetInferenceEndpointUsage 200" 200 empty -- "$ADMIN" POST "$OPS/reset-usage" "{\"endpoint_id\":\"$IE_ID\"}"
check "resetInferenceEndpointUsage unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" POST "$OPS/reset-usage" "{\"endpoint_id\":\"$UNKNOWN\"}"

# --- listInferenceEndpointBenchmarks / benchmarkInferenceEndpoint
check "listInferenceEndpointBenchmarks 200" 200 benchmarks -- "$ADMIN" GET "$EP/$IE_ID/benchmarks"
check "listInferenceEndpointBenchmarks unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" GET "$EP/$UNKNOWN/benchmarks"
check "benchmarkInferenceEndpoint workload out of bounds -> 400" 400 error global/invalid-parameters -- \
  "$ADMIN" POST "$OPS/benchmark" "{\"endpoint_id\":\"$IE_ID\",\"workload\":{\"conversations\":3}}"
check "benchmarkInferenceEndpoint unknown id -> 404" 404 error global/object-does-not-exist -- \
  "$ADMIN" POST "$OPS/benchmark" "{\"endpoint_id\":\"$UNKNOWN\"}"
# A run needs two GPU instances: 200 starts one, 400 is the documented refusal. Either conforms.
code=$(req "$ADMIN" POST "$OPS/benchmark" "{\"endpoint_id\":\"$IE_ID\",\"workload\":{\"conversations\":4,\"turns\":1}}")
if [ "$code" = 200 ]; then
  if problem=$(validate benchmark < "$TMP/body"); then pass "benchmarkInferenceEndpoint 200 (run started)"; else fail "benchmarkInferenceEndpoint 200" "$problem"; fi
  check "benchmarkInferenceEndpoint while a run is active -> 409" 409 error global/conflict -- \
    "$ADMIN" POST "$OPS/benchmark" "{\"endpoint_id\":\"$IE_ID\"}"
elif [ "$code" = 400 ]; then
  if problem=$(validate error global/invalid-parameters < "$TMP/body"); then pass "benchmarkInferenceEndpoint refused (fewer than 2 GPUs) -> 400"
  else fail "benchmarkInferenceEndpoint 400" "$problem"; fi
  skip "benchmarkInferenceEndpoint 409" "no run could start on these instances"
else
  fail "benchmarkInferenceEndpoint" "HTTP $code: $(head -c 300 "$TMP/body")"
fi

# --- admin-only operations with a member key
if [ -n "$MEMBER" ]; then
  check "member can read (getInferenceEndpoint 200)" 200 endpoint -- "$MEMBER" GET "$EP/$IE_ID"
  check "member createInferenceEndpoint -> 403" 403 error global/forbidden -- \
    "$MEMBER" POST "$EP" "{\"name\":\"$NAME-m\",\"instance_ids\":$IDS}"
  check "member updateInferenceEndpoint -> 403" 403 error global/forbidden -- "$MEMBER" POST "$EP/$IE_ID" '{"name":"member-rename"}'
  check "member updateInferenceEndpointPolicy -> 403" 403 error global/forbidden -- \
    "$MEMBER" PATCH "$EP/$IE_ID/policies/guardrails" '{"enabled":true}'
  check "member benchmarkInferenceEndpoint -> 403" 403 error global/forbidden -- \
    "$MEMBER" POST "$OPS/benchmark" "{\"endpoint_id\":\"$IE_ID\"}"
  check "member resetInferenceEndpointUsage -> 403" 403 error global/forbidden -- \
    "$MEMBER" POST "$OPS/reset-usage" "{\"endpoint_id\":\"$IE_ID\"}"
  check "member deleteInferenceEndpoint -> 403" 403 error global/forbidden -- "$MEMBER" DELETE "$EP/$IE_ID"
else
  skip "403 checks for admin-only operations" "set MEMBER_KEY to a non-admin key"
fi

# --- deleteInferenceEndpoint
check "deleteInferenceEndpoint unknown id -> 404" 404 error global/object-does-not-exist -- "$ADMIN" DELETE "$EP/$UNKNOWN"
if check "deleteInferenceEndpoint 200" 200 endpoint -- "$ADMIN" DELETE "$EP/$IE_ID"; then
  [ "$(field data.status)" = deleting ] && pass "deleted endpoint reports deleting" \
    || fail "deleted endpoint reports deleting" "status $(field data.status)"
  gone=""
  for _ in $(seq 1 40); do
    [ "$(req "$ADMIN" GET "$EP/$IE_ID")" = 404 ] && { gone=1; break; }
    sleep 3
  done
  [ -n "$gone" ] && { pass "deleted endpoint is gone (404)"; IE_ID=""; } || fail "deleted endpoint is gone (404)" "still there after 120s"
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

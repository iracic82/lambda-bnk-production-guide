#!/bin/sh
# TARGET = upstream IP; API_PORT / KV_PORT / KV_REPLAY_PORT = upstream ports (main 8000/20080/20081,
# fallback 8100/20180/20181, sim pods 8000/20080/20081). The relay always listens on 8000/20080/20081.
set -eu
: "${TARGET:?TARGET is required}"
API_PORT="${API_PORT:-8000}"; KV_PORT="${KV_PORT:-20080}"; KV_REPLAY_PORT="${KV_REPLAY_PORT:-20081}"
relay() { socat -d "TCP-LISTEN:$1,fork,reuseaddr,keepalive" "TCP:${TARGET}:$2,keepalive" & }
relay 8000 "$API_PORT"
relay 20080 "$KV_PORT"
relay 20081 "$KV_REPLAY_PORT"
echo "relay -> ${TARGET} api:${API_PORT} kv:${KV_PORT} replay:${KV_REPLAY_PORT}"
# exit (and let Kubernetes restart the pod) if any relay dies
wait -n 2>/dev/null || wait
exit 1

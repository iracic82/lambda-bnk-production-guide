# Byte-level TCP relay (T045): makes a remote GPU VM's vLLM look like a pod to BNK and the F5 Endpoint
# Picker. API, /metrics and the ZMQ KV-event streams all ride TCP, so no protocol awareness is needed.
FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507
RUN apk add --no-cache socat && adduser -D -u 10001 relay
COPY entrypoint.sh /entrypoint.sh
USER relay
EXPOSE 8000 20080 20081
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]

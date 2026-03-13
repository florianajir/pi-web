# Extends the official beszel-agent image with smartmontools for S.M.A.R.T. support.
# The agent binary is statically compiled Go, so it runs fine on Alpine.
FROM henrygd/beszel-agent AS upstream

FROM alpine:3.21
RUN apk add --no-cache smartmontools
COPY --from=upstream /agent /agent
VOLUME ["/var/lib/beszel-agent"]
ENTRYPOINT ["/agent"]

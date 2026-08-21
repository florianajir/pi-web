# Extends the official beszel-agent image with smartmontools for S.M.A.R.T. support.
# The agent binary is statically compiled Go, so it runs fine on Alpine.
# Kept in lockstep with the beszel hub tag in compose.yaml — bump both together.
FROM henrygd/beszel-agent:0.18.8 AS upstream

FROM alpine:3.24
# Exact pin fails the build when the 3.24 branch bumps the package — bump it here.
RUN apk add --no-cache smartmontools=7.5-r0
COPY --from=upstream /agent /agent
VOLUME ["/var/lib/beszel-agent"]
ENTRYPOINT ["/agent"]

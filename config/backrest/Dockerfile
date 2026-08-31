FROM ghcr.io/garethgeorge/backrest:v1.14.1
# postgresql-client is a virtual package, so the pin names its concrete provider.
# The client major MUST match the stack's Postgres server major (compose.yaml
# pins immich-app/postgres:16): a newer pg_dump emits SET parameters the older
# server does not know (e.g. transaction_timeout, added in 17), and the restore
# then aborts on its very first line under ON_ERROR_STOP. Verified in a restore
# drill against a real dump. Bump this together with the server image.
# Exact pins fail the build when the 3.24 branch bumps a package — bump them here.
RUN apk add --no-cache postgresql16-client=16.15-r0 jq=1.8.1-r0

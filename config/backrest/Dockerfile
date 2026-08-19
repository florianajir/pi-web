FROM ghcr.io/garethgeorge/backrest:v1.14.1
# postgresql-client is a virtual package, so the pin names its concrete provider.
# pg_dump 18 dumps the stack's Postgres 16 fine (pg_dump supports older servers).
# Exact pins fail the build when the 3.24 branch bumps a package — bump them here.
RUN apk add --no-cache postgresql18-client=18.6-r0 jq=1.8.1-r0

#!/bin/bash
set -e

# Create a temporary SQL file with environment variables substituted
TEMP_SQL=$(mktemp)
trap "rm -f $TEMP_SQL" EXIT

cat > "$TEMP_SQL" << EOF
-- Create Immich database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'immich') THEN
		CREATE USER immich WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER immich WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE immich'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich')
\gexec
ALTER USER immich WITH SUPERUSER;
GRANT ALL PRIVILEGES ON DATABASE immich TO immich;
ALTER DATABASE immich OWNER TO immich;

-- Create Nextcloud database and user
DO \$\$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nextcloud') THEN
		CREATE USER nextcloud WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	ELSE
		ALTER USER nextcloud WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}';
	END IF;
END
\$\$;
SELECT 'CREATE DATABASE nextcloud'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'nextcloud')
\gexec
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
ALTER DATABASE nextcloud OWNER TO nextcloud;

-- Set proper permissions for Immich user on Immich DB
\connect immich
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
GRANT ALL ON SCHEMA public TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO immich;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO immich;

-- Set proper permissions for Nextcloud user on Nextcloud DB
\connect nextcloud
GRANT ALL ON SCHEMA public TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO nextcloud;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO nextcloud;
EOF

# Execute the SQL file
psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres < "$TEMP_SQL"

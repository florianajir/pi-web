#!/bin/sh
# Registers the local llama-cpp backend as an Open WebUI connection.
#
# The OPENAI_API_BASE_URL / ENABLE_OPENAI_API variables on the open-webui
# service are "PersistentConfig" ones: Open WebUI copies them into its database
# the first time it starts and reads the database from then on, so on an
# instance that already has connections configured the environment is ignored
# and the model never appears in the picker. Hence this bootstrap.
#
# Open WebUI's connection API needs an admin session token, and logins go
# through Authelia SSO (ENABLE_LOGIN_FORM=false), so there is no scriptable
# credential to obtain one with - the config table is the practical route.
#
# Idempotent: it appends the connection only when missing, leaves any other
# connection alone, and only restarts open-webui when it actually changed
# something (the running process caches the config it loaded at startup).
set -eu

. "$(dirname "$0")/lib.sh"

# Service name and port from compose.yaml; both containers sit on the ai network.
LLAMA_URL="http://llama-cpp:8080/v1"

compose() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

psql_owui() {
    compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d open-webui "$@"
}

# 't' when the connection is already registered, or when Open WebUI has not
# persisted its connection list yet - a fresh install seeds it straight from
# the compose environment, which already points at llama-cpp.
connection_present() {
    psql_owui -tAc \
        "SELECT coalesce(
             (SELECT value::jsonb ? '$LLAMA_URL' FROM config WHERE key = 'openai.api_base_urls'),
             true
         );" 2>/dev/null | tr -d ' \r\n'
}

add_connection() {
    # api_base_urls, api_keys and api_configs are parallel: the config for a URL
    # is looked up by its index in the URL list, so all three have to grow
    # together. api_keys is padded first in case it is short - llama-server
    # takes no key anyway, it is unauthenticated on the internal ai network.
    psql_owui -q <<SQL
DO \$\$
DECLARE
    target text := '$LLAMA_URL';
    urls   jsonb;
    keys   jsonb;
    idx    int;
    stamp  bigint := extract(epoch from now())::bigint;
BEGIN
    SELECT value::jsonb INTO urls FROM config WHERE key = 'openai.api_base_urls';
    IF urls IS NULL OR urls ? target THEN
        RETURN;
    END IF;

    idx := jsonb_array_length(urls);

    SELECT coalesce(value::jsonb, '[]'::jsonb) INTO keys FROM config WHERE key = 'openai.api_keys';
    keys := coalesce(keys, '[]'::jsonb);
    WHILE jsonb_array_length(keys) < idx LOOP
        keys := keys || to_jsonb(''::text);
    END LOOP;

    UPDATE config SET value = (urls || to_jsonb(target))::json, updated_at = stamp
        WHERE key = 'openai.api_base_urls';
    UPDATE config SET value = (keys || to_jsonb(''::text))::json, updated_at = stamp
        WHERE key = 'openai.api_keys';
    UPDATE config SET value = jsonb_set(
            coalesce(value::jsonb, '{}'::jsonb),
            ARRAY[idx::text],
            '{"enable": true, "connection_type": "local", "tags": [], "prefix_id": "", "model_ids": []}'::jsonb,
            true
        )::json, updated_at = stamp
        WHERE key = 'openai.api_configs';
    UPDATE config SET value = 'true'::json, updated_at = stamp
        WHERE key = 'openai.enable';
END
\$\$;
SQL
}

main() {
    if ! container_is_running "pi-postgres"; then
        log "postgres is not running; skipping Open WebUI connection bootstrap"
        return 0
    fi

    wait_for_health_warning "pi-open-webui" 60 2 || true

    case "$(connection_present)" in
        t)
            return 0
            ;;
        f)
            ;;
        *)
            log "WARNING: could not read Open WebUI config table; skipping"
            return 0
            ;;
    esac

    log "Registering $LLAMA_URL as an Open WebUI connection"
    if ! add_connection; then
        log "WARNING: failed to register the llama-cpp connection"
        return 0
    fi

    log "Restarting open-webui to pick up the new connection"
    compose restart open-webui >/dev/null 2>&1 || log "WARNING: could not restart open-webui"
    wait_for_health_warning "pi-open-webui" 90 2 || true
}

main "$@"

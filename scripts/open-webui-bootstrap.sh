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
# Model alias llama-cpp serves (LLAMA_ARG_ALIAS in compose.yaml).
LLAMA_MODEL="gemma-4-e2b-it"
# Marker row recording that the defaults below were seeded, so they are applied
# once and never re-imposed - anything changed afterwards in Admin Settings
# stays changed.
DEFAULTS_MARKER="pi-pcloud.local_ai_defaults"
# Bump when the defaults below change, to seed the new ones once.
DEFAULTS_VERSION='"2"'
# The text-to-speech settings carry their own marker, so bumping one group's
# version never re-imposes the other's.
TTS_MARKER="pi-pcloud.local_tts_defaults"
TTS_VERSION='"1"'
# Piper's OpenAI-compatible facade (config/piper), on the same ai network.
TTS_BASE_URL="http://piper:8000/v1"
TTS_VOICE="fr_FR-siwis-medium"

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

# 't' once the given version of a settings group has been seeded.
marker_present() {
    psql_owui -tAc \
        "SELECT EXISTS (
             SELECT 1 FROM config WHERE key = '$1' AND value::text = '$2'
         );" 2>/dev/null | tr -d ' \r\n'
}

# Point Open WebUI's read-aloud button at the local Piper container. Seeded, not
# enforced: the engine has to be set somewhere for the feature to exist at all,
# but this runs once, so switching back to the browser voice - or to another
# voice - in Admin Settings sticks. Per-user voice choices in Settings > Audio
# override the default below anyway, and Piper falls back to it when asked for a
# voice it does not have.
apply_tts_defaults() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('audio.tts.engine',              '"openai"'::json,         extract(epoch from now())::bigint),
    ('audio.tts.openai.api_base_url', '"$TTS_BASE_URL"'::json,  extract(epoch from now())::bigint),
    ('audio.tts.model',               '"$TTS_VOICE"'::json,     extract(epoch from now())::bigint),
    ('audio.tts.voice',               '"$TTS_VOICE"'::json,     extract(epoch from now())::bigint),
    ('$TTS_MARKER',                   '$TTS_VERSION'::json,     extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL
}

# Open WebUI fires an extra, invisible LLM call per message for each of these:
# a chat title, chat tags, follow-up suggestions, a search query rewrite. Against
# a cloud API that is free; against a Pi generating ~10 tok/s it multiplies the
# wait for the answer the user is actually looking at, several times over, all
# competing for the same three CPU threads. Off by default here.
apply_defaults() {
    psql_owui -q <<SQL
INSERT INTO config (key, value, updated_at) VALUES
    ('task.title.enable',                'false'::json,          extract(epoch from now())::bigint),
    ('task.tags.enable',                 'false'::json,          extract(epoch from now())::bigint),
    ('task.follow_up.enable',            'false'::json,          extract(epoch from now())::bigint),
    ('task.query.search.enable',         'false'::json,          extract(epoch from now())::bigint),
    ('task.query.retrieval.enable',      'false'::json,          extract(epoch from now())::bigint),
    ('task.autocomplete.enable',         'false'::json,          extract(epoch from now())::bigint),
    ('memories.background_review.enable','false'::json,          extract(epoch from now())::bigint),
    ('task.model.default',               '"$LLAMA_MODEL"'::json, extract(epoch from now())::bigint),
    ('$DEFAULTS_MARKER',                 '$DEFAULTS_VERSION'::json, extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;
SQL

    # Built-in tools (time, memory, chats, notes, knowledge, channels) are on by
    # default for every model, and their schemas are injected into the prompt of
    # every message sent from the browser - about 5000 tokens, which is ~3
    # minutes of prompt processing on this CPU before the model starts writing.
    # A workspace entry for the model is the only place that default can be
    # turned off, so create one. Attaching tools to a chat explicitly still
    # works.
    psql_owui -q <<SQL
INSERT INTO model (id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active)
SELECT
    '$LLAMA_MODEL',
    (SELECT id FROM "user" WHERE role = 'admin' ORDER BY created_at LIMIT 1),
    NULL,
    '$LLAMA_MODEL',
    '{"capabilities": {"builtin_tools": false}}',
    '{}',
    extract(epoch from now())::bigint,
    extract(epoch from now())::bigint,
    true
WHERE EXISTS (SELECT 1 FROM "user" WHERE role = 'admin')
ON CONFLICT (id) DO UPDATE SET
    meta = jsonb_set(
        coalesce(model.meta::jsonb, '{}'::jsonb),
        '{capabilities,builtin_tools}',
        'false'::jsonb,
        true
    )::text,
    updated_at = extract(epoch from now())::bigint;
SQL
}

main() {
    changed=0

    if ! container_is_running "pi-postgres"; then
        log "postgres is not running; skipping Open WebUI bootstrap"
        return 0
    fi

    wait_for_health_warning "pi-open-webui" 60 2 || true

    case "$(connection_present)" in
        t) ;;
        f)
            log "Registering $LLAMA_URL as an Open WebUI connection"
            if add_connection; then
                changed=1
            else
                log "WARNING: failed to register the llama-cpp connection"
            fi
            ;;
        *)
            log "WARNING: could not read Open WebUI config table; skipping"
            return 0
            ;;
    esac

    if [ "$(marker_present "$DEFAULTS_MARKER" "$DEFAULTS_VERSION")" = "f" ]; then
        log "Seeding low-latency defaults (title/tags/follow-up generation off)"
        if apply_defaults; then
            changed=1
        else
            log "WARNING: failed to seed Open WebUI defaults"
        fi
    fi

    if [ "$(marker_present "$TTS_MARKER" "$TTS_VERSION")" = "f" ]; then
        log "Pointing text-to-speech at Piper ($TTS_VOICE)"
        if apply_tts_defaults; then
            changed=1
        else
            log "WARNING: failed to seed Open WebUI text-to-speech settings"
        fi
    fi

    [ "$changed" = "1" ] || return 0

    log "Restarting open-webui to pick up the new configuration"
    compose restart open-webui >/dev/null 2>&1 || log "WARNING: could not restart open-webui"
    wait_for_health_warning "pi-open-webui" 90 2 || true
}

main "$@"

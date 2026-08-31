#!/bin/sh
# Downloads the GGUF weights llama-cpp serves, into the mounted /models volume.
#
# Runs INSIDE the llama.cpp image (it ships curl), started by
# scripts/llama-cpp-pre-start.sh. It lives here rather than being inlined in
# that script so the quoting stays readable and the download can be re-run by
# hand:
#   docker run --rm -v llama_models:/models \
#     -v ./config/llama-cpp/fetch-models.sh:/fetch-models.sh:ro \
#     --entrypoint sh ghcr.io/ggml-org/llama.cpp:server-bXXXXX /fetch-models.sh
#
# Idempotent: a file whose size already matches the remote one is left alone,
# a partial download is resumed rather than restarted.
set -eu

MODELS_DIR="${MODELS_DIR:-/models}"

# "<destination file>|<url>". The main weights are Google's own QAT build:
# quantisation-aware training recovers most of the quality that plain
# post-training Q4_0 loses, at identical size and speed. Q4_0 specifically (not
# Q4_K_M) because llama.cpp repacks it into the ARM i8mm/dotprod kernels the
# Pi 5's Cortex-A76 has, which is worth more than the quant format difference.
#
# The third file is the multi-token-prediction head, used as the draft model for
# speculative decoding. It is 57MB and roughly doubled generation speed on the
# Pi 5 in testing (5.3 -> 10.6 tok/s), because the expensive part of CPU
# inference is streaming the weights through memory once per token, and one
# pass can verify several drafted tokens. Speculative decoding does not change
# what the model outputs - drafts the main model rejects are discarded.
DOWNLOADS="
gemma-4-E2B-it-qat-Q4_0.gguf|https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf
mmproj-gemma-4-E2B-it.gguf|https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B-it-mmproj.gguf
mtp-gemma-4-E2B-it-Q4_0.gguf|https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/mtp-gemma-4-E2B-it-Q4_0.gguf
"

log() {
    echo "[fetch-models] $*" >&2
}

remote_size() {
    # HuggingFace serves LFS objects through a redirect; the size that matters
    # is the content-length of the final hop, so keep the last one seen.
    curl -fsIL --retry 3 --retry-delay 2 "$1" 2>/dev/null |
        tr -d '\r' |
        awk -F': ' 'tolower($1) == "content-length" { size = $2 } END { print size }'
}

fetch() {
    local dest="$MODELS_DIR/$1"
    local url="$2"
    local expected actual

    expected="$(remote_size "$url" || true)"

    if [ -f "$dest" ]; then
        actual="$(stat -c '%s' "$dest")"
        if [ -z "$expected" ]; then
            log "$1 present, remote size unknown (offline?) - keeping it"
            return 0
        fi
        if [ "$actual" = "$expected" ]; then
            log "$1 up to date ($actual bytes)"
            return 0
        fi
        log "$1 size mismatch (local $actual, remote $expected) - refetching"
        # The .part goes with it: the remote object changed, so any leftover
        # partial belongs to the previous revision and --continue-at - would
        # splice the two together. The byte-count check after the download
        # cannot catch that — a spliced file still totals $expected bytes.
        rm -f "$dest" "$dest.part"
    elif [ -z "$expected" ]; then
        log "ERROR: $1 is missing and $url is unreachable"
        return 1
    fi

    # A partial at least as large as the remote object cannot be a prefix of
    # it, so it is stale rather than resumable.
    if [ -f "$dest.part" ]; then
        actual="$(stat -c '%s' "$dest.part")"
        if [ "$actual" -ge "$expected" ]; then
            log "$1 partial is $actual bytes for a $expected byte object - discarding it"
            rm -f "$dest.part"
        fi
    fi

    log "Downloading $1 ($expected bytes)"
    # No progress meter: this runs from systemd, where it would be thousands of
    # journald lines. The two log lines around it are the progress report.
    curl -fL --retry 3 --retry-delay 2 --no-progress-meter --continue-at - -o "$dest.part" "$url"

    actual="$(stat -c '%s' "$dest.part")"
    if [ "$actual" != "$expected" ]; then
        log "ERROR: $1 downloaded $actual bytes, expected $expected"
        rm -f "$dest.part"
        return 1
    fi

    mv "$dest.part" "$dest"
    log "$1 ready"
}

main() {
    mkdir -p "$MODELS_DIR"

    while IFS='|' read -r name url; do
        [ -n "$name" ] || continue
        fetch "$name" "$url"
    done <<EOF
$DOWNLOADS
EOF
}

main "$@"

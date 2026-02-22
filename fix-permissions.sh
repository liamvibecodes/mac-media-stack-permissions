#!/bin/bash
# fix-permissions.sh — Audit and fix file permissions for Docker media stacks on macOS

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
MEDIA_DIR="$HOME/Media"
FIX_MODE=false
ALLOW_OUTSIDE_MEDIA_DIR=false
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Expected PUID/PGID (current user)
EXPECTED_PUID=$(id -u)
EXPECTED_PGID=$(id -g)

usage() {
    echo "Usage: fix-permissions.sh [OPTIONS]"
    echo ""
    echo "Audit file permissions for your Docker media stack on macOS."
    echo "Dry-run by default. Use --fix to apply changes."
    echo ""
    echo "Options:"
    echo "  --fix         Fix permission issues (chown directories)"
    echo "  --path DIR    Path to media directory (default: ~/Media)"
    echo "  --allow-outside-media-dir  Allow --fix to chown compose mounts outside --path"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  bash fix-permissions.sh"
    echo "  bash fix-permissions.sh --path /Volumes/Media"
    echo "  bash fix-permissions.sh --fix"
    echo "  bash fix-permissions.sh --fix --path /Volumes/Media"
    echo "  bash fix-permissions.sh --fix --allow-outside-media-dir"
    exit "${1:-0}"
}

pass() {
    echo -e "${GREEN}OK${NC}    $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    echo -e "${YELLOW}WARN${NC}  $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}  $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --path)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for --path"
                usage 1
            fi
            MEDIA_DIR="$2"
            shift 2
            ;;
        --allow-outside-media-dir)
            ALLOW_OUTSIDE_MEDIA_DIR=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage 1
            ;;
    esac
done

MEDIA_DIR="${MEDIA_DIR/#\~/$HOME}"

canonical_dir() {
    local input="$1"
    if [[ -d "$input" ]]; then
        (cd "$input" 2>/dev/null && pwd -P)
    else
        return 1
    fi
}

is_path_under() {
    local candidate="$1"
    local root="$2"
    [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]
}

MEDIA_DIR_REAL=""
if [[ -d "$MEDIA_DIR" ]]; then
    MEDIA_DIR_REAL=$(canonical_dir "$MEDIA_DIR" || true)
fi

echo ""
echo "=============================="
echo "  Runtime Detection"
echo "=============================="
echo ""

# Detect runtime
RUNTIME=""
if command -v orbctl &> /dev/null && orbctl status &> /dev/null; then
    RUNTIME="orbstack"
    pass "Runtime: OrbStack detected"
elif command -v docker &> /dev/null && docker info &> /dev/null 2>&1; then
    if docker info 2>/dev/null | grep -q "Docker Desktop"; then
        RUNTIME="docker-desktop"
        pass "Runtime: Docker Desktop detected"
    else
        RUNTIME="docker-other"
        pass "Runtime: Docker detected (not Desktop or OrbStack)"
    fi
else
    fail "No Docker runtime found. Install Docker Desktop or OrbStack first."
    echo ""
    echo "=============================="
    echo "  Summary: $PASS_COUNT passed, $WARN_COUNT warnings, $FAIL_COUNT failed"
    echo "=============================="
    exit 1
fi

echo ""
echo "=============================="
echo "  Compose File"
echo "=============================="
echo ""

# Find docker-compose.yml
COMPOSE_FILE=""
if [[ -f "$MEDIA_DIR/docker-compose.yml" ]]; then
    COMPOSE_FILE="$MEDIA_DIR/docker-compose.yml"
    pass "docker-compose.yml found at $COMPOSE_FILE"
elif [[ -f "$MEDIA_DIR/docker-compose.yaml" ]]; then
    COMPOSE_FILE="$MEDIA_DIR/docker-compose.yaml"
    pass "docker-compose.yaml found at $COMPOSE_FILE"
else
    fail "No docker-compose.yml found in $MEDIA_DIR"
fi

echo ""
echo "=============================="
echo "  Compose Parse Check"
echo "=============================="
echo ""

if [[ -n "$COMPOSE_FILE" ]]; then
    if (cd "$MEDIA_DIR" && docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1); then
        pass "Compose file parses successfully"
    else
        warn "Compose file failed to parse with 'docker compose config'"
    fi
else
    warn "Skipping compose parse check (no compose file)"
fi

echo ""
echo "=============================="
echo "  .env Validation"
echo "=============================="
echo ""

# Check .env file
ENV_FILE="$MEDIA_DIR/.env"
ENV_PUID=""
ENV_PGID=""

if [[ -f "$ENV_FILE" ]]; then
    pass ".env file found"

    # Read PUID from .env
    if grep -q "^PUID=" "$ENV_FILE" 2>/dev/null; then
        ENV_PUID=$(grep "^PUID=" "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        if [[ "$ENV_PUID" == "$EXPECTED_PUID" ]]; then
            pass ".env PUID ($ENV_PUID) matches current user"
        else
            warn ".env PUID ($ENV_PUID) does not match current user ($EXPECTED_PUID)"
        fi
    else
        warn "PUID not set in .env"
    fi

    # Read PGID from .env
    if grep -q "^PGID=" "$ENV_FILE" 2>/dev/null; then
        ENV_PGID=$(grep "^PGID=" "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]')
        if [[ "$ENV_PGID" == "$EXPECTED_PGID" ]]; then
            pass ".env PGID ($ENV_PGID) matches current group"
        else
            warn ".env PGID ($ENV_PGID) does not match current group ($EXPECTED_PGID)"
        fi
    else
        warn "PGID not set in .env"
    fi
else
    warn "No .env file found at $ENV_FILE"
fi

echo ""
echo "=============================="
echo "  PUID/PGID Consistency"
echo "=============================="
echo ""

# Parse PUID/PGID from docker-compose.yml for each service
if [[ -n "$COMPOSE_FILE" ]]; then
    resolve_compose_id() {
        local raw="$1"
        local key="$2"
        local env_value="$3"
        local cleaned
        cleaned=$(echo "$raw" | sed 's/#.*$//' | tr -d '[:space:]"'"'"'')
        if [[ "$cleaned" == "\${$key}" || "$cleaned" == "\$$key" ]]; then
            if [[ -n "$env_value" ]]; then
                echo "$env_value"
            else
                echo "unset"
            fi
        else
            echo "$cleaned"
        fi
    }

    # Extract service names and their PUID/PGID values
    CURRENT_SERVICE=""
    PUID_MISMATCHES=()
    PGID_MISMATCHES=()
    ENTRIES_CHECKED=0

    while IFS= read -r line; do
        # Detect service name (top-level key under services, indented with 2 spaces)
        if echo "$line" | grep -qE '^\s{2}[a-zA-Z][a-zA-Z0-9_-]+:\s*$'; then
            CURRENT_SERVICE=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/://')
        fi

        # Detect PUID (list syntax: - PUID=..., mapping syntax: PUID: ...)
        SVC_PUID=""
        if echo "$line" | grep -qE '^\s*-\s*PUID='; then
            RAW_PUID=$(echo "$line" | sed 's/.*PUID=//')
            SVC_PUID=$(resolve_compose_id "$RAW_PUID" "PUID" "$ENV_PUID")
        elif echo "$line" | grep -qE '^\s*PUID:\s*'; then
            RAW_PUID=$(echo "$line" | sed -E 's/^[[:space:]]*PUID:[[:space:]]*//')
            SVC_PUID=$(resolve_compose_id "$RAW_PUID" "PUID" "$ENV_PUID")
        fi
        if [[ -n "$SVC_PUID" ]]; then
            ENTRIES_CHECKED=$((ENTRIES_CHECKED + 1))
            if [[ "$SVC_PUID" != "$EXPECTED_PUID" ]]; then
                PUID_MISMATCHES+=("$CURRENT_SERVICE uses PUID=$SVC_PUID, expected $EXPECTED_PUID")
            fi
        fi

        # Detect PGID (list syntax: - PGID=..., mapping syntax: PGID: ...)
        SVC_PGID=""
        if echo "$line" | grep -qE '^\s*-\s*PGID='; then
            RAW_PGID=$(echo "$line" | sed 's/.*PGID=//')
            SVC_PGID=$(resolve_compose_id "$RAW_PGID" "PGID" "$ENV_PGID")
        elif echo "$line" | grep -qE '^\s*PGID:\s*'; then
            RAW_PGID=$(echo "$line" | sed -E 's/^[[:space:]]*PGID:[[:space:]]*//')
            SVC_PGID=$(resolve_compose_id "$RAW_PGID" "PGID" "$ENV_PGID")
        fi
        if [[ -n "$SVC_PGID" ]]; then
            ENTRIES_CHECKED=$((ENTRIES_CHECKED + 1))
            if [[ "$SVC_PGID" != "$EXPECTED_PGID" ]]; then
                PGID_MISMATCHES+=("$CURRENT_SERVICE uses PGID=$SVC_PGID, expected $EXPECTED_PGID")
            fi
        fi
    done < "$COMPOSE_FILE"

    if [[ $ENTRIES_CHECKED -eq 0 ]]; then
        warn "No PUID/PGID environment variables found in compose file"
    else
        if [[ ${#PUID_MISMATCHES[@]} -eq 0 ]] && [[ ${#PGID_MISMATCHES[@]} -eq 0 ]]; then
            pass "All $ENTRIES_CHECKED PUID/PGID entries match expected $EXPECTED_PUID:$EXPECTED_PGID"
        else
            for msg in "${PUID_MISMATCHES[@]+"${PUID_MISMATCHES[@]}"}"; do
                [[ -n "$msg" ]] && warn "PUID mismatch: $msg"
            done
            for msg in "${PGID_MISMATCHES[@]+"${PGID_MISMATCHES[@]}"}"; do
                [[ -n "$msg" ]] && warn "PGID mismatch: $msg"
            done
        fi
    fi
else
    warn "Skipping PUID/PGID consistency check (no compose file)"
fi

echo ""
echo "=============================="
echo "  Volume Permissions"
echo "=============================="
echo ""

# Check common media stack directories
DIRS_TO_CHECK=(
    "config"
    "downloads"
    "movies"
    "tv"
    "music"
    "books"
    "media"
    "torrents"
    "usenet"
    "transcode"
    "backup"
    "backups"
)

DIRS_FOUND=0
for dir in "${DIRS_TO_CHECK[@]}"; do
    FULL_PATH="$MEDIA_DIR/$dir"
    if [[ -d "$FULL_PATH" ]]; then
        DIRS_FOUND=$((DIRS_FOUND + 1))
        DIR_UID=$(stat -f "%u" "$FULL_PATH")
        DIR_GID=$(stat -f "%g" "$FULL_PATH")

        if [[ "$DIR_UID" == "$EXPECTED_PUID" ]] && [[ "$DIR_GID" == "$EXPECTED_PGID" ]]; then
            pass "$dir/ owned by you ($DIR_UID:$DIR_GID)"
        else
            fail "$dir/ owned by $DIR_UID:$DIR_GID, expected $EXPECTED_PUID:$EXPECTED_PGID"
            if [[ "$FIX_MODE" == true ]]; then
                DIR_REAL=$(canonical_dir "$FULL_PATH" || true)
                ALLOW_FIX=true
                if [[ "$ALLOW_OUTSIDE_MEDIA_DIR" != true ]] && [[ -n "$MEDIA_DIR_REAL" ]] && [[ -n "$DIR_REAL" ]] && ! is_path_under "$DIR_REAL" "$MEDIA_DIR_REAL"; then
                    ALLOW_FIX=false
                    warn "Skipping fix for $dir/ because it resolves outside $MEDIA_DIR (use --allow-outside-media-dir to override)"
                fi

                if [[ "$ALLOW_FIX" == true ]]; then
                    echo -e "${CYAN}FIX${NC}   Running: chown -R $EXPECTED_PUID:$EXPECTED_PGID $FULL_PATH"
                    sudo chown -R "$EXPECTED_PUID:$EXPECTED_PGID" "$FULL_PATH"
                    pass "$dir/ ownership fixed to $EXPECTED_PUID:$EXPECTED_PGID"
                fi
            fi
        fi
    fi
done

if [[ $DIRS_FOUND -eq 0 ]]; then
    warn "No common media directories found in $MEDIA_DIR"
fi

# Also check any volume mounts from compose file
if [[ -n "$COMPOSE_FILE" ]]; then
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s+- .+:.+'; then
            HOST_PATH=$(echo "$line" | sed 's/^[[:space:]]*- //' | cut -d':' -f1 | tr -d '"'"'"'')
            # Expand variables
            HOST_PATH=$(echo "$HOST_PATH" | sed "s|\\\${MEDIA_DIR}|$MEDIA_DIR|g" | sed "s|\${MEDIA_DIR}|$MEDIA_DIR|g")
            # Skip if it's a named volume (no slash)
            if [[ "$HOST_PATH" == /* ]] && [[ -d "$HOST_PATH" ]]; then
                DIR_UID=$(stat -f "%u" "$HOST_PATH")
                DIR_GID=$(stat -f "%g" "$HOST_PATH")
                HOST_PATH_REAL=$(canonical_dir "$HOST_PATH" || true)
                SHORT_PATH=$(echo "$HOST_PATH" | sed "s|$HOME|~|")
                if [[ "$DIR_UID" == "$EXPECTED_PUID" ]] && [[ "$DIR_GID" == "$EXPECTED_PGID" ]]; then
                    pass "Volume $SHORT_PATH owned by you ($DIR_UID:$DIR_GID)"
                else
                    fail "Volume $SHORT_PATH owned by $DIR_UID:$DIR_GID, expected $EXPECTED_PUID:$EXPECTED_PGID"
                    if [[ "$FIX_MODE" == true ]]; then
                        ALLOW_FIX=true
                        if [[ "$ALLOW_OUTSIDE_MEDIA_DIR" != true ]] && [[ -n "$MEDIA_DIR_REAL" ]] && [[ -n "$HOST_PATH_REAL" ]] && ! is_path_under "$HOST_PATH_REAL" "$MEDIA_DIR_REAL"; then
                            ALLOW_FIX=false
                            warn "Skipping fix for $SHORT_PATH (outside $MEDIA_DIR). Use --allow-outside-media-dir to override."
                        fi

                        if [[ "$ALLOW_FIX" == true ]]; then
                            echo -e "${CYAN}FIX${NC}   Running: chown -R $EXPECTED_PUID:$EXPECTED_PGID $HOST_PATH"
                            sudo chown -R "$EXPECTED_PUID:$EXPECTED_PGID" "$HOST_PATH"
                            pass "Volume $SHORT_PATH ownership fixed"
                        fi
                    fi
                fi
            fi
        fi
    done < "$COMPOSE_FILE"
fi

echo ""
echo "=============================="
echo "  Full Disk Access"
echo "=============================="
echo ""

# Best-effort runtime probe: if a running container can see one of its bind-mounted
# media paths, we treat disk access as effectively working even when TCC rows vary.
runtime_bind_access_probe() {
    if [[ -z "$COMPOSE_FILE" ]]; then
        return 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    local container_ids
    container_ids="$(cd "$MEDIA_DIR" && docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null || true)"
    if [[ -z "$container_ids" ]]; then
        return 1
    fi

    local cid src dst src_real
    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        while IFS='|' read -r src dst; do
            [[ -n "$src" && -n "$dst" ]] || continue
            if [[ ! -e "$src" ]]; then
                continue
            fi

            src_real="$src"
            if [[ -d "$src" ]]; then
                src_real="$(canonical_dir "$src" || echo "$src")"
            fi

            if [[ -n "$MEDIA_DIR_REAL" ]] && ! is_path_under "$src_real" "$MEDIA_DIR_REAL" && [[ "$src" != /Volumes/* ]]; then
                continue
            fi

            if docker exec "$cid" sh -lc "test -e \"$dst\"" >/dev/null 2>&1 || \
               docker exec "$cid" /bin/sh -lc "test -e \"$dst\"" >/dev/null 2>&1; then
                echo "$src|$dst"
                return 0
            fi
        done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{printf "%s|%s\n" .Source .Destination}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
    done <<< "$container_ids"

    return 1
}

# Check Full Disk Access
# macOS stores FDA grants in a TCC database. We can check if the binary is listed,
# but the most reliable method is checking if we can read a protected path.
FDA_APP=""
if [[ "$RUNTIME" == "orbstack" ]]; then
    FDA_APP="OrbStack"
elif [[ "$RUNTIME" == "docker-desktop" ]]; then
    FDA_APP="Docker"
fi

if [[ -n "$FDA_APP" ]]; then
    FDA_CONFIRMED=false
    FDA_PATTERN="docker"
    if [[ "$RUNTIME" == "orbstack" ]]; then
        FDA_PATTERN="orbstack"
    fi

    # First try TCC database (read-only check). macOS versions can store grants
    # under different services, so check for any positive auth row for the runtime.
    TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    if [[ -r "$TCC_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$TCC_DB" "SELECT lower(client),auth_value FROM access;" 2>/dev/null | \
           awk -F'|' -v pat="$FDA_PATTERN" '$1 ~ pat && ($2+0) > 0 {found=1} END{exit(found?0:1)}'; then
            FDA_CONFIRMED=true
            pass "Disk access permission entry found for $FDA_APP in macOS privacy database"
        fi
    fi

    # Fallback: if a running container can access one of its media bind mounts,
    # treat disk access as effectively working even when TCC is not explicit.
    if [[ "$FDA_CONFIRMED" == false ]]; then
        PROBE_RESULT="$(runtime_bind_access_probe || true)"
        if [[ -n "$PROBE_RESULT" ]]; then
            PROBE_SRC="${PROBE_RESULT%%|*}"
            PROBE_DST="${PROBE_RESULT#*|}"
            PROBE_SRC_SHORT="$(echo "$PROBE_SRC" | sed "s|$HOME|~|")"
            pass "Runtime bind-mount probe succeeded for $FDA_APP ($PROBE_SRC_SHORT -> $PROBE_DST)"
            FDA_CONFIRMED=true
        fi
    fi

    if [[ "$FDA_CONFIRMED" == false ]]; then
        warn "Full Disk Access not confirmed for $FDA_APP (best-effort check)"
        echo "      Check: System Settings > Privacy & Security > Full Disk Access"
        echo "      If your containers can read/write media paths, this warning can be ignored."
    fi
else
    warn "Unknown runtime, skipping Full Disk Access check"
fi

echo ""
echo "=============================="
echo "  Summary: $PASS_COUNT passed, $WARN_COUNT warnings, $FAIL_COUNT failed"
echo "=============================="
echo ""

if [[ $FAIL_COUNT -gt 0 ]] && [[ "$FIX_MODE" == false ]]; then
    echo "Run with --fix to automatically resolve permission issues."
    echo ""
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi

exit 0

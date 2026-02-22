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
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  bash fix-permissions.sh"
    echo "  bash fix-permissions.sh --path /Volumes/Media"
    echo "  bash fix-permissions.sh --fix"
    echo "  bash fix-permissions.sh --fix --path /Volumes/Media"
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
            MEDIA_DIR="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

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
    # Extract service names and their PUID/PGID values
    CURRENT_SERVICE=""
    PUID_MISMATCHES=()
    PGID_MISMATCHES=()
    SERVICES_CHECKED=0

    while IFS= read -r line; do
        # Detect service name (top-level key under services, indented with 2 spaces)
        if echo "$line" | grep -qE '^\s{2}[a-zA-Z][a-zA-Z0-9_-]+:\s*$'; then
            CURRENT_SERVICE=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/://')
        fi

        # Detect PUID
        if echo "$line" | grep -qE '^\s+- PUID='; then
            SVC_PUID=$(echo "$line" | sed 's/.*PUID=//' | tr -d '[:space:]"'"'"'')
            # Resolve variable references
            if [[ "$SVC_PUID" == '${PUID}' ]] || [[ "$SVC_PUID" == '$PUID' ]]; then
                SVC_PUID="${ENV_PUID:-unset}"
            fi
            SERVICES_CHECKED=$((SERVICES_CHECKED + 1))
            if [[ "$SVC_PUID" != "$EXPECTED_PUID" ]]; then
                PUID_MISMATCHES+=("$CURRENT_SERVICE uses PUID=$SVC_PUID, expected $EXPECTED_PUID")
            fi
        fi

        # Detect PGID
        if echo "$line" | grep -qE '^\s+- PGID='; then
            SVC_PGID=$(echo "$line" | sed 's/.*PGID=//' | tr -d '[:space:]"'"'"'')
            if [[ "$SVC_PGID" == '${PGID}' ]] || [[ "$SVC_PGID" == '$PGID' ]]; then
                SVC_PGID="${ENV_PGID:-unset}"
            fi
            if [[ "$SVC_PGID" != "$EXPECTED_PGID" ]]; then
                PGID_MISMATCHES+=("$CURRENT_SERVICE uses PGID=$SVC_PGID, expected $EXPECTED_PGID")
            fi
        fi
    done < "$COMPOSE_FILE"

    if [[ $SERVICES_CHECKED -eq 0 ]]; then
        warn "No PUID/PGID environment variables found in compose file"
    else
        if [[ ${#PUID_MISMATCHES[@]} -eq 0 ]] && [[ ${#PGID_MISMATCHES[@]} -eq 0 ]]; then
            pass "All $SERVICES_CHECKED services use consistent PUID/PGID ($EXPECTED_PUID:$EXPECTED_PGID)"
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
                echo -e "${CYAN}FIX${NC}   Running: chown -R $EXPECTED_PUID:$EXPECTED_PGID $FULL_PATH"
                sudo chown -R "$EXPECTED_PUID:$EXPECTED_PGID" "$FULL_PATH"
                pass "$dir/ ownership fixed to $EXPECTED_PUID:$EXPECTED_PGID"
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
                SHORT_PATH=$(echo "$HOST_PATH" | sed "s|$HOME|~|")
                if [[ "$DIR_UID" == "$EXPECTED_PUID" ]] && [[ "$DIR_GID" == "$EXPECTED_PGID" ]]; then
                    pass "Volume $SHORT_PATH owned by you ($DIR_UID:$DIR_GID)"
                else
                    fail "Volume $SHORT_PATH owned by $DIR_UID:$DIR_GID, expected $EXPECTED_PUID:$EXPECTED_PGID"
                    if [[ "$FIX_MODE" == true ]]; then
                        echo -e "${CYAN}FIX${NC}   Running: chown -R $EXPECTED_PUID:$EXPECTED_PGID $HOST_PATH"
                        sudo chown -R "$EXPECTED_PUID:$EXPECTED_PGID" "$HOST_PATH"
                        pass "Volume $SHORT_PATH ownership fixed"
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
    # Try to detect via TCC database (read-only check)
    TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    if [[ -r "$TCC_DB" ]]; then
        if sqlite3 "$TCC_DB" "SELECT client FROM access WHERE service='kTCCServiceSystemPolicyAllFiles'" 2>/dev/null | grep -qi "$FDA_APP"; then
            pass "Full Disk Access granted for $FDA_APP"
        else
            warn "Full Disk Access not confirmed for $FDA_APP"
            echo "      Check: System Settings > Privacy & Security > Full Disk Access"
        fi
    else
        warn "Cannot read TCC database to verify Full Disk Access for $FDA_APP"
        echo "      Manually check: System Settings > Privacy & Security > Full Disk Access"
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

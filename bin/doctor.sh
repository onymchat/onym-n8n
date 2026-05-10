#!/bin/bash
# Verification checklist for the dev-env stack. Each check reports
# PASS/FAIL and the script exits non-zero on any failure. Most checks
# are structural — Mac-host delegation checks pass only on the Mac mini.
set -u

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"

PASS=0
FAIL=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  [\033[32mPASS\033[0m] %s\n" "$label"
        PASS=$((PASS+1))
    else
        printf "  [\033[31mFAIL\033[0m] %s\n" "$label"
        FAIL=$((FAIL+1))
    fi
}

# Read the employee list from employees.json so the checklist scales
# with the org. Fall back to "no employees" if the file is missing.
EMPLOYEES=""
if [ -r employees.json ]; then
    EMPLOYEES=$(jq -r '.employees | keys[]' employees.json 2>/dev/null || echo "")
fi

echo "== images =="
check "dev-env-base image present"  docker image inspect onym-n8n/dev-env-base:latest
check "dev-env-agent image present" docker image inspect onym-n8n/dev-env-agent:latest
check "base image is arm64" \
    bash -c 'test "$(docker image inspect onym-n8n/dev-env-base:latest --format "{{.Architecture}}")" = "arm64"'
check "agent image is arm64" \
    bash -c 'test "$(docker image inspect onym-n8n/dev-env-agent:latest --format "{{.Architecture}}")" = "arm64"'

echo
echo "== containers =="
ALL_CONTAINERS="onym-manager-agent onym-n8n onym-caddy"
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    ALL_CONTAINERS="$ALL_CONTAINERS onym-${LOGIN}-agent"
done <<<"$EMPLOYEES"
for c in $ALL_CONTAINERS; do
    check "$c running" \
        bash -c "test \"\$(docker inspect -f '{{.State.Running}}' $c 2>/dev/null)\" = 'true'"
done

echo
echo "== published ports =="
check "n8n loopback on 5678" bash -c 'echo > /dev/tcp/127.0.0.1/5678'
check "caddy on 80"          bash -c 'echo > /dev/tcp/127.0.0.1/80'
check "caddy on 443"         bash -c 'echo > /dev/tcp/127.0.0.1/443'
# Per-employee SSH ports (only those with sshHostPort configured).
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    PORT=$(jq -r --arg l "$LOGIN" '.employees[$l].sshHostPort // empty' employees.json 2>/dev/null)
    [ -z "$PORT" ] && continue
    check "${LOGIN}-agent sshd on $PORT" bash -c "echo > /dev/tcp/127.0.0.1/$PORT"
done <<<"$EMPLOYEES"

echo
echo "== in-container toolchains =="
for c in $ALL_CONTAINERS; do
    case "$c" in
      onym-n8n|onym-caddy) continue ;;
    esac
    check "$c: claude cli"  docker exec -u agent "$c" claude --version
    check "$c: gh cli"      docker exec -u agent "$c" gh --version
    check "$c: rustc"       docker exec -u agent "$c" rustc --version
done

echo
echo "== claude permission mode =="
# first-run.sh writes ~/.claude/settings.json with bypassPermissions on
# every boot. If this fails, headless `claude --print` will stall waiting
# for a TTY to confirm Edit/Write/Bash, and agent flows produce no diffs.
for c in $ALL_CONTAINERS; do
    case "$c" in
      onym-n8n|onym-caddy) continue ;;
    esac
    check "$c: bypassPermissions in settings.json" \
        docker exec -u agent "$c" \
            jq -e '.permissions.defaultMode == "bypassPermissions"' \
            /home/agent/.claude/settings.json
done

echo
echo "== n8n-agent helpers =="
# Catches the case where the image was rebuilt without picking up new
# scripts, leaving employees with a stale set of /usr/local/bin entries.
for c in $ALL_CONTAINERS; do
    case "$c" in
      onym-n8n|onym-caddy) continue ;;
    esac
    check "$c: n8n-agent-react installed" \
        docker exec "$c" test -x /usr/local/bin/n8n-agent-react
done

echo
echo "== manager dispatcher =="
check "manager: dispatcher present" \
    docker exec onym-manager-agent test -x /usr/local/bin/n8n-manager-dispatch
check "manager: employees.json mounted" \
    docker exec onym-manager-agent test -r /etc/onym/employees.json
check "manager: fan-out key generated" \
    docker exec -u agent onym-manager-agent test -f /home/agent/.ssh/manager-fanout

echo
echo "== manager → employee SSH reachability =="
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    HOST=$(jq -r --arg l "$LOGIN" '.employees[$l].host' employees.json)
    PORT=$(jq -r --arg l "$LOGIN" '.employees[$l].port // 22' employees.json)
    check "manager → $LOGIN ($HOST:$PORT)" \
        docker exec -u agent onym-manager-agent \
            bash -c "ssh -i ~/.ssh/manager-fanout -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/manager-known-hosts -p $PORT agent@$HOST true"
done <<<"$EMPLOYEES"

echo
echo "== n8n health =="
check "n8n /healthz (loopback)" curl -fsS http://127.0.0.1:5678/healthz
# A live key that doesn't match n8n.env on disk means the next force-
# recreate will load the file's value, fail to decrypt every existing
# credential, and surface as "Credentials for 'GitHub API' are not
# set" at workflow runtime. Catch it before that happens.
check "n8n encryption key matches n8n.env" bash -c '
    live=$(docker exec onym-n8n printenv N8N_ENCRYPTION_KEY 2>/dev/null | tr -d "\r\n")
    file=$(awk -F= "/^N8N_ENCRYPTION_KEY=/{print \$2; exit}" n8n.env 2>/dev/null | tr -d "\r\n")
    [ -n "$live" ] && [ -n "$file" ] && [ "$live" = "$file" ]
'

echo
echo "== caddy → n8n =="
check "caddy proxies /healthz" \
    docker exec onym-caddy wget -q --spider --no-check-certificate \
        --header "Host: ${N8N_PUBLIC_HOST:-n8n.example.com}" \
        http://localhost/healthz

echo
echo "---------------------------------------"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

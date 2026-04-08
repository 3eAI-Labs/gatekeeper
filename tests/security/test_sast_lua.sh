#!/bin/bash
# SAST: Static security analysis for Lua plugins
# Tests SEC-01 style checks: no dangerous functions, no hardcoded secrets
# Note: This script detects dangerous Lua patterns like os.execute, loadstring, etc.
# The grep patterns below search for these dangerous functions to ensure they are NOT present.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../../apisix/plugins" && pwd)"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local pattern="$2"
    local should_find="$3"  # "none" = should find zero matches

    local matches
    matches=$(grep -rn "$pattern" "$PLUGIN_DIR" --include="*.lua" 2>/dev/null || true)

    if [ "$should_find" = "none" ]; then
        if [ -z "$matches" ]; then
            echo "  PASS: $desc"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $desc"
            echo "    Found: $matches"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "======================================"
echo "Lua SAST Security Scan"
echo "======================================"
echo ""

echo "--- Command Injection Prevention ---"
check "No os.execute calls" "os\.execute" "none"
check "No io.popen calls" "io\.popen" "none"
check "No os.remove calls" "os\.remove" "none"

echo ""
echo "--- Code Injection Prevention ---"
check "No loadstring with variables" 'loadstring(' "none"
check "No dofile() calls" 'dofile(' "none"

echo ""
echo "--- Hardcoded Secret Detection ---"
check "No hardcoded API keys (sk- pattern)" "sk-[a-zA-Z0-9]\\{20,\\}" "none"

echo ""
echo "--- Unsafe Pattern Detection ---"
check "No ngx.print with unescaped user input" "ngx\.print(" "none"

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

if [ "$FAIL" -gt 0 ]; then
    echo "SAST scan FAILED — fix findings before merge"
    exit 1
else
    echo "SAST scan PASSED"
    exit 0
fi

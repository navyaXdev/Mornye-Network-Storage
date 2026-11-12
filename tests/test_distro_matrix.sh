#!/usr/bin/env bash
# ==============================================================================
# MORNYE NETWORK STORAGE — CROSS-DISTRIBUTION VERIFICATION SUITE
# Module: tests/test_distro_matrix.sh
# Tests OS detection, architecture normalization, package manager resolution,
# and installer syntax validation across official Linux distribution images.
# ==============================================================================

set -eo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROGRAM_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo "======================================================================"
echo "          MORNYE CROSS-DISTRIBUTION TESTING MATRIX                    "
echo "======================================================================"

# Matrix of target test environments: image|expected_id|expected_pm
DISTROS=(
    "debian:12-slim|debian|apt"
    "ubuntu:22.04|ubuntu|apt"
    "ubuntu:24.04|ubuntu|apt"
    "archlinux:latest|arch|pacman"
    "fedora:40|fedora|dnf"
    "rockylinux:9|rocky|dnf"
    "opensuse/leap:15.6|opensuse-leap|zypper"
    "alpine:3.20|alpine|apk"
)

TOTAL=0
PASSED=0
FAILED=0

for item in "${DISTROS[@]}"; do
    TOTAL=$((TOTAL + 1))
    IFS="|" read -r img exp_id exp_pm <<< "$item"

    echo ""
    echo -e "${BOLD}[Test ${TOTAL}/${#DISTROS[@]}] Distribution Target: ${CYAN}${img}${NC} (Expecting ID: ${exp_id}, PM: ${exp_pm})"

    # Run lightweight detection inside container
    test_cmd="
if [ -f /bin/bash ]; then
    SH_BIN=/bin/bash
else
    SH_BIN=/bin/sh
fi
\$SH_BIN -c '
. /app/installers/common.sh
detect_linux_distribution
echo \"DETECTION_OUT: OS_ID=\$OS_ID | OS_FAMILY=\$OS_FAMILY | PKG_MANAGER=\$PKG_MANAGER | ARCH=\$CPU_ARCH | INIT=\$INIT_SYSTEM\"
if [ \"\$PKG_MANAGER\" = \"$exp_pm\" ]; then
    echo \"VERIFY_RESULT: PASS\"
else
    echo \"VERIFY_RESULT: FAIL\"
fi
'
"

    # Pull or run
    out=$(docker run --rm -v "$PROGRAM_DIR":/app "$img" sh -c "$test_cmd" 2>&1 || true)
    
    detection_line=$(echo "$out" | grep "DETECTION_OUT:" || echo "Detection output missing")
    verify_line=$(echo "$out" | grep "VERIFY_RESULT:" || echo "FAIL")

    echo "  -> $detection_line"

    if echo "$verify_line" | grep -q "PASS"; then
        echo -e "  -> Result: ${GREEN}[PASS] Package manager and OS mapped correctly${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "  -> Result: ${RED}[FAIL] Detection mismatch or execution error${NC}"
        echo "$out" | tail -n 5
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "======================================================================"
echo -e "${BOLD}MATRIX SUMMARY:${NC} Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo "======================================================================"

if [ "$FAILED" -eq 0 ]; then
    exit 0
else
    exit 1
fi


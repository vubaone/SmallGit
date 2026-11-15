#!/usr/bin/env bash
# Run in-process SwiftUI interaction and rendering tests without opening the app.
# Usage: scripts/test-ui.sh [--case ClassName[/testMethod]]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_ROOT="${PACKAGE_ROOT}/.build/ui-tests"
TEST_FILTER='^SmallGitUITests[./]'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)
            if [[ $# -lt 2 || ! "$2" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$ ]]; then
                echo 'Expected --case ClassName[/testMethod]' >&2
                exit 2
            fi
            TEST_FILTER="^SmallGitUITests[./]$2($|/)"
            shift 2 ;;
        -h|--help)
            echo 'Usage: scripts/test-ui.sh [--case ClassName[/testMethod]]'
            echo 'Reports and PNGs: SmallGit/.build/ui-tests/results/'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

"${PACKAGE_ROOT}/../make_version.sh" --check

# Only generated artifacts from the previous run are removed.
rm -rf "${RUN_ROOT}/results"
mkdir -p "${RUN_ROOT}"/{tmp,results,git-template} "${PACKAGE_ROOT}/.build/cache"/{clang,swift,swiftpm}
export TMPDIR="${RUN_ROOT}/tmp/"
export SMALLGIT_UI_ARTIFACTS="${RUN_ROOT}/results"
export CLANG_MODULE_CACHE_PATH="${PACKAGE_ROOT}/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${PACKAGE_ROOT}/.build/cache/swift"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${RUN_ROOT}/gitconfig"
export GIT_TEMPLATE_DIR="${RUN_ROOT}/git-template"
export GIT_TERMINAL_PROMPT=0
export TZ=UTC
export LANG=en_US.UTF-8
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
cat > "${GIT_CONFIG_GLOBAL}" <<'CONFIG'
[user]
    name = SmallGit UI Tests
    email = ui@smallgit.test
[commit]
    gpgsign = false
[core]
    hooksPath = /dev/null
CONFIG

{
    sw_vers
    swift --version
    xcodebuild -version
    git --version
} > "${SMALLGIT_UI_ARTIFACTS}/environment.txt"

# An anchored target filter prevents the separate window-ordering tests in
# SmallGitTests from running here. One worker keeps rendering serial while
# using SwiftPM's XCTest xUnit reporter (older toolchains require --parallel).
swift test --package-path "${PACKAGE_ROOT}" \
    --cache-path "${PACKAGE_ROOT}/.build/cache/swiftpm" \
    --parallel --num-workers 1 --filter "${TEST_FILTER}" \
    --xunit-output "${SMALLGIT_UI_ARTIFACTS}/results.xml" \
    2>&1 | tee "${SMALLGIT_UI_ARTIFACTS}/test.log"

# SwiftPM can exit successfully when a filter matches nothing. A typo in a
# case name must not turn a CI run green without exercising any tests.
if ! grep -q '<testcase ' "${SMALLGIT_UI_ARTIFACTS}/results.xml"; then
    echo 'ERROR: no XCTest cases were reported. Check the --case value and toolchain.' >&2
    exit 1
fi
echo "UI test artifacts: ${SMALLGIT_UI_ARTIFACTS}"

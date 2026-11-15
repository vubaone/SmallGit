#!/usr/bin/env bash
# Desktop-free release checks: Python tooling, selected core regressions, UI suite.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_ROOT="${PACKAGE_ROOT}/.build/release-tests"
mkdir -p "${RUN_ROOT}"/{tmp,git-template} "${PACKAGE_ROOT}/.build/cache"/{clang,swift,swiftpm}
export TMPDIR="${RUN_ROOT}/tmp/"
export CLANG_MODULE_CACHE_PATH="${PACKAGE_ROOT}/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${PACKAGE_ROOT}/.build/cache/swift"
export PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${RUN_ROOT}/gitconfig"
export GIT_TEMPLATE_DIR="${RUN_ROOT}/git-template"
export GIT_TERMINAL_PROMPT=0
export SMALLGIT_RUN_LOCAL_SMARTGIT_TESTS=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
cat > "${GIT_CONFIG_GLOBAL}" <<'CONFIG'
[user]
    name = SmallGit Release Tests
    email = release@example.invalid
[commit]
    gpgsign = false
[core]
    hooksPath = /dev/null
CONFIG

"${PACKAGE_ROOT}/../make_version.sh" --check
python3 -m unittest discover -s "${SCRIPT_DIR}/tests" -v

# Explicit allowlist: adding a test that hosts native windows must not silently
# turn a release on the maintainer's main Mac into desktop automation.
CLASSES='AddRepositoriesTests|FileRefreshDuringActionTests|FailureStatusTests|GitCredentialsTests|RepoLayoutTests|TerminalViewModelTests|GitHubCLIAuthTests|CredentialSubmissionTests'
swift test --package-path "${PACKAGE_ROOT}" \
    --cache-path "${PACKAGE_ROOT}/.build/cache/swiftpm" \
    --parallel --num-workers 1 --filter "^SmallGitTests[./](${CLASSES})/" \
    --xunit-output "${RUN_ROOT}/core.xml" 2>&1 | tee "${RUN_ROOT}/core.log"
python3 - "${RUN_ROOT}/core.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = list(root.iter('testcase'))
if not cases or any(list(root.iter(tag)) for tag in ('failure', 'error', 'skipped')):
    sys.exit('Core release checks failed, were skipped, or matched no tests.')
PY
"${SCRIPT_DIR}/test-ui.sh"

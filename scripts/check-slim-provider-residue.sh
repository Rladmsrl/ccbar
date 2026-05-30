#!/usr/bin/env bash
# Guard the Claude-only build against user-visible non-Claude provider residue.
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0

fail() {
    echo "error: $*" >&2
    failures=$((failures + 1))
}

for provider_dir in Codex Gemini Kimi MiniMax; do
    if [[ -e "ClaudeStats/Providers/$provider_dir" ]]; then
        fail "removed provider directory still exists: ClaudeStats/Providers/$provider_dir"
    fi
done

if [[ -d ClaudeStats/Assets.xcassets/Providers ]]; then
    if python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path("ClaudeStats/Assets.xcassets/Providers")
pattern = re.compile(r"codex|gemini|kimi|minimax|openai", re.IGNORECASE)
matches = []
for path in root.rglob("*"):
    if path.name == "Contents.json":
        continue
    if pattern.search(str(path.relative_to(root))):
        matches.append(str(path))

for match in matches:
    print(match)
sys.exit(1 if matches else 0)
PY
    then
        :
    else
        fail "removed provider assets are still present"
    fi
fi

if python3 - <<'PY'
from pathlib import Path
import re
import sys

paths = [
    Path("README.md"),
    Path("ClaudeStats/Localization/Localizable.xcstrings"),
    Path("ClaudeStats/Views/MainWindow/Settings/Sections/TrackingSettingsView.swift"),
    Path("ClaudeStats/Services/ActivitySurfaceCatalog.swift"),
]
pattern = re.compile(r"Claude / Codex|OpenAI Codex|Gemini|Kimi|MiniMax|~/.codex|Codex and Claude|Codex usage")
matches = []
for path in paths:
    text = path.read_text(encoding="utf-8")
    for line_number, line in enumerate(text.splitlines(), start=1):
        if pattern.search(line):
            matches.append(f"{path}:{line_number}:{line}")

for match in matches:
    print(match)
sys.exit(1 if matches else 0)
PY
then
    :
else
    fail "user-facing removed-provider text is still present"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "==> Claude-only provider residue check passed"

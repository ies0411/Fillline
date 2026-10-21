#!/usr/bin/env bash
#
# Install the repository's git hooks. Idempotent: run it as often as you like.
#
#   ./Scripts/install-hooks.sh
#
# The hook is symlinked, not copied, so editing Scripts/hooks/pre-commit takes
# effect immediately. Nothing here needs root, Python, or network access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/Scripts/hooks/pre-commit"

if [ ! -f "$SOURCE" ]; then
    echo "error: $SOURCE is missing." >&2
    exit 1
fi

# `git rev-parse --git-path` is correct for worktrees too, where .git is a file.
hooks_dir="$(cd "$REPO_ROOT" && git rev-parse --git-path hooks)"
case "$hooks_dir" in
    /*) ;;
    *) hooks_dir="$REPO_ROOT/$hooks_dir" ;;
esac
target="$hooks_dir/pre-commit"

chmod +x "$SOURCE"
mkdir -p "$hooks_dir"

if [ -L "$target" ] && [ "$(readlink "$target")" = "$SOURCE" ]; then
    echo "pre-commit hook already installed: $target"
    exit 0
fi

# Never silently destroy a hook the user wrote by hand.
if [ -e "$target" ] && [ ! -L "$target" ]; then
    backup="$target.bak.$(date +%Y%m%d%H%M%S)"
    mv "$target" "$backup"
    echo "Existing hook moved to: $backup"
fi

ln -sfn "$SOURCE" "$target"
echo "Installed:"
echo "  $target -> $SOURCE"
echo
echo "Checks on every commit: staged secrets, swift format, files over 2 MB."
echo "Skip once with: git commit --no-verify"

#!/usr/bin/env bash
# dotfiles/claude/install.sh — ~/.claude/ 설정 설치 스크립트
# 용도: Jarvis fork 사용자가 Claude Code CLI 설정을 자동 설치
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

print_ok()   { echo "  ✅ $1"; }
print_skip() { echo "  ⏭️  $1"; }
print_info() { echo "  ℹ️  $1"; }

echo ""
echo "================================================"
echo "  🤖 Jarvis Claude Code 설정 설치"
echo "================================================"
echo ""

# 1. rules/ 설치
echo "📋 Rules (행동 원칙) 설치 중..."
mkdir -p "$CLAUDE_DIR/rules"
for f in "$SCRIPT_DIR/rules/"*.md; do
  name=$(basename "$f")
  dest="$CLAUDE_DIR/rules/$name"
  if [ -f "$dest" ]; then
    print_skip "$name (이미 존재 — 덮어쓰려면 --force 사용)"
  else
    cp "$f" "$dest"
    print_ok "$name"
  fi
done

# --force 옵션 시 덮어쓰기
if [[ "${1:-}" == "--force" ]]; then
  echo "  ⚠️  --force: 기존 파일 덮어쓰기 모드"
  cp "$SCRIPT_DIR/rules/"*.md "$CLAUDE_DIR/rules/"
  print_ok "rules/ 전체 덮어쓰기 완료"
fi

# 2. prompts/ 설치
echo ""
echo "🔍 Prompts (검증 하네스) 설치 중..."
mkdir -p "$CLAUDE_DIR/prompts"
cp "$SCRIPT_DIR/prompts/verify-harness.md" "$CLAUDE_DIR/prompts/"
print_ok "verify-harness.md"

# 3. hooks/ 설치
echo ""
echo "🪝 Hooks 설치 중..."
mkdir -p "$CLAUDE_DIR/hooks"
for f in "$SCRIPT_DIR/hooks/"*.sh; do
  name=$(basename "$f")
  dest="$CLAUDE_DIR/hooks/$name"
  cp "$f" "$dest"
  chmod +x "$dest"
  print_ok "$name"
done

# 4. commands/ (스킬) 설치
echo ""
echo "⚡ Commands (스킬) 설치 중..."
mkdir -p "$CLAUDE_DIR/commands"
for f in "$SCRIPT_DIR/commands/"*.md; do
  name=$(basename "$f")
  cp "$f" "$CLAUDE_DIR/commands/"
  print_ok "$name"
done

echo ""
echo "================================================"
echo "  🎉 설치 완료!"
echo "================================================"
echo ""
echo "  설치된 항목:"
echo "    📋 Rules:    $(ls "$CLAUDE_DIR/rules/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo "    🔍 Prompts:  $(ls "$CLAUDE_DIR/prompts/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo "    🪝 Hooks:    $(ls "$CLAUDE_DIR/hooks/"*.sh 2>/dev/null | wc -l | tr -d ' ')개"
echo "    ⚡ Commands: $(ls "$CLAUDE_DIR/commands/"*.md 2>/dev/null | wc -l | tr -d ' ')개"
echo ""
echo "  👉 Claude Code CLI를 재시작하면 적용됩니다."
echo ""

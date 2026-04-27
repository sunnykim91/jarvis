#!/bin/bash
# claude-zombie-cleanup.sh — Claude CLI 좀비 세션 자동 정리
# 2026-04-27 주인님 OOM 사고 (938MB cap 800MB) 근본 처방.
#
# 배경:
#   3개월 운영 중 Claude CLI 세션이 누적 (1~2일 uptime + idle), swap 압박 → 봇 GC 지연 → OOM.
#   Mac Mini 16GB 메모리 / swap 5GB. 좀비 4~5개 누적 시 swap 75% 사용, 시스템 압박.
#
# 정책 (보수적):
#   - 대상: Claude CLI 프로세스 (~/.claude/remote/ccd-cli/* 또는 ~/.local/bin/claude)
#   - 좀비 판정: uptime > 12시간 AND CPU 사용률 < 1% (idle)
#   - 회피: 현재 활성 세션 (active-session 파일에 기록된 PID)
#   - SIGTERM (graceful) → 5초 대기 → SIGKILL (강제)
#
# 실행 빈도: 매일 03:00 KST (사용자 작업 영향 최소 시간대)

set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/claude-zombie-cleanup.log"
mkdir -p "$(dirname "$LOG")"

NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$NOW] === Claude zombie cleanup 시작 ===" >> "$LOG"

# 활성 세션 PID (정리 대상에서 제외)
ACTIVE_PID=""
if [[ -f "${HOME}/jarvis/runtime/state/active-session" ]]; then
  # active-session 파일에는 timestamp만 있음. 활성 세션 보호는 ppid 추적으로
  ACTIVE_PID=$(pgrep -f "claude.*--allowedTools" | head -1 || echo "")
fi

ZOMBIES=()
TOTAL_FREED=0

# Claude CLI 프로세스 전수 검사
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  PID=$(echo "$line" | awk '{print $1}')
  ETIME=$(echo "$line" | awk '{print $2}')
  CPU=$(echo "$line" | awk '{print $3}')
  RSS_KB=$(echo "$line" | awk '{print $4}')

  # 현재 활성 세션 보호
  if [[ -n "$ACTIVE_PID" && "$PID" == "$ACTIVE_PID" ]]; then
    continue
  fi

  # uptime 12시간+ 판정 (etime 형식: DD-HH:MM:SS 또는 HH:MM:SS)
  if [[ "$ETIME" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    DAYS="${BASH_REMATCH[1]}"
    HOURS=$((DAYS * 24 + BASH_REMATCH[2]))
  elif [[ "$ETIME" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
    HOURS="${BASH_REMATCH[1]}"
  else
    continue  # 12시간 미만은 정상
  fi

  if (( HOURS < 12 )); then
    continue
  fi

  # CPU 사용률 < 1.0% = idle 판정
  if [[ "$(echo "$CPU < 1.0" | bc -l 2>/dev/null || echo 0)" != "1" ]]; then
    echo "[$NOW] SKIP PID=$PID etime=$ETIME cpu=$CPU% (활성 추정, idle 아님)" >> "$LOG"
    continue
  fi

  ZOMBIES+=("$PID")
  TOTAL_FREED=$((TOTAL_FREED + RSS_KB / 1024))
  echo "[$NOW] ZOMBIE PID=$PID etime=$ETIME cpu=$CPU% rss=$((RSS_KB/1024))MB" >> "$LOG"
done < <(ps -eo pid,etime,%cpu,rss,command | grep -E "ccd-cli|/.local/bin/claude " | grep -v grep)

if (( ${#ZOMBIES[@]} == 0 )); then
  echo "[$NOW] ✅ 좀비 0건 — cleanup 불필요" >> "$LOG"
  exit 0
fi

echo "[$NOW] 좀비 ${#ZOMBIES[@]}개 발견 (회수 예상 ${TOTAL_FREED}MB)" >> "$LOG"

# SIGTERM → 5초 대기 → SIGKILL
for PID in "${ZOMBIES[@]}"; do
  echo "[$NOW]   SIGTERM PID=$PID" >> "$LOG"
  kill -TERM "$PID" 2>/dev/null || true
done

sleep 5

# 잔존 강제 종료
for PID in "${ZOMBIES[@]}"; do
  if kill -0 "$PID" 2>/dev/null; then
    echo "[$NOW]   SIGKILL PID=$PID (SIGTERM 무시)" >> "$LOG"
    kill -KILL "$PID" 2>/dev/null || true
  fi
done

echo "[$NOW] ✅ 정리 완료 — ${#ZOMBIES[@]}개 좀비, 약 ${TOTAL_FREED}MB 회수" >> "$LOG"

# Discord 알림 (선택 — webhooks 설정 시)
WEBHOOK_FILE="${HOME}/jarvis/runtime/config/monitoring.json"
if [[ -f "$WEBHOOK_FILE" ]]; then
  WEBHOOK=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('$WEBHOOK_FILE','utf-8')).webhooks?.['jarvis-system']||'') } catch{}" 2>/dev/null)
  if [[ -n "$WEBHOOK" ]]; then
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"content\":\"🧹 **Claude 좀비 정리** — ${#ZOMBIES[@]}개 종료, 약 ${TOTAL_FREED}MB 회수\"}" \
      "$WEBHOOK" >/dev/null 2>&1 || true
  fi
fi

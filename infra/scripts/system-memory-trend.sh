#!/bin/bash
# system-memory-trend.sh — Mac Mini 메모리 사용 추이 일일 리포트
# 2026-04-27 OOM 사고 근본 처방 — swap·압축·좀비 누수 조기 발견.
#
# 매일 09:00 KST 실행:
#   1) PhysMem (used/unused/wired/compressor) 측정
#   2) Swap 사용률 측정
#   3) Top 5 메모리 점유 프로세스
#   4) Claude CLI 세션 카운트 + uptime 분포
#   5) 24h 추세 (state JSONL append-only)
#   6) Discord #jarvis-system 카드 송출
#
# 출력: ~/jarvis/runtime/state/system-memory-trend.jsonl (시계열 누적)
#       ~/jarvis/runtime/logs/system-memory-trend.log

set -uo pipefail
# v4.45 hotfix: set -e 제거 — pipe SIGPIPE(141) 등 비치명 에러로 스크립트 전체 중단되는 사고 방지.
# 개별 명령 실패는 || echo 0 / || true 로 안전 처리. 끝까지 실행되어 JSONL 적재 보장.

LOG="${HOME}/jarvis/runtime/logs/system-memory-trend.log"
STATE="${HOME}/jarvis/runtime/state/system-memory-trend.jsonl"
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")"

NOW=$(date '+%Y-%m-%d %H:%M:%S')
NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 1) PhysMem (top 출력: "9334M used (2004M wired, 1894M compressor), 6547M unused.")
PHYSMEM_LINE=$(top -l 1 -n 0 2>/dev/null | grep "^PhysMem:" || echo "")
# G 단위 (16384M+ 시) 또는 M 단위 둘 다 처리
USED_RAW=$(echo "$PHYSMEM_LINE" | grep -oE '[0-9]+[GM] used' | head -1)
USED_MB=0
if [[ "$USED_RAW" =~ ([0-9]+)G ]]; then
  USED_MB=$(( ${BASH_REMATCH[1]} * 1024 ))
elif [[ "$USED_RAW" =~ ([0-9]+)M ]]; then
  USED_MB=${BASH_REMATCH[1]}
fi
UNUSED_MB=$(echo "$PHYSMEM_LINE" | grep -oE '[0-9]+M unused' | grep -oE '[0-9]+' || echo 0)
WIRED_MB=$(echo "$PHYSMEM_LINE" | grep -oE '[0-9]+M wired' | grep -oE '[0-9]+' || echo 0)
COMPRESSOR_MB=$(echo "$PHYSMEM_LINE" | grep -oE '[0-9]+M compressor' | grep -oE '[0-9]+' || echo 0)
[[ -z "$UNUSED_MB" ]] && UNUSED_MB=0
[[ -z "$WIRED_MB" ]] && WIRED_MB=0
[[ -z "$COMPRESSOR_MB" ]] && COMPRESSOR_MB=0

# 2) Swap
SWAP_LINE=$(sysctl -n vm.swapusage 2>/dev/null || echo "")
SWAP_TOTAL=$(echo "$SWAP_LINE" | grep -oE 'total = [0-9.]+M' | grep -oE '[0-9.]+' | cut -d. -f1)
SWAP_USED=$(echo "$SWAP_LINE" | grep -oE 'used = [0-9.]+M' | grep -oE '[0-9.]+' | cut -d. -f1)
[[ -z "$SWAP_TOTAL" ]] && SWAP_TOTAL=0
[[ -z "$SWAP_USED" ]] && SWAP_USED=0
SWAP_PCT=0
if (( SWAP_TOTAL > 0 )); then
  SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
fi

# 3) Top 5 메모리 프로세스
TOP_PROCS=$(ps aux | sort -k 4 -rn | head -5 | awk '{printf "%s(%dMB)", substr($11, length($11)-15), $6/1024}' | tr '\n' ',' | sed 's/,$//')

# 4) Claude CLI 세션 카운트 + uptime 분포 (multi-line 출력 방지: \n까지 trim)
CLAUDE_TOTAL=$(pgrep -f "ccd-cli" 2>/dev/null | wc -l | tr -d ' \n')
[[ -z "$CLAUDE_TOTAL" ]] && CLAUDE_TOTAL=0
CLAUDE_LONG=$(ps -eo pid,etime,command 2>/dev/null | grep "ccd-cli" | grep -v grep | awk '$2 ~ /-/ {c++} END{print c+0}' | tr -d ' \n')
[[ -z "$CLAUDE_LONG" ]] && CLAUDE_LONG=0
CLAUDE_FRESH=$((CLAUDE_TOTAL - CLAUDE_LONG))

# 5) 봇 RSS
BOT_PID=$(pgrep -f "discord-bot.js" | head -1 || echo "")
BOT_RSS_MB=0
BOT_UPTIME=""
if [[ -n "$BOT_PID" ]]; then
  BOT_RSS_KB=$(ps -o rss= -p "$BOT_PID" 2>/dev/null | tr -d ' ')
  [[ -n "$BOT_RSS_KB" ]] && BOT_RSS_MB=$((BOT_RSS_KB / 1024))
  BOT_UPTIME=$(ps -o etime= -p "$BOT_PID" 2>/dev/null | tr -d ' ')
fi

# JSONL append (시계열 누적)
JSON=$(cat <<EOF
{"ts":"$NOW_ISO","physmem":{"used_mb":$USED_MB,"unused_mb":$UNUSED_MB,"wired_mb":$WIRED_MB,"compressor_mb":$COMPRESSOR_MB},"swap":{"used_mb":$SWAP_USED,"total_mb":$SWAP_TOTAL,"pct":$SWAP_PCT},"claude_cli":{"total":$CLAUDE_TOTAL,"long_running":$CLAUDE_LONG,"fresh":$CLAUDE_FRESH},"bot":{"pid":"$BOT_PID","rss_mb":$BOT_RSS_MB,"uptime":"$BOT_UPTIME"}}
EOF
)
echo "$JSON" >> "$STATE"

# 7-day retention (최근 7일 = 7개 entries만 유지)
if [[ -f "$STATE" ]]; then
  tail -7 "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE"
fi

# 24h trend (어제 같은 시간 vs 오늘) — 두 번째 줄과 마지막 줄 비교
TREND_DELTA=""
if [[ $(wc -l < "$STATE" | tr -d ' ') -ge 2 ]]; then
  PREV=$(head -1 "$STATE")
  PREV_SWAP=$(echo "$PREV" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s.trim().split('\\n')[0]).swap.used_mb)}catch{}})")
  PREV_UNUSED=$(echo "$PREV" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s.trim().split('\\n')[0]).physmem.unused_mb)}catch{}})")
  if [[ -n "$PREV_SWAP" && -n "$PREV_UNUSED" ]]; then
    SWAP_DELTA=$(( SWAP_USED - PREV_SWAP ))
    UNUSED_DELTA=$(( UNUSED_MB - PREV_UNUSED ))
    SWAP_SIGN=$([ $SWAP_DELTA -ge 0 ] && echo "+" || echo "")
    UNUSED_SIGN=$([ $UNUSED_DELTA -ge 0 ] && echo "+" || echo "")
    TREND_DELTA="\n📈 24h: swap ${SWAP_SIGN}${SWAP_DELTA}MB · unused ${UNUSED_SIGN}${UNUSED_DELTA}MB"
  fi
fi

# 위험 시그널
SIGNALS=""
(( SWAP_PCT >= 70 )) && SIGNALS="${SIGNALS}🔴 swap ${SWAP_PCT}% · "
(( UNUSED_MB < 1024 )) && SIGNALS="${SIGNALS}🔴 unused ${UNUSED_MB}MB · "
(( CLAUDE_LONG >= 3 )) && SIGNALS="${SIGNALS}🟡 좀비 의심 ${CLAUDE_LONG}개 · "
(( BOT_RSS_MB >= 1100 )) && SIGNALS="${SIGNALS}🟡 봇 ${BOT_RSS_MB}MB · "
[[ -z "$SIGNALS" ]] && SIGNALS="🟢 정상 · "
SIGNALS="${SIGNALS%· }"

# 로그
echo "[$NOW] PhysMem used=${USED_MB}MB unused=${UNUSED_MB}MB compressor=${COMPRESSOR_MB}MB | swap=${SWAP_USED}/${SWAP_TOTAL}MB (${SWAP_PCT}%) | Claude CLI total=${CLAUDE_TOTAL} long=${CLAUDE_LONG} | bot ${BOT_RSS_MB}MB | $SIGNALS" >> "$LOG"

# Discord 카드 송출 (jarvis-system)
WEBHOOK_FILE="${HOME}/jarvis/runtime/config/monitoring.json"
if [[ -f "$WEBHOOK_FILE" ]]; then
  WEBHOOK=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('$WEBHOOK_FILE','utf-8')).webhooks?.['jarvis-system']||'') } catch{}" 2>/dev/null)
  if [[ -n "$WEBHOOK" ]]; then
    MSG=$(cat <<EOF
📊 **Mac Mini 메모리 일일 리포트** ($(date '+%m-%d %H:%M'))

**PhysMem**: 사용 ${USED_MB}MB · 여유 ${UNUSED_MB}MB · 압축 ${COMPRESSOR_MB}MB
**Swap**: ${SWAP_USED}/${SWAP_TOTAL}MB (${SWAP_PCT}%)
**Claude CLI**: 총 ${CLAUDE_TOTAL}개 (장기 ${CLAUDE_LONG}개 / 신규 ${CLAUDE_FRESH}개)
**봇**: ${BOT_RSS_MB}MB (uptime ${BOT_UPTIME})
**상태**: ${SIGNALS}${TREND_DELTA}
EOF
)
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "$(node -e "console.log(JSON.stringify({content: process.argv[1]}))" "$MSG")" \
      "$WEBHOOK" >/dev/null 2>&1 || true
  fi
fi

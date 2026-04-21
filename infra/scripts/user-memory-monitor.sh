#!/usr/bin/env bash
# user-memory-monitor.sh — 전체 사용자 user-memory 오염 감지 크론
# 카테고리별 한도 초과 또는 전체 임계치 초과 시 jarvis-system 채널 Discord 경보
# 실행: 매일 08:00 (tasks.json SSoT)
# 교체: boram-memory-monitor.sh 폐기 → 이 파일로 통합 (2026-04-21)

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
USERS_DIR="$BOT_HOME/state/users"
WEBHOOK_FILE="$BOT_HOME/config/monitoring.json"
NODE="${NODE_BIN:-/opt/homebrew/bin/node}"

# 카테고리별 soft limit (이 값 초과 시 경보)
# hard limit은 user-memory.mjs CATEGORY_LIMITS 참조
# monitor는 "경보"만 — 실제 정리는 addFact()가 자동 처리
TOTAL_WARN=250     # 전체 facts 합계 경보 임계치
CAT_WARN_GENERAL=40
CAT_WARN_JARVIS=60
CAT_WARN_WORK=50
CAT_WARN_TRADING=35
CAT_WARN_HEALTH=25
CAT_WARN_FAMILY=20
CAT_WARN_STUDENTS=25

WEBHOOK_URL=$("$NODE" -e "
  try {
    const d = JSON.parse(require('fs').readFileSync('$WEBHOOK_FILE','utf8'));
    console.log(d.webhooks?.['jarvis-system'] || '');
  } catch { console.log(''); }
" 2>/dev/null || echo "")

if [[ -z "$WEBHOOK_URL" ]]; then
  echo "[memory-monitor] ERROR: jarvis-system webhook not found"
  exit 1
fi

KST_NOW=$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M')
ALERTS=""
ALL_OK=true

# 모든 users/*.json 파일 순회
for MEMORY_FILE in "$USERS_DIR"/*.json; do
  if [[ "$MEMORY_FILE" == *.bak* ]]; then continue; fi
  if [[ ! -f "$MEMORY_FILE" ]]; then continue; fi

  RESULT=$("$NODE" -e "
    const fs = require('fs');
    try {
      const d = JSON.parse(fs.readFileSync('$MEMORY_FILE','utf8'));
      const facts = Array.isArray(d.facts) ? d.facts : [];
      const name = d.name || 'unknown';
      const userId = d.userId || 'unknown';
      const total = facts.length;
      const cats = {};
      facts.forEach(f => {
        const c = (typeof f === 'string' ? 'legacy' : f?.category) || 'none';
        cats[c] = (cats[c] || 0) + 1;
      });
      console.log(JSON.stringify({ name, userId, total, cats }));
    } catch(e) { console.log(JSON.stringify({ name:'parse_error', userId:'?', total:0, cats:{} })); }
  " 2>/dev/null)

  NAME=$("$NODE" -e "console.log(JSON.parse('$RESULT').name)" 2>/dev/null || echo "?")
  USER_ID=$("$NODE" -e "console.log(JSON.parse('$RESULT').userId)" 2>/dev/null || echo "?")
  TOTAL=$("$NODE" -e "console.log(JSON.parse('$RESULT').total)" 2>/dev/null || echo "0")

  echo "[memory-monitor] $NAME ($USER_ID): total=$TOTAL"

  # 전체 임계치 체크
  WARNINGS=""
  if [[ "$TOTAL" -gt "$TOTAL_WARN" ]]; then
    WARNINGS="${WARNINGS}\n- 🔴 전체 facts ${TOTAL}개 (경보 임계치 ${TOTAL_WARN})"
    ALL_OK=false
  fi

  # 카테고리별 체크
  check_cat() {
    local cat="$1" warn="$2"
    local count
    count=$("$NODE" -e "
      const r = JSON.parse('$RESULT');
      console.log(r.cats['$cat'] || 0);
    " 2>/dev/null || echo "0")
    if [[ "$count" -gt "$warn" ]]; then
      WARNINGS="${WARNINGS}\n- 🟡 카테고리 [$cat] ${count}개 (경보 ${warn})"
      ALL_OK=false
    fi
  }
  check_cat "general"  "$CAT_WARN_GENERAL"
  check_cat "jarvis"   "$CAT_WARN_JARVIS"
  check_cat "work"     "$CAT_WARN_WORK"
  check_cat "trading"  "$CAT_WARN_TRADING"
  check_cat "health"   "$CAT_WARN_HEALTH"
  check_cat "family"   "$CAT_WARN_FAMILY"
  check_cat "students" "$CAT_WARN_STUDENTS"

  if [[ -n "$WARNINGS" ]]; then
    ALERTS="${ALERTS}\n### 👤 ${NAME} (userId: ${USER_ID})\n- 📊 전체: ${TOTAL}개${WARNINGS}"
  fi
done

if [[ "$ALL_OK" == "true" ]]; then
  echo "[memory-monitor] OK — 모든 사용자 정상"
  exit 0
fi

# 경보 발송
PAYLOAD=$("$NODE" -e "
const alerts = \`$ALERTS\`.replace(/\\\\n/g, '\n');
const now = '$KST_NOW';
const payload = {
  content: null,
  embeds: [{
    title: '⚠️ user-memory 오염 경보',
    description: '하나 이상의 사용자 메모리가 임계치를 초과했습니다.\n\n' + alerts + '\n\n메모리 파일을 확인하고 정리하세요.',
    color: 15548997,
    footer: { text: 'user-memory-monitor · ' + now },
  }]
};
console.log(JSON.stringify(payload));
" 2>/dev/null)

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  --max-time 10)

if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
  echo "[memory-monitor] ALERT sent (http=$HTTP_CODE)"
else
  echo "[memory-monitor] ALERT send failed (http=$HTTP_CODE)"
  exit 1
fi

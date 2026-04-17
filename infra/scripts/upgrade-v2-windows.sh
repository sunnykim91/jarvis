#!/usr/bin/env bash
set -euo pipefail
# upgrade-v2-windows.sh — Jarvis v1.x → v2.0.0 (Windows / Git Bash)
#
# A2 Runtime Migration: BOT_HOME(infra/) → repo_root/runtime/
#
# Usage:
#   cd ~/develop/jarvis && bash infra/scripts/upgrade-v2-windows.sh
#
# 특징:
#   - Idempotent: 이미 마이그레이션됐으면 skip
#   - macOS의 launchctl 대신 PID 파일 기반 프로세스 제어
#   - plist 재작성 없음 (Windows는 Task Scheduler 또는 수동 실행)

# ─── 경로 설정 ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME="${REPO_ROOT}/runtime"
LOG="${REPO_ROOT}/runtime/logs/upgrade-v2.log"

# 현재 BOT_HOME (migration source)
LEGACY="${BOT_HOME:-${REPO_ROOT}/infra}"

# ─── 유틸 ────────────────────────────────────────────────────────────
mkdir -p "${RUNTIME}/logs" 2>/dev/null || true
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG" 2>/dev/null || echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "❌ ERROR: $*"; exit 1; }

# ─── 플랫폼 체크 ─────────────────────────────────────────────────────
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        log "✅ Windows 환경 감지 ($(uname -s))"
        ;;
    Darwin)
        die "macOS는 upgrade-v2.sh를 사용하세요: bash infra/scripts/upgrade-v2.sh"
        ;;
    *)
        log "⚠️ 알 수 없는 플랫폼 ($(uname -s)) — 계속 진행합니다"
        ;;
esac

log "═══════════════════════════════════════════"
log "Jarvis v2.0.0 Upgrade — A2 Runtime Migration (Windows)"
log "═══════════════════════════════════════════"
log "  REPO_ROOT : $REPO_ROOT"
log "  LEGACY    : $LEGACY"
log "  RUNTIME   : $RUNTIME"
log "  LOG       : $LOG"
log ""

# ─── Pre-flight ──────────────────────────────────────────────────────
if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    die "$REPO_ROOT is not a git repo"
fi

# Idempotent check — runtime/state/sessions.json 이미 있으면 skip
if [[ -f "${RUNTIME}/state/sessions.json" ]]; then
    log "✅ 이미 마이그레이션 완료 상태 (runtime/state/sessions.json 존재)"
    log "   BOT_HOME이 runtime/ 으로 설정돼 있는지만 확인하세요:"
    log "   현재 BOT_HOME=$LEGACY"
    if [[ "$LEGACY" == "$RUNTIME" ]]; then
        log "   ✅ BOT_HOME 이미 runtime/ 가리킴"
    else
        log "   ⚠️  BOT_HOME 업데이트 필요 → $RUNTIME"
    fi
    exit 0
fi

if [[ ! -d "$LEGACY" ]]; then
    die "LEGACY($LEGACY) 없음. BOT_HOME 환경변수를 확인하세요."
fi

# ─── Phase 1: 봇 정지 ────────────────────────────────────────────────
log ""
log "━━━ Phase 1: 봇 정지 ━━━"
PID_FILE="${LEGACY}/state/bot.pid"

if [[ -f "$PID_FILE" ]]; then
    BOT_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$BOT_PID" ]] && kill -0 "$BOT_PID" 2>/dev/null; then
        log "  봇 PID=$BOT_PID 정지 중..."
        kill "$BOT_PID" 2>/dev/null || true
        sleep 3
        # 강제 종료 (아직 살아있으면)
        kill -9 "$BOT_PID" 2>/dev/null || true
        log "  ✅ 봇 정지 완료 (PID=$BOT_PID)"
    else
        log "  (봇 이미 미실행 or PID 없음)"
    fi
else
    # PID 파일 없으면 프로세스 이름으로 시도
    if pgrep -f "discord-bot.js" >/dev/null 2>&1; then
        log "  discord-bot.js 프로세스 정지 중..."
        pkill -f "discord-bot.js" 2>/dev/null || true
        sleep 2
        log "  ✅ 정지 완료"
    else
        log "  (봇 미실행)"
    fi
fi

# ─── Phase 2: 데이터 복사 ────────────────────────────────────────────
log ""
log "━━━ Phase 2: 데이터 복사 (infra/ → runtime/) ━━━"

# 복사 대상 디렉토리 (migrate-to-runtime.sh 동일 목록)
RUNTIME_DIRS=(
    state logs config configs wiki context docker board results reports
    backup watchdog inbox teams experiments vault-starter tmp data discord
    prompts rag ledger templates private adr
)

mkdir -p "$RUNTIME"

COPIED=0
SKIPPED=0

for d in "${RUNTIME_DIRS[@]}"; do
    src="${LEGACY}/${d}"
    dst="${RUNTIME}/${d}"
    if [[ -d "$src" ]] && [[ ! -L "$src" ]]; then
        log "  복사 중: $d ..."
        mkdir -p "$dst"
        # rsync 있으면 사용, 없으면 cp -a
        if command -v rsync &>/dev/null; then
            rsync -a --delete "$src/" "$dst/" 2>/dev/null || true
        else
            cp -rf "$src/." "$dst/" 2>/dev/null || true
        fi
        COPIED=$((COPIED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

# .env 계열 루트 파일 복사
find "$LEGACY" -maxdepth 1 -type f 2>/dev/null | while read -r f; do
    name=$(basename "$f")
    case "$name" in
        .env|.env.test|.env.*)
            cp -n "$f" "$RUNTIME/" 2>/dev/null && log "  복사됨: $name" || true
            ;;
    esac
done

log "  ✅ 복사 완료 (복사=$COPIED, 스킵=$SKIPPED)"

# ─── Phase 3: 검증 ───────────────────────────────────────────────────
log ""
log "━━━ Phase 3: 무결성 검증 ━━━"
FAIL=0
for d in "${RUNTIME_DIRS[@]}"; do
    src="${LEGACY}/${d}"
    dst="${RUNTIME}/${d}"
    if [[ -d "$src" ]] && [[ ! -L "$src" ]]; then
        if [[ ! -d "$dst" ]]; then
            log "  MISSING: $dst"
            FAIL=$((FAIL + 1))
            continue
        fi
        src_count=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
        dst_count=$(find "$dst" -type f 2>/dev/null | wc -l | tr -d ' ')
        # dst >= src면 OK (마이그레이션 중 새 파일 생성 가능 — logs 등)
        if (( dst_count < src_count )); then
            log "  MISMATCH: $d (src=$src_count, dst=$dst_count — 파일 누락)"
            FAIL=$((FAIL + 1))
        else
            log "  OK: $d ($src_count files)"
        fi
    fi
done

if [[ "$FAIL" -gt 0 ]]; then
    die "검증 실패 ${FAIL}건 — Phase 2 재실행 필요. 원본($LEGACY)은 안전."
fi
log "  ✅ 전체 검증 통과"

# ─── Phase 4: Git hooks 설치 ─────────────────────────────────────────
log ""
log "━━━ Phase 4: Git hooks 설치 ━━━"
if bash "${REPO_ROOT}/infra/scripts/install-hooks.sh" 2>&1 | tee -a "$LOG"; then
    log "  ✅ Git hooks 설치 완료"
else
    log "  ⚠️  install-hooks 결과 불확실 — 수동 확인 필요"
fi

# ─── Phase 5: BOT_HOME 업데이트 안내 ─────────────────────────────────
log ""
log "━━━ Phase 5: BOT_HOME 업데이트 (수동) ━━━"
if [[ "${LEGACY}" == "${RUNTIME}" ]]; then
    log "  ✅ BOT_HOME 이미 runtime/ 가리킴 — 변경 불필요"
else
    log "  ⚠️  BOT_HOME을 아래 값으로 업데이트하세요:"
    log ""
    log "  현재: BOT_HOME=$LEGACY"
    log "  변경: BOT_HOME=$RUNTIME"
    log ""
    log "  Windows 환경변수 설정 방법:"
    log "    [제어판] → 고급 시스템 설정 → 환경 변수 → BOT_HOME 수정"
    log "    또는 PowerShell: [System.Environment]::SetEnvironmentVariable('BOT_HOME','$RUNTIME','User')"
    log ""
    log "  ⚠️  변경 후 터미널/봇 재시작 필요"
fi

# ─── Phase 6: 봇 재시작 ──────────────────────────────────────────────
log ""
log "━━━ Phase 6: 봇 재시작 ━━━"
RESTART_SCRIPT="${REPO_ROOT}/infra/scripts/bot-self-restart.sh"
if [[ -x "$RESTART_SCRIPT" ]]; then
    log "  bot-self-restart.sh 호출 중..."
    bash "$RESTART_SCRIPT" "v2.0.0 runtime 마이그레이션 완료" 2>&1 | tee -a "$LOG" || \
        log "  ⚠️  재시작 예약 실패 — 수동 기동 필요"
else
    log "  ⚠️  bot-self-restart.sh 없음 — 수동 기동 필요"
fi

# ─── 완료 ────────────────────────────────────────────────────────────
log ""
log "═══════════════════════════════════════════"
log "✅ A2 Migration 완료! (Windows)"
log "═══════════════════════════════════════════"
log "  Runtime : $RUNTIME"
log "  원본    : $LEGACY (보존됨 — 삭제하지 마세요)"
log "  로그    : $LOG"
log ""
log "  검증 명령:"
log "    cat $RUNTIME/state/bot-heartbeat    # heartbeat 최신"
log "    cat $RUNTIME/state/bot.pid          # 봇 PID 확인"
log ""
log "  문제 시 롤백:"
log "    BOT_HOME 환경변수를 $LEGACY 로 되돌리고 봇 재시작"

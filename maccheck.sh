#!/bin/bash
# =====================================================================
#  maccheck — 중고 맥북 현장 점검 (읽기 전용: 설정·파일을 바꾸지 않음)
#
#  실행 (둘 중 편한 것):
#   A) 터미널에  bash  (뒤에 한 칸 띄움) 입력 → 이 파일을 터미널 창에 끌어다 놓기 → Enter
#   B) 터미널에  bash ~/Downloads/maccheck-main/maccheck.sh  입력
#
#  구조: 섹션별로 따로 실행(시간 제한 포함) → 한 섹션이 실패해도 나머지는 계속
#        SSD 수치를 못 읽거나 섹션이 2개 이상 실패하면 비상용(KiemTraMac) 자동 실행
#        어떤 경우에도 마지막에 "스크립트로 확인 못 하는 항목" 안내 출력
#  참고: KiemTraMac (github.com/kiluss2/KiemTraMac), Tirekick (github.com/EverydayOpen/tirekick)
#  macOS 기본 bash 3.2 호환
# =====================================================================

# ---------------- 매물 기대 사양 (매물마다 수정, 비우면 비교 없이 표시만) ----------------
SPEC_CHIP="${MC_CHIP-Apple M1}"
SPEC_MODEL="${MC_MODEL-MacBookAir10,1}"
SPEC_MEM="${MC_MEM-16 GB}"
SPEC_SSD="${MC_SSD-512}"          # GB, 숫자만

# ---------------- 설정 ----------------
PAGE_URL="${MC_PAGE:-https://lota09.github.io/maccheck/t.html}"   # ← 본인 GitHub Pages 주소
KT_TARBALL="https://github.com/kiluss2/KiemTraMac/archive/refs/heads/main.tar.gz"
SECTION_TIMEOUT="${MC_TIMEOUT:-60}"
TTY="${MC_TTY:-/dev/tty}"
# 인코딩·지역 설정 고정: 판매자 맥이 유럽식 소수점(54,7)·한국어 등 어떤 언어여도 숫자·문자열 처리가 같도록
export LC_ALL=C LANG=C
SSD_AVOID_PU=80; SSD_BEST_PU=5
BAT_MIN_MAX=80; BAT_MAX_CYC=1000
PANIC_BAD=3

# ---------------- 준비 ----------------
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$DIR" ] && { xattr -dr com.apple.quarantine "$DIR" 2>/dev/null; chmod +x "$DIR"/bin/* 2>/dev/null; }
TMP="$(mktemp -d /tmp/maccheck.XXXXXX 2>/dev/null || echo /tmp/maccheck.$$)"; mkdir -p "$TMP"
RES="$TMP/results.tsv"; : > "$RES"
FAILED="$TMP/failed.tsv"; : > "$FAILED"
REPORT="${DIR:-/tmp}/maccheck-result-$(date +%Y%m%d-%H%M).txt"   # 바탕화면 접근 권한 팝업을 피하려고 스크립트 폴더에 저장

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_CHK=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_OK=""; C_BAD=""; C_CHK=""; C_DIM=""; C_B=""; C_0=""; fi

TAB=$'\t'
isnum() { case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }
# 기록 형식: 등급 \t 분류 \t 항목 \t 값 \t 대응/메모
rec()  { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RES"; }
ok()   { rec OK   "$@"; }
bad()  { rec BAD  "$@"; }
chk()  { rec CHK  "$@"; }
info() { rec INFO "$@"; }
have_tty() { [ -r "$TTY" ] && ( : < "$TTY" ) 2>/dev/null; }
ask() { printf '%s' "$1"; REPLY=""; if have_tty; then IFS= read -r REPLY < "$TTY"; else echo; fi; }
say() { printf '%s\n' "$*"; }

# system_profiler JSON (종류별 캐시: 한 종류가 실패해도 다른 섹션에 영향 없음)
spj() { local f="$TMP/sp_$1.json"; [ -s "$f" ] || system_profiler -json "$1" > "$f" 2>/dev/null; echo "$f"; }
spv() { plutil -extract "$2" raw -o - "$(spj "$1")" 2>/dev/null; }

HAVE_SUDO=0
SUDO() { if [ "$HAVE_SUDO" = 1 ]; then sudo -n "$@"; else "$@"; fi; }

# =====================================================================
#  섹션들 (각각 별도 서브셸에서 실행됨)
# =====================================================================

# 일련번호 → 생산 시기 (구형 12자리, 2020년대 기준)
decode_serial() {
  local s="$1" yc wc Y="CDFGHJKLMNPQRSTVWXYZ" W="123456789CDFGHJKLMNPQRTVWXY" yi wi year half week
  [ ${#s} -eq 12 ] || { echo "신형 무작위 일련번호(생산 시기 해독 불가)"; return; }
  yc="${s:3:1}"; wc="${s:4:1}"
  yi="${Y%%$yc*}"; yi=${#yi}; wi="${W%%$wc*}"; wi=${#wi}
  [ "$yi" -ge 20 ] || [ "$wi" -ge 27 ] && { echo "해독 불가"; return; }
  year=$(( 2020 + yi / 2 )); half=$(( yi % 2 )); week=$(( wi + 1 + half * 26 ))
  echo "약 ${year}년 ${week}주차 생산"
}

sec_hw() {
  local G="기기" CHIP MODEL MEM SERIAL MODELNO NAME REGION RN KIND SSD_BYTES SSD_GB LO HI
  CHIP="$(spv SPHardwareDataType SPHardwareDataType.0.chip_type)"
  MODEL="$(spv SPHardwareDataType SPHardwareDataType.0.machine_model)"
  MEM="$(spv SPHardwareDataType SPHardwareDataType.0.physical_memory)"
  SERIAL="$(spv SPHardwareDataType SPHardwareDataType.0.serial_number)"
  MODELNO="$(spv SPHardwareDataType SPHardwareDataType.0.model_number)"
  NAME="$(spv SPHardwareDataType SPHardwareDataType.0.machine_name)"

  cmp_spec() { # 항목 실제값 기대값
    if [ -z "$2" ]; then chk "$G" "$1" "읽기 실패" "애플 메뉴 → 이 Mac에 관하여에서 직접 확인"
    elif [ -z "$3" ]; then info "$G" "$1" "$2" ""
    elif [ "$2" = "$3" ]; then ok "$G" "$1" "$2" ""
    else bad "$G" "$1" "$2" "매물 사양($3)과 다름 → 판매자에게 확인, 다르면 구매 중단"; fi
  }
  cmp_spec "칩" "$CHIP" "$SPEC_CHIP"
  cmp_spec "모델 ID" "$MODEL" "$SPEC_MODEL"
  cmp_spec "메모리" "$MEM" "$SPEC_MEM"

  if [ -n "$SERIAL" ]; then
    info "$G" "일련번호" "$SERIAL" "$(decode_serial "$SERIAL") · checkcoverage.apple.com 에서 모델명 대조 가능"
  else chk "$G" "일련번호" "읽기 실패" "이 Mac에 관하여에서 확인"; fi

  if [ -n "$MODELNO" ]; then
    REGION=""; local R2 R1
    R2="$(printf '%s' "$MODELNO" | sed -nE 's#.*([A-Z]{2})/A$#\1#p')"
    R1="$(printf '%s' "$MODELNO" | sed -nE 's#.*([A-Z])/A$#\1#p')"
    case "$R2" in KH|LL|CH|ZP|TA|FN|ZA|DK|KS|RS|SM|TU|AE|HN|LZ|PP|ZM|PL|CZ|MG|SL|TH|BZ|CL|AB|FD|HB|ID|LE|MY|PA|PO|RU|SA|SO|TQ|VC|ZE|ZS) REGION="$R2";; *) REGION="$R1";; esac
    case "$REGION" in
      KH) RN="한국";; LL) RN="미국";; J) RN="일본";; CH) RN="중국";; ZP) RN="홍콩";; TA) RN="대만";;
      B) RN="영국";; D) RN="독일";; FN) RN="프랑스";; ZA) RN="싱가포르";; DK) RN="덴마크";; PP) RN="필리핀";; T) RN="이탈리아";; Y) RN="스페인";; ZM) RN="말레이시아";; X) RN="호주";; C) RN="캐나다";; *) RN="기타(${REGION:-?})";;
    esac
    case "$MODELNO" in Z*) KIND="주문제작(CTO)";; *) KIND="기본형";; esac
    info "$G" "모델 번호" "$MODELNO" "$KIND · 판매국가 $RN"
  fi

  SSD_BYTES="$(diskutil info -plist disk0 2>/dev/null | plutil -extract TotalSize raw -o - - 2>/dev/null)"
  if isnum "$SSD_BYTES"; then
    SSD_GB=$(( SSD_BYTES / 1000000000 ))
    if isnum "$SPEC_SSD"; then
      LO=$(( SPEC_SSD * 93 / 100 )); HI=$(( SPEC_SSD * 103 / 100 ))
      if [ "$SSD_GB" -ge "$LO" ] && [ "$SSD_GB" -le "$HI" ]; then ok "$G" "저장공간" "${SSD_GB}GB" "${SPEC_SSD}GB 모델"
      else bad "$G" "저장공간" "${SSD_GB}GB" "매물 사양(${SPEC_SSD}GB)과 다름 → 구매 중단 또는 재협상"; fi
    else info "$G" "저장공간" "${SSD_GB}GB" ""; fi
  else chk "$G" "저장공간" "읽기 실패" "이 Mac에 관하여 → 저장 공간에서 확인"; fi

  info "$G" "macOS" "$(sw_vers -productVersion 2>/dev/null)" ""
  return 0
}

sec_lock() {
  local G="잠금" AL NACC MDM_OUT ABM_OUT ORG
  local LOGGED=0 FMM=0
  AL="$(spv SPHardwareDataType SPHardwareDataType.0.activation_lock_status)"
  NACC="$(defaults read MobileMeAccounts Accounts 2>/dev/null | grep -c 'AccountID')"
  isnum "$NACC" && [ "$NACC" -gt 0 ] && LOGGED=1
  nvram fmm-mobileme-token-FMM >/dev/null 2>&1 && FMM=1
  [ "$LOGGED" = 1 ] && touch "$TMP/seller_login"
  local FINAL="마지막에 판매자가 '모든 콘텐츠 및 설정 지우기'(Apple ID 암호 입력) → 재설정 화면에서 Apple ID 요구 없으면 OK"

  # 판매자가 로그인한 상태라면 잠금·나의 Mac 찾기가 켜져 있는 건 정상적인 상황
  if [ "$LOGGED" = 1 ]; then
    info "$G" "iCloud 로그인" "${NACC}개 계정 (판매자 로그인 상태)" "하드웨어 점검에는 영향 없음 · 결제 전 해제만 확인"
  else ok "$G" "iCloud 로그인" "없음" ""; fi

  case "$AL" in
    *disabled*) ok "$G" "활성화 잠금" "꺼짐" "";;
    *enabled*)
      if [ "$LOGGED" = 1 ]; then
        chk "$G" "활성화 잠금" "켜짐(판매자 로그인 상태)" "$FINAL. 판매자가 Apple ID 암호를 모르면 구매 중단"
      else
        bad "$G" "활성화 잠금" "켜짐(로그인 계정 없음)" "이 맥에 없는 다른 사람 계정에 잠김 → 구매 중단"
      fi;;
    *) chk "$G" "활성화 잠금" "읽기 실패" "⌥+애플메뉴 → 시스템 정보 → 하드웨어 → 활성화 잠금 상태 확인. 어쨌든 $FINAL";;
  esac

  if [ "$FMM" = 1 ] && [ "$LOGGED" = 1 ]; then
    info "$G" "나의 Mac 찾기" "켜짐(판매자 로그인 상태)" "초기화하면 함께 해제됨"
  elif [ "$FMM" = 1 ]; then
    chk "$G" "나의 Mac 찾기" "켜짐(로그인 계정 없음)" "활성화 잠금과 함께 판단. 초기화 후 Apple ID 요구 여부로 최종 확인"
  else ok "$G" "나의 Mac 찾기" "꺼짐" ""; fi

  MDM_OUT="$(profiles status -type enrollment 2>&1)"
  if printf '%s' "$MDM_OUT" | grep -qi ': *Yes'; then
    bad "$G" "MDM(회사 관리)" "등록됨" "회사 관리 기기 → 구매 중단"
  elif [ "$(printf '%s\n' "$MDM_OUT" | grep -ci ': *No')" -ge 2 ]; then
    ok "$G" "MDM(회사 관리)" "없음" ""
  else
    chk "$G" "MDM(회사 관리)" "결과 해석 불가" "시스템 설정 → 일반 → 기기 관리에 프로파일이 없는지 확인"
  fi

  if [ "$HAVE_SUDO" = 1 ]; then
    ABM_OUT="$(sudo -n profiles show -type enrollment 2>&1)"
    if printf '%s' "$ABM_OUT" | grep -qiE 'OrganizationName|ConfigurationURL|IsMDMUnremovable'; then
      ORG="$(printf '%s' "$ABM_OUT" | sed -nE 's/.*OrganizationName *= *"?([^";]*)"?;?.*/\1/p' | head -1)"
      bad "$G" "회사 배정(ABM)" "배정됨: ${ORG:-이름 불명}" "초기화해도 회사 관리로 다시 묶임 → 구매 중단"
    elif printf '%s' "$ABM_OUT" | grep -qiE 'not DEP enabled|no configuration|Client is not'; then
      ok "$G" "회사 배정(ABM)" "없음" ""
    else
      chk "$G" "회사 배정(ABM)" "확인 실패" "인터넷(핫스팟) 확인. 안 되면 마지막 초기화 때 '원격 관리' 화면이 안 뜨는지로 확인"
    fi
  else
    chk "$G" "회사 배정(ABM)" "건너뜀(비밀번호 없음)" "마지막 초기화 때 '원격 관리' 화면이 안 뜨는지로 확인"
  fi

  case "$(csrutil status 2>/dev/null)" in
    *enabled.*) ok  "$G" "보안(SIP)" "켜짐" "";;
    *disabled*) chk "$G" "보안(SIP)" "꺼짐" "개조 흔적일 수 있음 → 판매자에게 이유 질문";;
    *)          chk "$G" "보안(SIP)" "읽기 실패" "무시해도 됨 (초기화하면 기본값)";;
  esac
  return 0
}

get_smartctl() {
  local S
  if command -v smartctl >/dev/null 2>&1; then command -v smartctl; return 0; fi
  for S in "$DIR/bin/smartctl" "$DIR/smartctl"; do
    [ -f "$S" ] || continue
    "$S" --version >/dev/null 2>&1 || { xattr -c "$S" 2>/dev/null; codesign -s - -f "$S" >/dev/null 2>&1; }
    "$S" --version >/dev/null 2>&1 && { echo "$S"; return 0; }
  done
  return 1
}

sec_ssd() {
  local G="SSD" SCTL SMJ="$TMP/sm.json" HAVE=0 SMART_SP CW SPARE SPTH PU MEDIA DUW POH UNSAFE WTT CTT REASONS TBW
  SCTL="$(get_smartctl)"
  if [ -n "$SCTL" ]; then
    "$SCTL" -j -a disk0 > "$SMJ" 2>/dev/null
    if ! plutil -extract nvme_smart_health_information_log.percentage_used raw -o - "$SMJ" >/dev/null 2>&1 && [ "$HAVE_SUDO" = 1 ]; then
      sudo -n "$SCTL" -j -a disk0 > "$SMJ" 2>/dev/null
    fi
    plutil -extract nvme_smart_health_information_log.percentage_used raw -o - "$SMJ" >/dev/null 2>&1 && HAVE=1
  fi
  sm() { plutil -extract "nvme_smart_health_information_log.$1" raw -o - "$SMJ" 2>/dev/null; }

  if [ "$HAVE" = 1 ]; then
    CW="$(sm critical_warning)"; SPARE="$(sm available_spare)"; SPTH="$(sm available_spare_threshold)"
    PU="$(sm percentage_used)"; MEDIA="$(sm media_errors)"; DUW="$(sm data_units_written)"
    POH="$(sm power_on_hours)"; UNSAFE="$(sm unsafe_shutdowns)"; WTT="$(sm warning_temp_time)"; CTT="$(sm critical_comp_time)"
    REASONS=""
    isnum "$CW"    && [ "$CW" -ne 0 ]    && REASONS="${REASONS}경고 플래그 $CW; "
    isnum "$MEDIA" && [ "$MEDIA" -gt 0 ] && REASONS="${REASONS}데이터 오류 ${MEDIA}건; "
    isnum "$SPARE" && isnum "$SPTH" && [ "$SPARE" -le "$SPTH" ] && REASONS="${REASONS}예비공간 ${SPARE}%≤하한 ${SPTH}%; "
    isnum "$PU"    && [ "$PU" -ge "$SSD_AVOID_PU" ] && REASONS="${REASONS}수명 ${PU}% 사용; "
    if [ -n "$REASONS" ]; then
      echo "절대 피해야함" > "$TMP/ssd_verdict"
      bad "$G" "SSD 판정" "절대 피해야함" "${REASONS%; } → 네고 말고 구매 중단 (SSD는 메인보드 일체형)"
    elif isnum "$PU" && [ "$PU" -le "$SSD_BEST_PU" ] && [ "$SPARE" = 100 ]; then
      echo "최고수준" > "$TMP/ssd_verdict"; ok "$G" "SSD 판정" "최고수준" ""
    else
      echo "무난함" > "$TMP/ssd_verdict"; ok "$G" "SSD 판정" "무난함" ""
    fi
    TBW="$(awk -v d="${DUW:-0}" 'BEGIN{printf "%.1f", d*512000/1e12}')"
    info "$G" "수명 사용률" "${PU}%" "≤${SSD_BEST_PU}% 최고 / ≥${SSD_AVOID_PU}% 피해야함"
    info "$G" "누적 쓰기량" "${TBW} TB" ""
    info "$G" "예비공간 / 오류 / 경고" "${SPARE}% / ${MEDIA}건 / ${CW}" "100% / 0 / 0 이 정상"
    info "$G" "사용 시간 / 비정상 종료" "${POH}시간 / ${UNSAFE}회" "참고용"
    if { isnum "$WTT" && [ "$WTT" -gt 0 ]; } || { isnum "$CTT" && [ "$CTT" -gt 0 ]; }; then
      chk "$G" "과열 이력" "경고 ${WTT}분 / 위험 ${CTT}분" "참고용. 다른 항목이 정상이면 감수 가능"
    fi
  else
    touch "$TMP/need_emergency"
    SMART_SP="$(spv SPNVMeDataType SPNVMeDataType.0._items.0.smart_status)"
    [ -z "$SMART_SP" ] && SMART_SP="$(diskutil info -plist disk0 2>/dev/null | plutil -extract SMARTStatus raw -o - - 2>/dev/null)"
    case "$SMART_SP" in
      *[Ff]ail*) echo "절대 피해야함" > "$TMP/ssd_verdict"
                 bad "$G" "SSD 판정" "절대 피해야함" "SMART 상태 Failing → 구매 중단";;
      *[Vv]erified*) chk "$G" "SSD 판정" "수명 수치 확인 불가" "비상용 점검이 자동 실행됨. 그것도 실패하면 SMART 정상(Verified) 근거로 감수";;
      *) chk "$G" "SSD 판정" "확인 불가" "비상용 점검이 자동 실행됨";;
    esac
  fi
  return 0
}

sec_bat() {
  local G="배터리" PF i B="" CYC HEALTH BMAX BAT_IO DESIGN RAWMAX PFAIL
  PF="$(spj SPPowerDataType)"
  i=0; while [ $i -le 6 ]; do
    plutil -extract "SPPowerDataType.$i.sppower_battery_health_info" json -o - "$PF" >/dev/null 2>&1 \
      && { B="SPPowerDataType.$i.sppower_battery_health_info"; break; }
    i=$((i+1)); done
  if [ -n "$B" ]; then
    CYC="$(spv SPPowerDataType "$B.sppower_battery_cycle_count")"
    HEALTH="$(spv SPPowerDataType "$B.sppower_battery_health")"
    BMAX="$(spv SPPowerDataType "$B.sppower_battery_health_maximum_capacity")"; BMAX="${BMAX%\%}"
  fi
  BAT_IO="$(ioreg -rn AppleSmartBattery 2>/dev/null)"
  iov() { printf '%s' "$BAT_IO" | sed -nE "s/.*\"$1\" = ([0-9]+).*/\1/p" | head -1; }
  DESIGN="$(iov DesignCapacity)"; RAWMAX="$(iov AppleRawMaxCapacity)"; PFAIL="$(iov PermanentFailureStatus)"

  case "$HEALTH" in
    Good|Normal|정상) ok "$G" "상태" "$HEALTH" "";;
    "") chk "$G" "상태" "읽기 실패" "시스템 설정 → 배터리 → 배터리 성능 상태 ⓘ 에서 확인";;
    *)  chk "$G" "상태" "$HEALTH" "교체 권장 상태 → 교체 전제라면 네고 사유";;
  esac
  isnum "$PFAIL" && [ "$PFAIL" -ne 0 ] && bad "$G" "영구 고장 플래그" "$PFAIL" "충전 회로 이상 가능 → 구매 중단 권장"
  if isnum "$BMAX"; then
    if [ "$BMAX" -ge "$BAT_MIN_MAX" ]; then ok "$G" "최대 용량" "${BMAX}%" ""
    else chk "$G" "최대 용량" "${BMAX}%" "교체 필요 수준 → 배터리값(5~8만원)만큼 네고"; fi
  else chk "$G" "최대 용량" "읽기 실패" "시스템 설정 → 배터리 → 배터리 성능 상태 ⓘ"; fi
  if isnum "$CYC"; then
    if [ "$CYC" -le "$BAT_MAX_CYC" ]; then ok "$G" "충전 사이클" "${CYC}회" "정격 ${BAT_MAX_CYC}회"
    else chk "$G" "충전 사이클" "${CYC}회" "정격 초과 → 교체 전제로 네고"; fi
  else chk "$G" "충전 사이클" "읽기 실패" "⌥+애플메뉴 → 시스템 정보 → 전원 → 사이클 수"; fi
  isnum "$DESIGN" && isnum "$RAWMAX" && info "$G" "실측 용량" "${RAWMAX} / ${DESIGN} mAh" "현재 / 설계"
  return 0
}

sec_panic() {
  local G="안정성" NP
  if SUDO ls /Library/Logs/DiagnosticReports >/dev/null 2>&1; then
    NP="$(SUDO find /Library/Logs/DiagnosticReports -maxdepth 2 -name '*.panic' -mtime -180 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$NP" -ge "$PANIC_BAD" ]; then bad "$G" "커널 패닉(180일)" "${NP}회" "메인보드·SSD 이상 의심 → 구매 중단 권장"
    elif [ "$NP" -ge 1 ]; then chk "$G" "커널 패닉(180일)" "${NP}회" "판매자에게 원인 질문. 업데이트 직후 1회 정도는 흔함"
    else ok "$G" "커널 패닉(180일)" "0회" ""; fi
  else chk "$G" "커널 패닉(180일)" "로그 읽기 불가" "판매자에게 '갑자기 꺼지거나 재시동된 적 있나요?' 질문"; fi
  return 0
}

sec_dev() {
  # JSON 기준으로 판정 (텍스트 출력은 macOS 언어 설정에 따라 번역되므로 사용하지 않음)
  local G="장치" T
  T="$(system_profiler -json SPDisplaysDataType 2>/dev/null)"
  if printf '%s' "$T" | grep -qE '2560 ?x ?1600'; then ok "$G" "내장 디스플레이" "2560x1600 인식" ""
  else chk "$G" "내장 디스플레이" "해상도 인식 이상" "디스플레이 설정 확인, 테스트 페이지에서 화면 점검"; fi
  T="$(system_profiler -json SPAirPortDataType 2>/dev/null)"
  if printf '%s' "$T" | grep -qE 'spairport_status_connected|spairport_current_network_information'; then ok "$G" "Wi-Fi" "연결됨" ""
  else chk "$G" "Wi-Fi" "연결 확인 안 됨" "메뉴 막대 Wi-Fi 아이콘으로 핫스팟 연결 확인"; fi
  T="$(system_profiler -json SPBluetoothDataType 2>/dev/null)"
  if printf '%s' "$T" | grep -q 'attrib_on'; then ok "$G" "블루투스" "켜짐" ""
  elif printf '%s' "$T" | grep -q 'attrib_off'; then chk "$G" "블루투스" "꺼짐" "제어 센터에서 켜고 휴대폰이 검색되는지 확인"
  else chk "$G" "블루투스" "인식 안 됨" "제어 센터 → 블루투스가 보이는지 확인"; fi
  T="$(system_profiler -json SPCameraDataType 2>/dev/null)"
  if printf '%s' "$T" | grep -q '"_name"'; then ok "$G" "카메라" "장치 인식" ""
  else chk "$G" "카메라" "인식 안 됨" "테스트 페이지 카메라 항목으로 재확인"; fi
  return 0
}

sec_port() {  # 대화형: 시간 제한 없이 전면 실행
  local G="포트" BASE_USB NOW_USB STEP PC PD W AC_INFO
  usb_count() { { system_profiler -json SPUSBHostDataType; system_profiler -json SPUSBDataType; } 2>/dev/null | grep -o '"_name"' | wc -l | tr -d ' '; }
  on_ac() { pmset -g batt 2>/dev/null | grep -q "AC Power"; }
  wait_ac() { local n=0; while [ $n -lt 6 ]; do on_ac && return 0; sleep 1; n=$((n+1)); done; return 1; }
  if ! have_tty; then chk "$G" "포트 점검" "건너뜀" "충전기를 두 포트에 번갈아 꽂아 충전 표시 확인"; return 0; fi
  say ""
  say "${C_B}--- 포트 점검 (약 30초) ---${C_0}  왼쪽 포트 2개: [안쪽]=힌지 쪽, [바깥쪽]=앞쪽"
  ask "▶ 케이블을 모두 뽑고 Enter (건너뛰기: s) "
  if [ "$REPLY" = "s" ]; then chk "$G" "포트 점검" "건너뜀" "충전기를 두 포트에 번갈아 꽂아 충전 표시 확인"; return 0; fi
  BASE_USB="$(usb_count)"
  for STEP in 1 2; do
    if [ $STEP = 1 ]; then PC="안쪽"; PD="바깥쪽"; else PC="바깥쪽"; PD="안쪽"; fi
    ask "▶ 충전기 → [$PC], 휴대폰(데이터 케이블) → [$PD] 에 꽂고 Enter "
    if wait_ac; then
      W="$(pmset -g ac 2>/dev/null | sed -nE 's/.*Wattage *= *([0-9]+W?).*/\1/p' | head -1)"
      ok "$G" "[$PC] 충전" "충전 감지" "${W:+어댑터 $W}"
    else bad "$G" "[$PC] 충전" "충전 안 됨" "꽂힘 상태·다른 케이블로 재확인. 그래도 안 되면 포트 불량 → 구매 중단 또는 큰 폭 네고"; fi
    sleep 2
    NOW_USB="$(usb_count)"
    if isnum "$NOW_USB" && isnum "$BASE_USB" && [ "$NOW_USB" -gt "$BASE_USB" ]; then ok "$G" "[$PD] 데이터" "기기 인식" ""
    else chk "$G" "[$PD] 데이터" "인식 안 됨" "휴대폰 알림에서 '파일 전송' 선택 후 재확인. 충전이 되면 감수 가능"; fi
  done
  AC_INFO="$(pmset -g ac 2>/dev/null | sed -nE 's/.*(Manufacturer|Name) *= *(.*)/\2/p' | paste -sd ' ' -)"
  [ -n "$AC_INFO" ] && info "$G" "충전기" "$AC_INFO" ""
  return 0
}


# ---------------------------------------------------------------------
#  스트레스 테스트 (대화형, 선택): CPU 전체 코어 + 메모리 패턴 검증
#  GPU 는 테스트 페이지(t.html)의 'GPU 스트레스' 항목에서 진행
# ---------------------------------------------------------------------
STRESS_SEC="${MC_STRESS_SEC:-90}"      # CPU 부하 시간(초)
MEM_PCT="${MC_MEM_PCT:-60}"            # 메모리 검사에 쓸 RAM 비율(%)

thermal_level() {  # Nominal / Moderate / Heavy / Trapping / Sleeping (sudo 필요)
  [ "$HAVE_SUDO" = 1 ] || return 0
  sudo -n powermetrics -i 500 -n 1 --samplers thermal 2>/dev/null \
    | sed -nE 's/.*Current pressure level: *([A-Za-z]+).*/\1/p' | head -1
}

sec_stress() {
  local G="스트레스" NCPU D W i F FIRST LAST RATIO PCT T0 T1 TMAX LV ALIVE
  if ! have_tty; then chk "$G" "스트레스 테스트" "건너뜀" "필요하면 나중에 다시 실행"; return 0; fi
  say ""
  say "${C_B}--- 스트레스 테스트 (선택, 약 3~4분) ---${C_0}"
  say "CPU 전체 코어 ${STRESS_SEC}초 + 메모리 RAM의 ${MEM_PCT}% 쓰기·검증. 본체가 따뜻해지는 건 정상입니다."
  ask "▶ 진행하려면 Enter, 건너뛰려면 s "
  if [ "$REPLY" = "s" ]; then chk "$G" "스트레스 테스트" "건너뜀" "필요하면 나중에 다시 실행"; return 0; fi

  # ---- CPU ----
  NCPU="$(sysctl -n hw.ncpu 2>/dev/null)"; isnum "$NCPU" || NCPU=8
  D="$TMP/stress"; mkdir -p "$D"
  T0="$(thermal_level)"
  say "  · CPU ${NCPU}코어 부하 중 (${STRESS_SEC}초)…"
  i=0
  while [ $i -lt "$NCPU" ]; do
    perl -e '
      my ($dur,$out)=@ARGV; open(my $fh,">",$out) or exit 1; select($fh); $|=1;
      my $start=time; my $sec=$start; my $n=0; my $x=0.5;
      while (time-$start < $dur) {
        for (1..20000) { $x = sin($x)+cos($x)*1.0001; }
        $n++;
        if (time != $sec) { print(($sec-$start)," $n\n"); $sec=time; $n=0; }
      }' "$STRESS_SEC" "$D/w$i" &
    i=$((i+1))
  done
  TMAX="$T0"
  W=0
  while [ $W -lt "$STRESS_SEC" ]; do
    sleep 15; W=$((W+15))
    LV="$(thermal_level)"
    case "$LV" in Heavy|Trapping|Sleeping) TMAX="$LV";; Moderate) [ "$TMAX" = Nominal ] || [ -z "$TMAX" ] && TMAX="$LV";; esac
    printf '    %s초 경과%s\n' "$W" "${LV:+ (발열 단계: $LV)}"
  done
  wait 2>/dev/null

  ALIVE=0; for F in "$D"/w*; do [ -s "$F" ] && ALIVE=$((ALIVE+1)); done
  # 초별 합계 → 처음 10초 평균 vs 마지막 10초 평균
  RATIO="$(cat "$D"/w* 2>/dev/null | awk -v dur="$STRESS_SEC" '
      {s[$1]+=$2; if($1>m)m=$1}
      END{ a=0;na=0;b=0;nb=0
           for(t=1;t<=10&&t<=m;t++){a+=s[t];na++}
           for(t=m-10;t<m;t++){if(t>10){b+=s[t];nb++}}
           if(na==0||nb==0||a==0){print "";exit}
           printf "%d", (b/nb)/(a/na)*100 }')"

  if [ "$ALIVE" -lt "$NCPU" ]; then
    bad "$G" "CPU 부하" "${ALIVE}/${NCPU} 코어만 완료" "부하 중 프로세스가 죽음 → CPU·메모리 불안정 의심"
  elif ! isnum "$RATIO"; then
    chk "$G" "CPU 부하" "완료 (성능 유지율 계산 불가)" "부하 시간을 늘려 재실행"
  elif [ "$RATIO" -ge 70 ]; then
    ok "$G" "CPU 부하" "${NCPU}코어 ${STRESS_SEC}초 완료" "성능 유지율 ${RATIO}% (팬 없는 에어는 서서히 떨어지는 게 정상)"
  elif [ "$RATIO" -ge 50 ]; then
    chk "$G" "CPU 부하" "성능 유지율 ${RATIO}%" "평평한 곳·서늘한 곳에서 재측정. 계속 낮으면 내부 방열 문제 의심"
  else
    bad "$G" "CPU 부하" "성능 유지율 ${RATIO}%" "90초 만에 절반 이하로 떨어짐 → 방열·센서 이상 의심"
  fi
  case "$TMAX" in
    Heavy|Trapping|Sleeping) chk "$G" "발열 단계(최고)" "$TMAX" "90초 만에 높은 단계 → 서늘한 곳에서 재측정";;
    "") info "$G" "발열 단계" "측정 안 됨" "비밀번호 미입력 시 측정 불가";;
    *)  ok "$G" "발열 단계(최고)" "$TMAX" "";;
  esac

  # ---- 메모리 ----
  local MEMB CHUNKS
  MEMB="$(sysctl -n hw.memsize 2>/dev/null)"
  if isnum "$MEMB"; then
    CHUNKS=$(( MEMB / 1073741824 * MEM_PCT / 100 )); [ "$CHUNKS" -lt 1 ] && CHUNKS=1
    say "  · 메모리 ${CHUNKS}GB 쓰기·검증 중 (1~2분)…"
    local MR
    MR="$(perl -e '
      my $n=shift; my $sz=1<<30; my @b; my $bad=0;
      my @pat=("\xAA","\x55","\xFF","\x00");
      for my $p (0..1) {
        @b=();
        for my $i (0..$n-1) { my $c=$pat[($i+$p)%4]; push @b, $c x $sz; }
        for my $i (0..$n-1) { my $c=$pat[($i+$p)%4]; $bad++ unless $b[$i] eq ($c x $sz); }
      }
      print "$bad\n";' "$CHUNKS" 2>/dev/null)"
    if [ -z "$MR" ]; then
      chk "$G" "메모리 검증" "실행 실패(메모리 부족 등)" "MC_MEM_PCT=40 으로 낮춰 재실행, 또는 Apple 진단(전원 버튼 길게 → ⌘D)"
    elif [ "$MR" = 0 ]; then
      ok "$G" "메모리 검증" "${CHUNKS}GB × 2회 패턴 오류 0" ""
    else
      bad "$G" "메모리 검증" "불일치 ${MR}개 블록(1GB 단위)" "RAM 이상 의심 → Apple 진단(전원 버튼 길게 → ⌘D)으로 재확인"
    fi
  else
    chk "$G" "메모리 검증" "메모리 크기 읽기 실패" ""
  fi

  # ---- 부하 후 안정성 ----
  local NP
  NP="$(SUDO find /Library/Logs/DiagnosticReports -maxdepth 2 -name '*.panic' -mmin -10 2>/dev/null | wc -l | tr -d ' ')"
  if isnum "$NP" && [ "$NP" -gt 0 ]; then bad "$G" "부하 중 커널 패닉" "${NP}회" "부하에서 시스템이 죽음 → 구매 중단 권장"; fi
  info "$G" "GPU" "테스트 페이지에서 진행" "t.html 의 7번 'GPU 스트레스' 60초"
  return 0
}

# =====================================================================
#  섹션 실행기: 실패·시간초과를 격리
# =====================================================================
# 섹션 실패 시 수동 확인 방법
fallback_of() {
  case "$1" in
    기기)   echo "애플 메뉴 → 이 Mac에 관하여: 칩·메모리·저장공간·일련번호 확인";;
    잠금)   echo "시스템 설정 맨 위 Apple ID 로그아웃 여부 + 시스템 설정 → 일반 → 기기 관리(프로파일 없음) + 마지막 초기화 때 원격 관리 화면 없음";;
    SSD)    echo "비상용 점검(자동 실행) 결과로 판단";;
    배터리) echo "시스템 설정 → 배터리 → 배터리 성능 상태 ⓘ (최대 용량·상태)";;
    안정성) echo "판매자에게 갑작스런 재시동 경험 질문";;
    장치)   echo "테스트 페이지 + 제어 센터에서 Wi-Fi·블루투스 확인";;
    포트)   echo "충전기를 두 포트에 번갈아 꽂아 충전 표시 확인";;
    스트레스) echo "Apple 진단: 전원 끄고 전원 버튼 길게 → 옵션 화면에서 ⌘D (CPU·메모리·배터리 하드웨어 검사)";;
  esac
}
secfail() { # 분류 사유
  printf '%s\t%s\n' "$1" "$2" >> "$FAILED"
  chk "$1" "섹션 점검 실패" "$2" "$(fallback_of "$1")"
}
run_section() { # 분류 함수
  local G="$1" FN="$2" P W RC BEFORE AFTER
  printf '  · %-6s ' "$G"
  BEFORE=$(grep -c "$TAB$G$TAB" "$RES" 2>/dev/null)
  rm -f "$TMP/$FN.timeout"
  ( "$FN" ) > "$TMP/$FN.log" 2>&1 &
  P=$!
  ( sleep "$SECTION_TIMEOUT"; kill -TERM "$P" 2>/dev/null && touch "$TMP/$FN.timeout" ) >/dev/null 2>&1 &
  W=$!
  wait "$P" 2>/dev/null; RC=$?
  kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
  AFTER=$(grep -c "$TAB$G$TAB" "$RES" 2>/dev/null)
  if [ -f "$TMP/$FN.timeout" ]; then say "${C_CHK}시간 초과${C_0}"; secfail "$G" "시간 초과(${SECTION_TIMEOUT}초)"
  elif [ "$RC" -ne 0 ]; then say "${C_CHK}실패${C_0}"; secfail "$G" "오류(코드 $RC)"
  elif [ "$AFTER" -le "$BEFORE" ]; then say "${C_CHK}결과 없음${C_0}"; secfail "$G" "결과 없음"
  else say "완료"; fi
}

# =====================================================================
#  출력부 (EXIT 시 무조건 실행)
# =====================================================================
print_results() {
  local nc="$1" cok="$C_OK" cbad="$C_BAD" cchk="$C_CHK" cdim="$C_DIM" cb="$C_B" c0="$C_0" last="" LV GR IT VA NO TAG N_OK N_BAD N_CHK V
  [ "$nc" = 1 ] && { cok=""; cbad=""; cchk=""; cdim=""; cb=""; c0=""; }
  N_OK=$(grep -c '^OK' "$RES"); N_BAD=$(grep -c '^BAD' "$RES"); N_CHK=$(grep -c '^CHK' "$RES")
  echo ""
  echo "${cb}================ 점검 결과 ================${c0}  ${cdim}$(date '+%Y-%m-%d %H:%M')${c0}"
  while IFS=$'\t' read -r LV GR IT VA NO; do
    [ "$GR" != "$last" ] && { echo ""; echo "${cb}[$GR]${c0}"; last="$GR"; }
    case "$LV" in
      OK) TAG="${cok}✅ 정상    ${c0}";; BAD) TAG="${cbad}❌ 비정상  ${c0}";;
      CHK) TAG="${cchk}⚠️  확인필요${c0}";; *) TAG="${cdim}·  정보    ${c0}";;
    esac
    if [ "$LV" = INFO ] && [ -n "$NO" ]; then printf '  %s %s: %s  %s(%s)%s\n' "$TAG" "$IT" "$VA" "$cdim" "$NO" "$c0"
    elif [ "$LV" = OK ] && [ -n "$NO" ]; then printf '  %s %s: %s  %s(%s)%s\n' "$TAG" "$IT" "$VA" "$cdim" "$NO" "$c0"
    else printf '  %s %s: %s\n' "$TAG" "$IT" "$VA"; fi
  done < "$RES"

  if [ "$N_BAD" -gt 0 ] || [ "$N_CHK" -gt 0 ]; then
    echo ""
    echo "${cb}================ 조치 필요 ================${c0}"
    grep '^BAD' "$RES" | while IFS=$'\t' read -r LV GR IT VA NO; do echo "  ${cbad}❌ [$GR] $IT: $VA${c0}"; echo "     → $NO"; done
    grep '^CHK' "$RES" | while IFS=$'\t' read -r LV GR IT VA NO; do echo "  ${cchk}⚠️  [$GR] $IT: $VA${c0}"; echo "     → $NO"; done
  fi
  echo ""
  echo "${cb}------------------------------------------${c0}"
  printf '  정상 %s · 비정상 %s · 확인필요 %s\n' "$N_OK" "$N_BAD" "$N_CHK"
  V="$(cat "$TMP/ssd_verdict" 2>/dev/null)"; printf '  SSD 판정: %s\n' "${V:-확인 불가}"
  if [ "$N_BAD" -gt 0 ]; then echo "  ${cbad}${cb}🔴 결론: 구매 중단 권장 (❌ 항목 참고)${c0}"
  elif [ "$N_CHK" -gt 0 ]; then echo "  ${cchk}${cb}🟡 결론: ⚠️ 항목 조치 후 판단 (잠금 관련은 양보 금지)${c0}"
  else echo "  ${cok}${cb}🟢 결론: 자동 점검 모두 정상${c0}"; fi
  if [ -f "$TMP/seller_login" ]; then
    echo "  ${cchk}🔐 판매자 Apple ID 로그인 상태 → 결제 전 '초기화 후 Apple ID 요구 없음' 확인 필수 (안내 6번)${c0}"
  fi
}

run_emergency() {
  local need=0 nf
  nf=$(grep -c . "$FAILED" 2>/dev/null)
  [ -f "$TMP/need_emergency" ] && need=1
  isnum "$nf" && [ "$nf" -ge 2 ] && need=1
  [ "$need" = 1 ] || return 0
  echo ""
  echo "${C_CHK}${C_B}=== 진단 일부 실패 → 비상용 점검(KiemTraMac)을 자동 실행합니다 ===${C_0}"
  echo "${C_DIM}인터넷(핫스팟) 필요 · 질문 2개는 Enter로 건너뛰면 됨 · 결과는 베트남어지만 SSD 수치(%, TB)는 숫자로 보임${C_0}"
  local KD="$TMP/kt"; mkdir -p "$KD"
  if curl -fsSL --max-time 60 "$KT_TARBALL" -o "$KD/kt.tgz" 2>/dev/null && tar -xzf "$KD/kt.tgz" -C "$KD" 2>/dev/null \
     && [ -f "$KD/KiemTraMac-main/KiemTraMac.command" ]; then
    if have_tty; then ( cd "$KD" && bash KiemTraMac-main/KiemTraMac.command < "$TTY" ); else ( cd "$KD" && bash KiemTraMac-main/KiemTraMac.command < /dev/null ); fi
    echo "${C_DIM}(비상용 점검 끝 · 'SSD' 줄의 % 가 수명 사용률: 80% 이상이거나 lỗi(오류)가 있으면 구매 중단)${C_0}"
  else
    echo "${C_BAD}비상용 점검도 받지 못했습니다(인터넷 확인).${C_0} 아래 수동 확인 안내대로 진행하세요."
  fi
}

print_guide() {
  echo ""
  echo "${C_B}================ 스크립트로 확인 못 하는 항목 ================${C_0}"
  echo "  1) 테스트 페이지 (2~3분): 화면 색 · 키보드 · 트랙패드 · 스피커 · 마이크·카메라 · GPU 스트레스(60초)"
  echo "     안 열리면: Safari 주소창에 ${PAGE_URL}"
  [ -n "$DIR" ] && echo "     또는 Finder 에서 ${DIR}/t.html 더블클릭"
  echo "  2) 밝기·음량 키(F1·F2·F11·F12)와 키보드 백라이트가 동작하는지"
  echo "  3) Touch ID: 판매자에게 잠금(⌃⌘Q) 후 지문으로 풀어 달라고 하기"
  echo "  4) 애플 메뉴 → 이 Mac에 관하여 → Parts & Service: 교체 부품 이력"
  echo "  5) (이미 했다면 생략) 외관·힌지, 평평한 곳에서 네 모서리 눌러 배터리 부풂"
  if [ -f "$TMP/seller_login" ]; then
    echo "  6) ${C_CHK}${C_B}(필수, 5~10분) 판매자 Apple ID 해제 — 결제 직전 마지막 단계${C_0}"
    echo "     a. 판매자가 시스템 설정 → 일반 → 전송 또는 재설정 → 모든 콘텐츠 및 설정 지우기"
    echo "        (판매자 맥 암호 + Apple ID 암호 입력 → 로그아웃·나의 Mac 찾기·활성화 잠금이 함께 해제됨)"
    echo "     b. 재시동 후 언어·국가 → Wi-Fi(핫스팟) 연결 단계까지 진행"
    echo "     c. '활성화 잠금' 또는 이전 Apple ID 암호를 요구하면 → 판매자가 그 자리에서 해제하기 전엔 결제 금지"
    echo "     d. '원격 관리' 화면이 뜨면 → 회사 기기, 결제 금지"
    echo "     e. 둘 다 없으면 OK → 결제"
    echo "     ※ 판매자가 Apple ID 암호를 모르거나 '집에 가서 지워주겠다'고 하면 구매하지 마세요"
  else
    echo "  6) (권장, 5분) 시스템 설정 → 일반 → 전송 또는 재설정 → 모든 콘텐츠 및 설정 지우기"
    echo "     → 다시 켜서 Wi-Fi 단계까지: 이전 Apple ID 요구·'원격 관리' 화면이 없으면 OK"
  fi
  if [ -s "$FAILED" ]; then
    echo ""
    echo "  ${C_CHK}실패한 섹션 수동 확인:${C_0}"
    while IFS=$'\t' read -r GR WHY; do echo "   - [$GR] $(fallback_of "$GR")"; done < "$FAILED"
  fi
  echo ""
  echo "  ${C_B}절대 양보 금지:${C_0} 활성화 잠금 켜짐 · MDM/회사 배정 · 원격 관리 화면 · SSD 절대 피해야함"
  echo "  ${C_DIM}결과 파일: $REPORT  (휴대폰으로 화면도 찍어 두세요)${C_0}"
  echo ""
}

FINISHED=0
finish() {
  [ "$FINISHED" = 1 ] && return; FINISHED=1
  trap '' INT
  { print_results 0; } 2>/dev/null || echo "(결과표 출력 실패)"
  { print_results 1 > "$REPORT"; } 2>/dev/null
  { run_emergency; } 2>/dev/null
  if have_tty && [ "$OPEN_PAGE" = 1 ]; then
    ask "▶ Enter 를 누르면 테스트 페이지를 엽니다 (건너뛰기: s) "
    if [ "$REPLY" != "s" ]; then
      open -a Safari "$PAGE_URL" 2>/dev/null || { [ -n "$DIR" ] && open "$DIR/t.html" 2>/dev/null; }
    fi
  fi
  print_guide
  rm -rf "$TMP" 2>/dev/null
}
trap finish EXIT
trap 'echo; echo "(중단됨)"; exit 130' INT

# =====================================================================
#  메인
# =====================================================================
OPEN_PAGE=0
say ""
say "${C_B}=== 중고 맥북 현장 점검 (읽기 전용) ===${C_0}"
say "${C_DIM}정보를 읽기만 하고 설정·파일을 바꾸지 않습니다.${C_0}"
say ""
say "판매자 맥 비밀번호를 1회 입력해 주세요. (회사 배정 확인·로그 읽기에만 사용)"
say "${C_DIM}원치 않으면 그냥 Enter 3번 → 해당 항목만 '확인필요'로 표시${C_0}"
sudo -v 2>/dev/null && HAVE_SUDO=1
say ""
say "자동 점검 중… (섹션당 최대 ${SECTION_TIMEOUT}초)"
run_section "기기"   sec_hw
run_section "잠금"   sec_lock
run_section "SSD"    sec_ssd
run_section "배터리" sec_bat
run_section "안정성" sec_panic
run_section "장치"   sec_dev

# 포트: 대화형이라 전면 실행 (실패해도 계속)
( sec_port ) || secfail "포트" "오류"
( sec_stress ) || secfail "스트레스" "오류"
OPEN_PAGE=1
exit 0

# maccheck — 중고 맥북 현장 점검

판매자 맥에서 실행하는 **읽기 전용** 점검 스크립트와 반자동 테스트 페이지입니다.

## 저장소 구성
```
maccheck/
├─ maccheck.sh        진단 스크립트 (bash 3.2 호환)
├─ t.html                  화면·키보드·트랙패드·스피커·마이크·카메라 테스트
├─ bin/smartctl            SSD SMART 판독 (직접 추가)
├─ bin/smartctl-LICENSE.txt
└─ README.md
```

## 설정 (1회)
1. GitHub에 `maccheck` 저장소를 만들고 파일을 올립니다. `maccheck.sh`는 `bash`로 실행하므로 실행 권한이 없어도 됩니다.
   `publish_maccheck.sh`를 쓰면 저장소 생성·smartctl 추가·Pages 설정·주소 치환까지 자동입니다.
2. **smartctl:** [KiemTraMac](https://github.com/kiluss2/KiemTraMac)의 `smartctl`(smartmontools 7.5 universal)과
   `smartctl-LICENSE.txt`를 `bin/`에 복사합니다.
3. (선택) Settings → Pages를 켜고 `maccheck.sh` 상단 `PAGE_URL`의 `USERNAME`을 바꿉니다.
   Pages가 없어도 zip 안의 `t.html`로 테스트할 수 있지만, Safari에서 카메라·마이크는 https 페이지에서만 확실히 동작합니다.
4. 매물마다 `maccheck.sh` 상단 **매물 기대 사양**(칩·모델 ID·메모리·SSD)을 수정합니다. 비우면 비교 없이 표시만 합니다.

## 현장 실행
1. 외관·배터리 부풂 확인
2. 판매자 맥을 휴대폰 핫스팟에 연결 → Safari로 `github.com/lota09/maccheck` → Code → **Download ZIP**
   (Safari가 다운로드 폴더에 자동으로 압축을 풉니다)
3. ⌘+Space → "터미널" → `bash ` (한 칸 띄움) 입력 → Finder에서 `maccheck.sh`를 터미널 창으로 끌어다 놓기 → Enter
   - 또는 `bash ~/Downloads/maccheck-main/maccheck.sh`
4. 화면 안내대로 진행 → 결과의 ❌·⚠️ 항목 아래 "→" 대응 방법 확인 → 마지막 안내(수동 확인)까지 진행

## 동작 방식
- 섹션(기기·잠금·SSD·배터리·안정성·장치)을 **각각 별도 프로세스 + 60초 제한**으로 실행 → 하나가 멈추거나 실패해도 나머지 계속
- 포트 점검은 대화형(충전기·휴대폰 꽂기 2단계)
- SSD 수치를 못 읽거나 섹션 2개 이상 실패 → **비상용 KiemTraMac 자동 다운로드·실행**
- 종료·중단(Ctrl+C) 어떤 경우에도 **"스크립트로 확인 못 하는 항목" 안내는 출력**
- 결과는 바탕화면 `maccheck-날짜.txt`로도 저장

## 판정 기준
- **SSD:** 경고 플래그≠0, 데이터 오류>0, 예비공간≤하한(Apple은 99%), 수명 사용률≥80% 중 하나라도 → **절대 피해야함** /
  사용률≤5%·예비공간 100%·오류 0 → **최고수준** / 그 외 → **무난함**
- **배터리:** 상태 Normal/Good 아님, 최대 용량<80%, 사이클>1000 → 확인필요 / 영구 고장 플래그 → 비정상
- **커널 패닉(180일):** 3회 이상 비정상, 1~2회 확인필요
- 읽기 실패는 절대 "정상"으로 표시하지 않고 **확인필요**로 표시

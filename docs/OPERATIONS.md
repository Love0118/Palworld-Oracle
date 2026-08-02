# Operations

## 정상 종료

`systemctl stop palworld`는 다음 순서를 사용합니다.

1. REST `POST /save`
2. REST `POST /shutdown`
3. 설정된 대기시간 동안 종료 완료 대기
4. 실패 시 systemd가 `SIGINT`, timeout 후 최종 종료

REST credential이 없거나 API가 응답하지 않아도 systemd 종료 경로는 유지됩니다.

## 백업

```bash
sudo palworldctl backup
journalctl -u palworld-backup.service
```

백업은 서버를 정상 종료한 뒤 전체 `/var/lib/palworld/Saved`를 압축하고 SHA-256 sidecar를 만든 다음, 이전 실행 상태였으면 서버를 다시 시작합니다. 기본 보존기간은 14일입니다. 단순 ext4 환경에서도 파일 간 시점을 일치시키기 위해 정기 백업과 업데이트 직전 백업 모두 cold backup으로 수행되므로 짧은 점검 중단이 발생합니다.

같은 VM의 백업만으로는 디스크 또는 계정 장애를 복구할 수 없습니다. `/var/lib/palworld/backups`를 별도 볼륨이나 객체 저장소로 복제하세요.

복원 시에는 서버를 정지하고 현재 Saved를 별도 위치에 보존한 뒤, 검증된 archive를 임시 경로에 풀어 구조와 checksum을 확인하고 교체해야 합니다. 자동 복원은 의도하지 않은 데이터 손실 위험 때문에 제공하지 않습니다.

## 월드 저장 슬롯

Discord `/pal save-slots`와 `/pal save-slot`은 최대 10개의 독립 월드를 선택합니다.
처음 슬롯 기능을 사용하면 당시 활성 월드를 1번 슬롯으로 등록합니다. 활성 슬롯의
`SaveGames`만 `/var/lib/palworld/Saved`에 두고, 나머지 슬롯은
`/var/lib/palworld/save-slots`에 보관합니다. `Config`는 공통으로 남으므로 포트, 서버
이름, REST와 같은 서버 설정은 슬롯 전환으로 바뀌지 않습니다.

슬롯 전환은 현재 월드를 정상 종료하고 cold backup을 성공시킨 뒤에만 시작합니다.
선택 슬롯의 `SaveGames`를 원자적으로 교체하고 서버·REST health를 확인합니다. 새
슬롯 기동에 실패하면 이전 `SaveGames`와 활성 슬롯 상태를 복구한 뒤 기존 서버를 다시
시작합니다. 일반 백업은 활성 월드만 압축하므로, 장기 보관할 비활성 슬롯은 별도 파일
시스템 백업 정책에도 포함하세요.

## 업데이트

```bash
sudo palworldctl update
journalctl -u palworld-update.service
```

업데이트는 다음 순서입니다.

1. updater worktree 갱신
2. 파일 fingerprint가 현재 릴리스와 다른지 확인
3. staging snapshot 생성
4. 기존 서버 정상 종료
5. cold backup
6. staging을 root 소유 read-only 릴리스로 승격
7. `current` 링크 원자적 전환
8. 이전에 실행 중이었다면 새 릴리스 시작

새 릴리스가 즉시 시작하지 못하면 이전 binary 릴리스로 링크를 되돌립니다. 하지만 새 바이너리가 세이브를 열어 포맷을 변경한 뒤 발생한 장애에는 cold backup 복원 검토가 필요합니다.

서버가 원래 중지돼 있고 `PALWORLD_UPDATE_START_IF_STOPPED=false`이면 관리자가 정지한 상태를 존중하기 위해 구조 검증만 거쳐 승격하며 런타임 health 검증은 다음 수동 시작 때 수행됩니다. 중지 상태의 자동 업데이트에서도 즉시 기동 검증을 원하면 이 값을 `true`로 설정하되, 업데이트 후 서버가 실행 상태로 남는다는 점을 고려하세요.

## 예약 및 명령 재기동

```bash
sudo palworldctl restart
systemctl list-timers palworld-maintenance-restart.timer
```

`palworldctl restart`와 Discord `/pal restart confirm:True`는 모두
`palworld-maintenance-restart.service`를 호출합니다. 먼저 updater worktree를
검증하고, 새 릴리스가 있으면 cold backup 뒤 원자적으로 전환합니다. 새
릴리스가 없어도 현재 서버를 정상 종료·기동하고 REST health를 확인합니다.
업데이트가 있는 경우 업데이트 경로의 기동을 재사용하므로 이중 재기동하지
않습니다.

timer는 호스트 timezone과 무관하게 `Asia/Seoul`을 명시하고 매일 05:00에
업데이트 검사를 시작합니다. 다운로드 시간만큼 실제 중단 시작 시각은 늦어질
수 있습니다. 업데이트 확인이 실패하면 경고를 남기고 검증된 현재 릴리스를
예정대로 재기동합니다. `Persistent=true`이므로 05:00에 호스트가 꺼져 있으면
다음 부팅에서 누락된 작업을 한 번 수행합니다. 과거의 별도
`palworld-update.timer`는 설치/업그레이드 시
비활성화·제거되어 낮 시간대의 추가 업데이트 재기동을 만들지 않습니다.

## 장애 확인

```bash
sudo palworldctl doctor
sudo palworldctl status
sudo palworldctl logs
sudo palworldctl metrics
systemctl list-timers 'palworld-*'
```

`palworld-firewall.service`는 재부팅마다 전용 `PALWORLD_ORACLE` chain을
재구성하고 현재 게임 UDP 포트의 허용 규칙을 적용합니다. 이 unit은 호스트
전체의 default-deny 정책이나 REST 차단을 대신하지 않습니다. 기존 INPUT
정책과 클라우드 Security List/NSG에서 `8211/udp`만 공인 ingress로 열고
REST `8212/tcp`는 명시적으로 차단해야 합니다.

FPS 임계치 미달은 로그 경보만 발생시킵니다. REST liveness 또는 프로세스 상태가 설정된 횟수만큼 연속 실패해야 자동 복구가 실행됩니다. `PALWORLD_RSS_RESTART_MIB=0`은 메모리 임계치 복구가 비활성화된 상태입니다.

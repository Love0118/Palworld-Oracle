# Architecture

Palworld Oracle는 게임 실행, 업데이트, 데이터, 운영 credential을 서로 다른 신뢰 영역으로 분리합니다.

```text
DepotDownloader(ARM64 native)
        │
        ▼
updater worktree ── fingerprint ── staging release
                                      │
                         save → stop → cold backup
                                      │
                                      ▼
                             atomic current switch
                                      │
                                      ▼
                          Box64 → PalServer x86_64
                                      │
                 ┌────────────────────┼───────────────────┐
                 ▼                    ▼                   ▼
          persistent Saved       REST metrics       Box64 cache
                                      │
                                      ▼
                             native observer textfile
                                      │
                                      ▼
                          restricted Discord status bot
```

## 불변 릴리스

서비스 계정은 `/opt/palworld/releases`에 쓸 수 없습니다. 게임의 `Pal/Saved`만 `/var/lib/palworld/Saved`로 연결됩니다. 새 파일은 별도 staging에서 완성한 뒤 서버가 정지한 상태에서만 승격합니다.

이 구조는 다음 문제를 방지합니다.

- 실행 중 업데이트로 바이너리와 지연 로딩 에셋 버전이 섞이는 현상
- 다운로드 실패가 서버 시작을 막는 현상
- 업데이트 후 이전 실행 파일을 찾을 수 없는 상태
- updater 취약점으로 서비스 launcher나 systemd unit까지 변조되는 범위 확대

## 프로세스와 권한

- `palworld`: Saved, 전용 HOME, health state, Box64 cache만 기록
- `palworld-updater`: 격리된 worktree와 staging만 기록
- `palworld-backup`: supplementary group 없이 ACL을 통해 Saved만 읽고 별도 backup 영역만 기록; 관리자 credential과 유지보수 lock은 접근할 수 없음
- `palworld-observer`: Saved 접근 없이 loopback REST와 read-only cgroup 수치만 읽고 자체 Prometheus textfile, `userId` 전용 접속 스냅샷, 탈출 선택 목록용 닉네임·`userId` 스냅샷만 기록
- `palworld-discord`: observer의 성능값·정제된 접속 스냅샷·탈출 선택 목록만 읽고, 전용 runtime 요청 파일을 통해 고정된 업데이트·재기동·플레이어 재접속 unit만 활성화
- `root`: 릴리스 승격, systemd 제어, credential 설치

`palworld.service`의 MainPID는 launcher가 `exec box64 ...`로 교체되므로 systemd가 실제 변환 프로세스와 전체 cgroup을 추적합니다.

## systemd 단위

- `palworld.service`: 게임 서버
- `palworld-firewall.service`: 공인 게임 UDP 포트만 호스트 INPUT 정책에 허용
- `palworld-backup.service`: 관리자가 요청할 때 수행하는 수동 cold backup
- `palworld-healthcheck.service/.timer`: 프로세스와 REST liveness
- `palworld-observer.service`: ARM64 네이티브 장기 성능 관측
- `palworld-discord.service`: 길드·채널·역할 제한 Discord slash command
- `palworld-recover.service`: 연속 장애 시 cooldown 복구
- `palworld-update.service`: 수동 업데이트의 격리 다운로드와 원자적 승격
- `palworld-update-watch.service/.timer`: 5분마다 Steam Linux 매니페스트만 확인하고, 변경을 2회 확인한 뒤 사전 공지·안전 업데이트 실행
- `palworld-maintenance-restart.service/.timer`: 매일 05:00 KST 업데이트 확인 후 재기동

Box64 DynaRec은 실행 중 코드를 생성하므로 `MemoryDenyWriteExecute`를 의도적으로 적용하지 않습니다. CPU quota와 낮은 memory hard cap도 기본값에서 제외합니다.

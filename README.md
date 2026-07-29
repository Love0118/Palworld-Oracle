# Palworld Oracle

Oracle Cloud ARM64에서 Palworld 전용 서버를 Docker 없이 직접 실행하기 위한 운영 베이스라인입니다.

ARM64 네이티브 DepotDownloader가 게임 파일을 받고, Box64 DynaRec이 공식 x86_64 Linux 서버만 변환 실행합니다. systemd가 서버·백업·상태 확인·업데이트를 각각 관리합니다.

## 현재 범위

- Debian/Ubuntu ARM64
- Oracle A1(Ampere Altra/Neoverse-N1), Raspberry Pi 5, Apple Silicon Linux 및 generic ARM64 Box64 빌드 프로필
- Palworld Dedicated Server app `2394010`
- Box64 `v0.4.2`, DepotDownloader `3.4.0` 기본 고정
- 실행 중인 릴리스와 다운로드 작업공간 분리
- 정상 저장/종료 후 원자적 릴리스 전환
- REST 상태 검사, 6시간 백업, 한국시간 05:00 업데이트 확인·재기동
- 역할과 채널이 제한된 Discord 상태·재기동 slash command
- ARM64 네이티브 C++ 성능 관측과 Prometheus textfile

Palworld의 공식 ARM64 서버 바이너리가 아니라 Box64 변환 실행 방식이므로, 목표 동접과 월드 크기는 실제 부하 테스트로 확정해야 합니다.

## 빠른 시작

```bash
git clone --branch beta https://github.com/Love0118/Palworld-Oracle.git
cd Palworld-Oracle
sudo ./scripts/install.sh
```

설치기는 다음 작업을 수행합니다.

1. ARM64와 기본 4KiB 페이지 크기를 검사합니다.
2. 전용 `palworld`, `palworld-updater`, `palworld-backup` 계정을 만듭니다.
3. 현재 CPU에 맞춰 Box64를 빌드합니다.
4. ARM64 DepotDownloader와 첫 Palworld 릴리스를 설치합니다.
5. 백업·상태 확인·05:00 KST 재기동 timer를 활성화합니다. 게임 서비스와 Discord 봇은 구성이 끝날 때까지 활성화하지 않습니다.

관리자 비밀번호와 기본 서버 정보를 설정합니다. 비밀번호는 명령행 인수에 넣지 않고 대화형으로 입력합니다.

```bash
sudo palworldctl configure --server-name "Palworld Oracle" --players 16
sudo palworldctl start
sudo palworldctl status
```

자동화 환경에서는 권한이 제한된 임시 파일을 사용합니다.

```bash
sudo palworldctl configure \
  --password-file /secure/path/admin-password \
  --server-name "Palworld Oracle" \
  --players 16
```

설치기는 전용 iptables chain에서 게임 포트 `8211/udp`의 허용 규칙을
관리합니다. 호스트 전체의 default-deny 정책을 만들거나 REST를 직접
차단하지는 않습니다. Oracle Cloud Security List/NSG와 호스트 방화벽에서
게임 UDP만 허용하고 `8212/tcp`는 공인 인터넷에서 반드시 차단하세요.
기본 운영 도구는 `127.0.0.1:8212`로 접속합니다.

## 관리 명령

```bash
sudo palworldctl status
sudo palworldctl logs
sudo palworldctl metrics
sudo palworldctl backup
sudo palworldctl update
sudo palworldctl profile show
sudo palworldctl profile apply
sudo palworldctl doctor
sudo palworldctl restart
sudo palworldctl discord status
```

`profile apply`는 실행 중인 서버를 정상 종료하고 cold backup을 만든 뒤,
ARM 균형 프로필을 원자적으로 적용합니다. 재시작한 서버가 정확한 값을
REST로 보고하지 않으면 이전 설정을 자동 복원합니다.

게임 밸런스와 월드 제한은 다음 파일에서 관리합니다.

```text
/var/lib/palworld/Saved/Config/LinuxServer/PalWorldSettings.ini
```

설정 변경 후에는 서버를 재시작해야 합니다.

Discord에서 `/pal status`와 업데이트 포함 `/pal restart`를 사용하려면 bot
token, 길드·채널·관리 역할 ID를 별도로 등록합니다. 자세한 절차와 권한 경계는
[Discord 관리 봇](docs/DISCORD_BOT.md)을 참고하세요.

## 데이터 및 릴리스 구조

```text
/opt/palworld/
  current -> releases/<release-id>
  releases/<release-id>/          # root 소유, 실행 중 불변
  staging/                         # updater 전용
  tools/depotdownloader/

/var/lib/palworld/Saved/           # 영속 월드/설정
/var/lib/palworld/backups/         # 체크섬이 포함된 백업
/var/lib/palworld/health/          # probe 상태
/var/lib/palworld/home/            # 게임 계정 HOME
/var/lib/palworld-admin/           # root 소유 유지보수 상태와 잠금
/var/lib/palworld-updater/worktree # 실행과 분리된 다운로드 작업공간
/var/lib/palworld-observer/         # 네이티브 관측기 textfile 상태
/var/cache/palworld/               # Box64 DynaCache, 백업 제외
/etc/palworld/                     # 운영 설정과 관리자 credential
```

업데이트는 worktree를 먼저 갱신하고 변경된 경우에만 새 릴리스를 만듭니다. 이후 서버를 저장·종료하고 cold backup을 만든 다음 `current` 심볼릭 링크를 원자적으로 전환합니다. 실행 중인 파일을 덮어쓰지 않습니다.

정기 백업도 파일 간 일관성을 위해 cold backup으로 동작합니다. 실행 중이었다면 정상 저장·종료 후 백업하고 다시 시작하므로 6시간마다 짧은 점검 중단이 발생합니다.

## 성능 기준선

Palworld 1.0 공식 문서는 과거의 멀티스레드 인수를 생략했을 때 성능이 더 나을 수 있다고 안내합니다. 따라서 기본값은 다음과 같습니다.

```text
PALWORLD_LEGACY_PERF_ARGS=false
PALWORLD_WORKER_THREADS=
```

기본 설정을 먼저 측정한 뒤 동일한 복제 월드에서 legacy 인수와 worker 수를 하나씩 비교하세요. FPS 저하는 자동 재시작 사유가 아니라 경보로만 처리됩니다. REST liveness가 연속해서 실패한 경우에만 cooldown을 적용해 복구를 시도합니다.

자세한 내용은 다음 문서를 참고하세요.

- [구조](docs/ARCHITECTURE.md)
- [설정 및 Box64 프로필](docs/CONFIGURATION.md)
- [백업·업데이트·복구 운영](docs/OPERATIONS.md)
- [Discord 관리 봇](docs/DISCORD_BOT.md)
- [성능 벤치마크](docs/BENCHMARK.md)
- [네이티브 최적화와 서버 모드 경계](docs/NATIVE_OPTIMIZATION.md)
- [원거리 거점·운반·드롭 병합 실험 설계](docs/AWAY_BASE_OPTIMIZATION.md)
- [기본 비활성 AwayBaseOptimizer 서버 모드](mods/AwayBaseOptimizer/README.md)

## 주의사항

- `MemoryDenyWriteExecute=yes`는 Box64 JIT/DynaRec을 막으므로 사용하지 않습니다.
- 낮은 `MemoryMax`나 CPU hard quota는 저장 전 OOM 또는 서버 FPS 급락을 유발할 수 있어 기본 적용하지 않습니다.
- 새 버전이 기존 세이브를 열었다면 바이너리만 이전 버전으로 되돌리는 것으로 충분하지 않을 수 있습니다. 세이브 포맷 변경 가능성이 있으므로 업데이트 전 cold backup도 함께 보존합니다.
- `/opt/palworld/releases`는 자동 삭제하지 않습니다. 정상 동작과 복구 테스트를 확인한 후 오래된 릴리스를 정리하세요.

## 근거 자료

- [Pocketpair Linux 전용 서버 배포](https://docs.palworldgame.com/getting-started/deploy-dedicated-server/)
- [Pocketpair 실행 인수](https://docs.palworldgame.com/settings-and-operation/arguments/)
- [Pocketpair REST metrics](https://docs.palworldgame.com/api/rest-api/metrics/)
- [DepotDownloader](https://github.com/SteamRE/DepotDownloader)
- [Box64](https://github.com/ptitSeb/box64)

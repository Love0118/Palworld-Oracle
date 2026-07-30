# palworld-observer

`palworld-observer`는 ARM64 Linux에서 별도 런타임이나 외부 C++ 라이브러리 없이 동작하는 Palworld 전용 관측 프로세스입니다. Palworld REST API와 systemd cgroup을 읽기만 하며 게임 서버 프로세스에는 코드를 주입하지 않습니다.

## 수집 항목

- REST `/v1/api/metrics`: FPS, frame time, 접속자 수, 최대 접속자 수, uptime
- REST `/v1/api/players`: 접속자의 `userId`만 추출한 접속 감지용 스냅샷
- cgroup v2 `/sys/fs/cgroup/system.slice/palworld.service`: 총 메모리, anonymous memory, CPU 사용량, OOM 및 OOM-kill 누계
- 최근 360개 성공 표본: frame time p50/p95/p99, 최소 5분이 쌓인 뒤 anonymous memory의 최소제곱 선형 추세(MiB/hour)

성공한 표본은 비밀번호 등 비밀정보 없이 JSON 한 줄로 stdout에 즉시 기록됩니다.
Prometheus textfile과 플레이어 스냅샷은 같은 디렉터리의 임시파일을
`rename(2)`하는 방식으로 원자적으로 교체합니다. 플레이어 스냅샷에는 닉네임,
계정명, IP, 위치나 ping을 넣지 않고 `userId`와 서버 uptime만 기록합니다. REST
API가 아직 준비되지 않았거나 일시적으로 실패하면 프로세스는 종료되지 않고
stderr에 경고를 남긴 뒤 다음 주기에 다시 시도합니다.

## 빌드 및 테스트

ARM64 Linux에서 GCC 또는 Clang과 CMake 3.20 이상이 필요합니다.

```bash
cmake -S native/observer -B build/observer -DCMAKE_BUILD_TYPE=Release
cmake --build build/observer --parallel
build/observer/palworld-observer --self-test
```

컴파일에는 `-Wall -Wextra -Wpedantic -Werror`가 적용됩니다.

## 설정

| 환경변수 | 기본값 | 설명 |
|---|---:|---|
| `PALWORLD_REST_HOST` | `127.0.0.1` | REST 호스트 |
| `PALWORLD_REST_PORT` | `8212` | REST TCP 포트 |
| `PALWORLD_REST_BASE_PATH` | `/v1/api` | `/metrics` 앞의 REST 경로 |
| `PALWORLD_REST_USER` | `admin` | Basic Auth 사용자 이름 |
| `PALWORLD_OBSERVER_INTERVAL_SECONDS` | `10` | 수집 간격(1초 이상) |
| `PALWORLD_OBSERVER_OUTPUT` | `/var/lib/palworld-observer/palworld.prom` | Prometheus textfile 출력 경로 |
| `PALWORLD_OBSERVER_PLAYERS_OUTPUT` | `/var/lib/palworld-observer/players.snapshot` | 정제된 `userId` 스냅샷 출력 경로 |

비밀번호는 환경변수나 명령행으로 받지 않습니다. systemd credential 디렉터리의 `admin-password` 파일, 즉 `${CREDENTIALS_DIRECTORY}/admin-password`만 읽습니다. 예를 들어 서비스 단위에서는 다음처럼 전달할 수 있습니다.

```ini
[Service]
ExecStart=/usr/local/bin/palworld-observer
LoadCredential=admin-password:/etc/palworld/credentials/admin-password
StateDirectory=palworld-observer
```

출력 디렉터리는 프로세스 시작 전에 존재하고 실행 사용자에게 쓰기 가능해야 합니다. 대상 cgroup 경로는 현재 운영 단위 이름인 `palworld.service`에 맞춰 고정되어 있습니다. CPU 값은 논리 CPU 한 개를 완전히 사용할 때 `100`이며 멀티스레드 부하에서는 `100`을 넘을 수 있습니다.

textfile과 상위 디렉터리는 `palworld-observer` 그룹으로 제한됩니다. node_exporter 같은 외부 collector를 연결할 때만 해당 서비스 계정을 이 그룹에 명시적으로 추가하고, credential이나 Saved 그룹은 부여하지 마세요.

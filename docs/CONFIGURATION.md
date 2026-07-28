# Configuration

## 운영 환경

기본 설정은 `/etc/palworld/palworld.env`에 있습니다. 비밀값을 넣지 않는 `root:root 0644` 파일이며, 변경 후 해당 service나 timer를 다시 시작해야 합니다. 관리자 비밀번호는 별도의 systemd credential 파일에 저장됩니다.

서버 이름, 관리자 비밀번호, 월드 및 밸런스 설정은 `/var/lib/palworld/Saved/Config/LinuxServer/PalWorldSettings.ini`에 있습니다. `DefaultPalWorldSettings.ini`를 직접 수정해도 적용되지 않습니다.

`palworldctl configure`는 서버가 배포한 최신 기본 파일에서 기존 scalar 값만 원자적으로 교체합니다. 전체 설정 템플릿을 프로젝트에 고정하지 않으므로 게임 업데이트로 항목이 추가되어도 제거하지 않습니다.

## Box64 빌드 프로필

설치 시 `BOX64_BUILD_PROFILE=auto`가 CPU를 탐지합니다.

| 값 | 대상 |
| --- | --- |
| `adlink` | Oracle A1 / Ampere Altra / Neoverse-N1 |
| `rpi5` | Raspberry Pi 5 |
| `m1` | Apple Silicon Linux |
| `generic` | AmpereOne 및 그 외 ARM64 |

직접 지정하는 예시는 다음과 같습니다.

```bash
sudo BOX64_BUILD_PROFILE=adlink ./scripts/install.sh
```

기본 Box64 및 DepotDownloader 버전은 SHA-256까지 고정됩니다. 다른 버전을 시험할 때는 해당 공식 자산을 별도로 검증한 뒤 `BOX64_SHA256` 또는 `DEPOT_DOWNLOADER_SHA256`도 함께 지정해야 합니다.

## Box64 실행 프로필

기본값은 Palworld ARM 운영 사례에서 사용되는 균형 프로필입니다.

```text
BOX64_DYNAREC_BIGBLOCK=1
BOX64_DYNAREC_SAFEFLAGS=1
BOX64_DYNAREC_STRONGMEM=1
BOX64_DYNAREC_FASTROUND=1
BOX64_DYNAREC_FASTNAN=1
BOX64_DYNAREC_X87DOUBLE=0
```

변환 계층 크래시가 재현될 때만 다음 안정성 우선 값을 시험하세요.

```text
BOX64_DYNAREC_BIGBLOCK=0
BOX64_DYNAREC_SAFEFLAGS=2
BOX64_DYNAREC_STRONGMEM=3
BOX64_DYNAREC_FASTROUND=0
BOX64_DYNAREC_FASTNAN=0
BOX64_DYNAREC_X87DOUBLE=1
```

안정성 프로필은 메모리 순서와 부동소수점 처리를 보수적으로 만들어 성능을 크게 낮출 수 있습니다. 한 번에 하나의 변수만 바꾸고 복제 월드에서 검증하세요.

## 게임 부하 제한

다음 항목은 월드가 성장할수록 CPU·메모리·동기화 부하를 크게 바꿉니다.

- `BaseCampMaxNum`, `BaseCampMaxNumInGuild`
- `BaseCampWorkerMaxNum`
- `MaxBuildingLimitNum`
- `PhysicsActiveDropItemMaxNum`
- `PalSpawnNumRate`
- `ServerReplicatePawnCullDistance`

서비스 정책에 맞는 상한을 정하고, 값 변경 전후 REST FPS·frame time·RSS 증가율을 기록하세요.

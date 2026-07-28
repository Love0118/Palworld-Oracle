# Configuration

## 운영 환경

기본 설정은 `/etc/palworld/palworld.env`에 있습니다. 비밀값을 넣지 않는 `root:root 0644` 파일이며, 변경 후 해당 service나 timer를 다시 시작해야 합니다. 관리자 비밀번호는 별도의 systemd credential 파일에 저장됩니다.

서버 이름, 관리자 비밀번호, 월드 및 밸런스 설정은 `/var/lib/palworld/Saved/Config/LinuxServer/PalWorldSettings.ini`에 있습니다. `DefaultPalWorldSettings.ini`를 직접 수정해도 적용되지 않습니다.

`palworldctl configure`는 서버가 배포한 최신 기본 파일에서 기존 scalar 값만 원자적으로 교체합니다. 전체 설정 템플릿을 프로젝트에 고정하지 않으므로 게임 업데이트로 항목이 추가되어도 제거하지 않습니다.

## ARM 균형 게임 프로필

현재 프로필은 사용자가 요청한 명시적 밸런스/부하 항목만 변경합니다.

```bash
sudo palworldctl profile show
sudo palworldctl profile apply
```

적용 값은 다음과 같습니다.

```text
bEnableInvaderEnemy=False
CollectionDropRate=1.8
CollectionObjectRespawnSpeedRate=2.0
DropItemMaxNum=2100
DropItemAliveMaxHours=0.5
DeathPenalty=None
PhysicsActiveDropItemMaxNum=500
BaseCampMaxNum=64
BaseCampMaxNumInGuild=10
MaxBuildingLimitNum=10000
ServerReplicatePawnCullDistance=12000.0
ItemContainerForceMarkDirtyInterval=2.0
```

`DropItemMaxNum=2100`은 이 서버 빌드의 기본값 3000의 70%입니다.
`DropItemAliveMaxHours=0.5`는 30분입니다. Pocketpair 문서에서
`CollectionObjectRespawnSpeedRate`는 이름과 달리 재생 *간격*으로 정의되므로
`2.0`은 자원이 약 두 배 늦게 다시 생기는 값입니다.

추가 성능 상한은 물리 동작 중인 드롭을 500개로 제한하고, 서버 전체
거점을 64개로 제한합니다. 길드당 거점은 공식 최대치인 10개입니다.
플레이어당 건축 상한은 10,000개이며 Pal 복제 거리는
150m에서 120m로 줄어듭니다. 컨테이너 UI의 강제 재동기화 간격은 2초라서
최대 약 1초가량 더 늦게 보일 수 있습니다. 거점당 팰 15마리는 기존값을
유지합니다.

적용기는 유지보수 잠금을 잡고 정상 저장·종료, cold backup, 원자적 설정
변경을 수행합니다. 서버가 실행 중이었다면 재시작 후 REST 값까지 검증하고,
원래 정지 상태였다면 파일 검증만 마친 뒤 정지 상태를 유지합니다. 검증
실패 시 파일 ACL을 포함한 기존 설정을 복원하고 이전 실행 상태로 되돌립니다.

주변 드롭 병합의 `bMergeDropItems`와 언로드 거점의 `bUpdateSimple`은 공식
`PalWorldSettings.ini` 키가 아닙니다. 이 값들은
[`AwayBaseOptimizer`](../mods/AwayBaseOptimizer/README.md)의 격리된 런타임
실험에만 속하며 이 프로필이 변경하지 않습니다. 모드 소스도 기본 비활성이고
실서버에는 설치되지 않습니다.

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

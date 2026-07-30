# Discord 관리 봇

Discord 봇은 등록한 길드와 채널에서만 다음 slash command를 제공합니다.

- `/pal status`: 접속자, Palworld cgroup CPU/RAM, 서버 FPS, frame time, uptime
- `/pal restart confirm:True`: 업데이트 확인 후 안전한 서버 재기동
- `/pal escape player:...`: 닉네임·Steam ID 목록에서 버그에 걸린 플레이어를 선택해 강제 재접속
- `/pal log-channel channel:#채널`: 관리 명령 기록을 남길 채널 지정

Palworld 공식 REST metrics에는 별도 TPS 항목이 없으므로 상태 명령은 공식
`serverfps`를 **TPS 대체 지표**로 명시해 표시합니다. 봇은 네이티브 observer가
만든 Prometheus 파일, `userId` 전용 접속 스냅샷, 탈출 선택 목록용 닉네임·`userId`
스냅샷만 읽으며 REST 관리자 비밀번호에는 접근하지 않습니다.

## Discord 애플리케이션 준비

Discord Developer Portal에서 애플리케이션과 Bot을 만든 뒤 다음 OAuth2
scope로 대상 길드에 초대합니다.

```text
bot
applications.commands
```

관리 채널에서 메시지 전송과 embed 링크 권한만 부여하면 됩니다. 메시지 본문을
읽지 않으므로 Message Content Intent는 필요하지 않습니다. Discord 개발자
모드를 켜고 길드 ID, 관리 채널 ID, 재기동을 허용할 역할 ID를 복사합니다.

토큰은 명령행에 넣지 말고 root만 읽을 수 있는 한 줄짜리 파일로 준비합니다.

```bash
sudo install -o root -g root -m 0600 /dev/null /root/discord-token
sudoedit /root/discord-token

sudo palworldctl discord configure \
  --token-file /root/discord-token \
  --guild-id 123456789012345678 \
  --channel-id 223456789012345678 \
  --admin-role-id 323456789012345678
```

`--admin-role-id`는 여러 번 지정할 수 있습니다. Discord의 Administrator
권한을 가진 사용자도 재기동할 수 있습니다. 별도 관리 역할이 없다면
`--admin-role-id`를 생략하고 Administrator만 허용할 수 있습니다. 설정이
끝나면 원본 토큰 파일은
안전하게 삭제하고, bot token을 회전할 때 같은 명령으로 다시 구성합니다.

```bash
sudo palworldctl discord status
sudo palworldctl discord logs
```

## 플레이어 탈출

`/pal escape`는 버그에 걸려 긴급 탈출을 사용할 수 없는 **온라인** 플레이어를
안전하게 강제 재접속시키는 관리 명령입니다. 게임 데이터나 인벤토리를 삭제하지
않으며, 재접속이 완료된 뒤 클라이언트 물리 상태가 다시 초기화됩니다. `player`
입력란을 선택하면 현재 온라인 플레이어의 닉네임과 Steam ID가 함께 표시되므로
대상을 고르면 됩니다.

```text
/pal escape player:광주전남의왕심재윤의부경대시위대작전 · steam_76561198863908214
```

등록된 관리 채널에서는 관리 역할 없이 실행할 수 있습니다. 봇은 직접 REST
자격 증명에 접근하지 않으며, 별도 저권한 systemd 서비스가 한 번의 검증된
요청만 처리해 해당 플레이어의 재접속을 요청합니다.

## 명령 로그 채널

Discord 서버 소유자 또는 Administrator가 등록된 Discord 서버의 어느 채널에서든
다음 명령을 실행하면 설정이 재기동 후에도 유지됩니다. 재기동 전용 관리 역할만
가진 사용자는 로그 목적지를 변경할 수 없습니다.

```text
/pal log-channel channel:#서버-로그
```

봇에 대상 채널의 채널 보기, 메시지 보내기, embed 링크 권한이 있어야 합니다.
이후 관리 명령을 사용할 때 명령어, 실행자 ID, 실행 채널, 결과와 시각을 해당
채널에 기록합니다. 로그 채널이 아직 지정되지 않았거나 Discord 전송이 실패한
경우에도 systemd journal에는 같은 명령 사용 기록이 남으며, 관리 명령 자체는
로그 전송 실패와 관계없이 계속 동작합니다.

플레이어가 접속하면 같은 채널에 현재 접속 인원과 REST가 제공하는 `userId`를
기록합니다. `/pal escape` 선택 목록을 위해 observer는 온라인 플레이어의 게임
닉네임과 `userId`만 Discord 봇에 전달합니다. 계정명, IP, 위치와 ping은 observer
단계에서 버립니다. 관측 주기가 10초이므로 접속 로그와 선택 목록은 최대 약 10초
늦을 수 있습니다.

## 재기동과 업데이트

`/pal restart`는 `confirm=True`가 있어야 실행됩니다. 봇은 전용
`/run/palworld-discord` 디렉터리에 고정된 요청 파일만 만들 수 있고,
systemd path unit이 그 파일만 감지해 `palworld-maintenance-restart.service`를
실행합니다. 봇 계정은 임의 systemd 명령, 게임 계정, 유지보수 그룹, REST
credential에 접근할 수 없습니다.

재기동 서비스는 다음 순서로 동작합니다.

1. 별도 updater worktree에서 최신 파일을 내려받아 fingerprint를 비교합니다.
2. 업데이트가 있으면 정상 종료, cold backup, 원자적 릴리스 전환을 수행합니다.
3. 업데이트가 없으면 현재 릴리스를 정상 종료합니다.
4. 서버를 한 번만 기동하고 프로세스와 REST health를 검증합니다.

Steam 또는 네트워크 장애로 업데이트 확인 자체가 실패해도 로그에 경고를 남기고
검증된 현재 릴리스는 예정대로 재기동합니다. 다운로드 실패 중간 산출물을
활성화하지는 않습니다.

같은 서비스가 매일 한국시간 `05:00`에 systemd timer로 실행됩니다. 05:00에
업데이트 검사를 시작하므로 큰 다운로드가 있으면 실제 게임 프로세스 재기동은
다운로드와 검증이 끝난 뒤 시작됩니다. 호스트가 05:00에 꺼져 있었다면
`Persistent=true` 정책에 따라 다음 부팅 시 누락된 작업을 한 번 수행합니다.

## 상태값과 권한 경계

성능 관측값이 기본 30초보다 오래됐으면 봇은 과거 CPU/RAM/FPS를 현재 값처럼
표시하지 않습니다. CPU 100%는 논리 코어 하나를 가득 쓴 상태이며, 예를 들어
`243%`는 약 `2.43`개 코어 사용량입니다. RAM은 호스트 전체가 아니라
`palworld.service` cgroup 사용량입니다.

봇 token은 `/etc/palworld/credentials/discord-token`에 `root:root 0600`으로
저장되고 systemd credential로만 전달됩니다. 비밀값을
`/etc/palworld/discord.env`, Git, Discord 명령 인수에 넣지 마세요.

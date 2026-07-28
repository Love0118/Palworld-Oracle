# Benchmark

성능 인수와 Box64 설정은 동일한 복제 월드에서 비교해야 합니다. 빈 월드 결과로 운영 월드의 동접을 예측하지 마세요.

## 수집 항목

- REST `serverfps`, `serverframetime`, 접속자 수, 기지 수, uptime
- 프로세스 RSS와 시간당 증가량
- 각 CPU 코어 사용률과 steal time
- 디스크 I/O latency, queue, 여유 공간
- Box64 오류와 Palworld save 시간

ARM64 네이티브 관측기의 최신 Prometheus textfile은 다음 경로에 있습니다.

```text
/var/lib/palworld-observer/palworld.prom
```

원시 표본과 경고는 `journalctl -u palworld-observer.service`에서 확인합니다.

## 권장 매트릭스

1. 기본값: legacy performance 인수 없음
2. `PALWORLD_LEGACY_PERF_ARGS=true`, worker 자동
3. legacy 인수 + worker 2
4. legacy 인수 + worker 4 또는 할당 vCPU 범위
5. 가장 좋은 실행 인수에서 Box64 변수를 한 항목씩 비교

각 시험은 서버 시작 후 30분 이상 warm-up하고, 동일한 접속자·기지·작업 팰·이동 경로로 30~60분 측정합니다. 최종 설정은 목표 동접으로 24~72시간 soak test를 통과해야 합니다.

CPU pinning은 기본 최적화가 아닙니다. Oracle A1처럼 균일 코어인 환경에서는 다른 workload와 실제 경합이 확인된 경우에만 비교하세요. CPU hard quota는 메인 스레드를 throttle할 수 있으므로 사용하지 않는 것이 기본입니다.

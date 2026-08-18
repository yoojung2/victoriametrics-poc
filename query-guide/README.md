# VictoriaMetrics 실전 쿼리 가이드

서비스 운영 시 개발자가 꼭 알아야 할 쿼리와 개념을 정리합니다.
모든 쿼리는 VM(바이너리)과 AKS(Helm) 양쪽에서 실제 검증되었습니다.

---

## 검증 환경

| 환경 | VictoriaMetrics | 앱 | 부하 |
|------|----------------|-----|------|
| **VM** (20.194.29.17:8428) | v1.108.1 바이너리 | octocat-supply :3000 | nohup 24h |
| **AKS** (port-forward :9428) | Helm (Single) | octocat-supply Deployment x2 | loadgen-24h Pod |

---

## 1. 트래픽 분석 (가장 먼저 볼 것)

### 1-1. 초당 요청 수 (RPS)

```promql
rate(http_requests_total{job="octocat-supply"}[5m])
```

> **왜 중요한가:** 서비스의 현재 부하 수준을 파악하는 가장 기본적인 지표.
> 배포 전후, 트래픽 스파이크, 장애 시점을 즉시 파악할 수 있다.

검증 결과:
```
VM:  /api/products = 0.9333 req/s (경로당 약 1 req/s)
AKS: /api/products = 0.9800 req/s
```

### 1-2. 경로별 RPS (어디에 트래픽이 집중되나)

```promql
sum by (path) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** 특정 API에 트래픽이 몰리는지, 예상치 못한 경로로 요청이 오는지 파악.
> 불필요한 호출 패턴이나 크롤러/봇 트래픽도 발견할 수 있다.

검증 결과:
```
VM:  7개 경로 각각 ~0.93 req/s, /metrics = 0.10 req/s
AKS: /api/deliveries = 1.68 req/s (loadgen 타이밍 차이)
```

### 1-3. HTTP 상태 코드별 분포

```promql
sum by (status) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** 200 외에 4xx/5xx 비율이 갑자기 올라가면 장애 징후.
> Grafana 대시보드에서 stacked bar로 시각화하면 직관적.

---

## 2. 에러율 & 가용성 (SLO 핵심)

### 2-1. 5xx 에러율

```promql
sum(rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="octocat-supply"}[5m]))
```

> **왜 중요한가:** SLO(Service Level Objective)의 핵심 지표.
> "99.9% 가용성" = 에러율 0.1% 미만 유지.
> 알림 룰: `> 0.01` (1% 초과) 시 경고, `> 0.05` (5%) 시 긴급.

검증 결과:
```
VM:  no 5xx (에러 없음 ✅)
AKS: no 5xx (에러 없음 ✅)
```

### 2-2. 경로별 에러율 (어디서 에러가 나는지)

```promql
sum by (path) (rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
/
sum by (path) (rate(http_requests_total{job="octocat-supply"}[5m]))
```

> 전체 에러율이 낮아도 특정 경로에서만 에러가 집중될 수 있다.

---

## 3. 응답 시간 (Latency) - 사용자 경험의 핵심

### 3-1. P95 응답 시간

```promql
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
)
```

> **왜 중요한가:** 평균보다 P95/P99가 실제 사용자 경험을 반영한다.
> "평균 10ms인데 P95가 500ms" = 20명 중 1명은 느린 응답을 받는다.

검증 결과:
```
VM:  P95 = 9.50 ms ✅
```

### 3-2. 평균 응답 시간

```promql
rate(http_request_duration_seconds_sum{job="octocat-supply"}[5m])
/
rate(http_request_duration_seconds_count{job="octocat-supply"}[5m])
```

### 3-3. 경로별 P95 (느린 API 찾기)

```promql
histogram_quantile(0.95,
  sum by (path, le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
)
```

> 전체 P95는 정상이지만 특정 API가 느릴 수 있다. DB 쿼리 최적화 대상 선정에 유용.

---

## 4. Node.js 런타임 모니터링

### 4-1. 프로세스 메모리 (RSS)

```promql
process_resident_memory_bytes{job="octocat-supply"}
```

> **왜 중요한가:** 메모리 누수 탐지의 핵심.
> 시간이 지나면서 꾸준히 올라가면 메모리 누수 의심.
> 컨테이너 memory limit에 근접하면 OOM Kill 위험.

검증 결과:
```
VM:  98.0 MB
AKS: 92.1 MB
```

### 4-2. V8 Heap 사용량

```promql
nodejs_heap_size_used_bytes{job="octocat-supply"}
```

> RSS와 Heap 차이가 크면 native 모듈(better-sqlite3 등)이 메모리를 쓰고 있다는 뜻.

검증 결과:
```
VM:  22.7 MB (RSS 98MB 중 Heap은 23MB → native 모듈이 ~75MB 사용)
AKS: 20.8 MB
```

### 4-3. Heap 사용률 (OOM 위험도)

```promql
nodejs_heap_size_used_bytes{job="octocat-supply"}
/
nodejs_heap_size_total_bytes{job="octocat-supply"}
```

> 80% 이상이면 GC 부하 증가, V8 OOM 위험.

### 4-4. CPU 사용률

```promql
rate(process_cpu_seconds_total{job="octocat-supply"}[5m])
```

> 결과가 1.0 = CPU 코어 1개 100% 사용. Node.js는 싱글 스레드이므로 1.0에 가까우면 병목.

검증 결과:
```
VM:  1.29% (여유 충분)
AKS: 6.01%
```

### 4-5. Event Loop Lag (Node.js 고유 지표)

```promql
nodejs_eventloop_lag_seconds{job="octocat-supply"}
```

> **왜 중요한가:** Node.js 성능의 핵심 지표.
> Event Loop이 막히면 모든 요청이 느려진다.
> 10ms 이하: 정상 / 50ms 이상: 성능 저하 / 100ms 이상: 심각한 블로킹.

검증 결과:
```
VM:  3.48 ms ✅ (정상)
AKS: 2.45 ms ✅ (정상)
```

### 4-6. Event Loop Lag P99 (순간 스파이크 감지)

```promql
nodejs_eventloop_lag_p99_seconds{job="octocat-supply"}
```

> 평균 lag은 낮은데 P99가 높으면 간헐적 블로킹 발생 중.

### 4-7. GC (가비지 컬렉션) 시간

```promql
rate(nodejs_gc_duration_seconds_sum{job="octocat-supply"}[5m])
```

> **왜 중요한가:** GC가 오래 걸리면 Event Loop이 멈춘다.
> kind별로 확인: `major`가 높으면 Old Space 메모리 압박.

검증 결과:
```
VM:  minor = 0.507 ms/s, major = 0.018 ms/s, incremental = 0.023 ms/s
     → minor GC가 대부분, major는 거의 없음 = 건강한 상태 ✅
```

### 4-8. Active Handles & Open File Descriptors

```promql
nodejs_active_handles_total{job="octocat-supply"}
process_open_fds{job="octocat-supply"}
```

> 시간 경과에 따라 계속 증가하면 리소스 누수 (연결 미해제, 파일 미닫힘).

검증 결과:
```
VM:  Active Handles = 4, Open FDs = 39 (안정적)
```

---

## 5. MetricsQL 확장 기능 (Prometheus에서는 안 되는 것)

### MetricsQL이란?

VictoriaMetrics는 **MetricsQL**이라는 자체 쿼리 언어를 사용합니다.
Prometheus의 PromQL과 **100% 호환**되면서, 추가 기능을 제공합니다.

즉, 기존 PromQL 쿼리를 그대로 사용할 수 있고, 더 편리한 기능도 쓸 수 있습니다.

```
PromQL 쿼리 ──→ VictoriaMetrics에서 그대로 동작 ✅
MetricsQL 쿼리 ──→ Prometheus에서는 에러 ❌
```

---

### 5-1. lookbehind window 자동 선택

#### 개념 설명

`rate()` 함수는 "최근 N분간의 초당 변화율"을 계산합니다.
Prometheus에서는 이 "N분"(window)을 **반드시 직접 지정**해야 합니다.

```promql
# Prometheus: [5m]을 빼면 에러 발생
rate(http_requests_total[5m])    # ✅ 동작
rate(http_requests_total)         # ❌ 에러!
```

VictoriaMetrics는 window를 생략하면 **scrape_interval에 맞춰 자동으로 최적의 window를 선택**합니다.

```promql
# VictoriaMetrics MetricsQL: window 생략 가능
rate(http_requests_total{job="octocat-supply"})         # ✅ 자동 선택
rate(http_requests_total{job="octocat-supply"}[5m])     # ✅ 수동 지정도 가능
```

#### 검증 결과

```
수동 [5m]:     0.933333 req/s
자동 (생략):   0.933333 req/s
→ 동일한 결과 ✅
```

#### 왜 유용한가?

- scrape_interval을 10s → 30s로 바꿔도 쿼리 수정이 필요 없음
- 대시보드의 쿼리를 더 간결하게 작성 가능
- **주의:** 나중에 Prometheus로 마이그레이션할 때는 window를 명시해야 함

---

### 5-2. default 연산자 (빈 결과 처리)

#### 개념 설명

모니터링 대시보드에서 가장 흔한 문제 중 하나:
"데이터가 없으면 그래프에 빈 구간이 생기거나, 계산이 NaN이 된다."

Prometheus에서는 이걸 처리할 방법이 없지만,
VictoriaMetrics는 `default` 연산자로 빈 결과에 기본값을 넣을 수 있습니다.

#### 예시: 존재하지 않는 경로의 요청 수

```promql
# Prometheus: 데이터 없으면 → 결과 없음 (그래프 빈 칸)
rate(http_requests_total{path="/없는경로"}[5m])

# VictoriaMetrics: 데이터 없으면 → 0으로 채움
rate(http_requests_total{path="/없는경로"}[5m]) default 0
```

#### 검증 결과

```
default 없이:  result count: 0 (빈 결과)
default 0:     result count: 1, value: 0 (0으로 채워짐 ✅)
```

#### 실전 활용: 에러율 계산에서 NaN 방지

```promql
# 문제: 5xx 에러가 아예 없으면 분자가 0이 아니라 "없음"이 되어 NaN 발생
sum(rate(http_requests_total{status=~"5.."}[5m]))
/ sum(rate(http_requests_total[5m]))

# 해결: default 0으로 분자가 없을 때 0을 반환
sum(rate(http_requests_total{status=~"5.."}[5m])) default 0
/ sum(rate(http_requests_total[5m]))
```

---

### 5-3. keep_last_value (그래프 끊김 방지)

#### 개념 설명

앱을 재시작하거나, 네트워크 장애로 scrape가 일시 실패하면 어떻게 될까?

- **Prometheus:** 5분 동안 데이터가 없으면 "stale" 마킹 → 그래프가 끊김
- **VictoriaMetrics:** `keep_last_value()`로 마지막 수집 값을 유지할 수 있음

```
그래프 예시 (Prometheus):
메모리 ████████████░░░░░░░████████████
                    ↑ 앱 재시작 (빈 구간)

그래프 예시 (VictoriaMetrics + keep_last_value):
메모리 ████████████████████████████████
                    ↑ 앱 재시작 (마지막 값 유지)
```

#### 쿼리

```promql
# 일반 쿼리: scrape 실패 시 그래프 끊김
process_resident_memory_bytes{job="octocat-supply"}

# keep_last_value: 마지막 값 유지 (연속 그래프)
keep_last_value(process_resident_memory_bytes{job="octocat-supply"})
```

#### 검증 결과

```
VM: 96.8 MB (현재 값 유지 ✅)
```

#### 언제 쓰면 좋나?

- 대시보드에서 그래프 끊김 없이 연속으로 보고 싶을 때
- 배포/재시작이 잦은 서비스의 리소스 모니터링
- **주의:** 앱이 실제로 죽었는데 마지막 값이 유지되면 오해할 수 있으므로,
  알림 룰에서는 사용하지 않는 것이 좋음 (알림은 `up == 0`으로 별도 설정)

---

### 5-4. label 조작 함수 (쿼리 시점에서 라벨 변경)

#### 개념 설명

Prometheus에서 메트릭의 라벨(label)을 바꾸려면 scrape 설정 파일에서
`relabel_configs`를 수정하고 서버를 재시작해야 합니다.

VictoriaMetrics는 **쿼리 시점에서** 라벨을 추가/삭제/변경할 수 있습니다.

#### label_set: 라벨 추가

여러 환경(dev, staging, production)의 메트릭을 하나의 대시보드에서 볼 때 유용합니다.

```promql
# 환경 라벨과 팀 라벨을 쿼리 시점에 추가
label_set(up{job="octocat-supply"}, "env", "production", "team", "backend")
```

검증 결과:
```
원래: {job="octocat-supply", instance="localhost:3000"}
결과: {job="octocat-supply", instance="localhost:3000", env="production", team="backend"} ✅
```

#### label_del: 불필요한 라벨 제거

`instance` 라벨이 있으면 같은 서비스의 여러 인스턴스가 별도 시리즈로 분리됩니다.
집계할 때 방해가 되는 라벨을 제거할 수 있습니다.

```promql
# instance 라벨 제거 → 모든 인스턴스를 하나로 합침
label_del(http_requests_total{job="octocat-supply"}, "instance")
```

검증 결과:
```
원래: {job, instance, method, path, status}
결과: {job, method, path, status}  ← instance 제거됨 ✅
```

#### Prometheus에서는?

```yaml
# Prometheus: 설정 파일에서만 가능 (서버 재시작 필요)
metric_relabel_configs:
  - action: labeldrop
    regex: instance
```

→ VictoriaMetrics는 쿼리 한 줄로 즉시 처리 가능

---

### 5-5. range_last / range_first (구간의 처음/끝 값)

#### 개념 설명

"최근 5분간의 마지막 값" 또는 "최근 5분간의 첫 번째 값"을 가져옵니다.
Prometheus에는 이 함수가 없어서, subquery 등 복잡한 우회가 필요합니다.

```promql
# 최근 5분간의 마지막으로 수집된 값
range_last(http_requests_total{job="octocat-supply", path="/api/products"}[5m])

# 최근 5분간의 첫 번째로 수집된 값
range_first(http_requests_total{job="octocat-supply", path="/api/products"}[5m])
```

검증 결과:
```
VM: range_last = 1478 (현재 누적 요청 수 ✅)
```

#### 언제 쓰나?

- 배포 직전/직후의 메트릭 스냅샷 비교
- 특정 시점의 정확한 값이 필요할 때 (평균이 아닌 실제 값)

---

### 5-6. median (중간값)

#### 개념 설명

Prometheus에서 중간값을 구하려면 `quantile(0.5, ...)` 을 써야 합니다.
VictoriaMetrics는 `median()` 함수를 직접 제공합니다.

```promql
# Prometheus 방식
quantile(0.5, http_request_duration_seconds_count{job="octocat-supply"})

# VictoriaMetrics MetricsQL
median(http_request_duration_seconds_count{job="octocat-supply"})
```

검증 결과:
```
VM: median = 1477 ✅
```

---

### 5-7. count_ne_over_time (특정 값이 아닌 횟수 세기)

#### 개념 설명

"최근 1시간 동안 서비스가 다운된 적이 있나?"를 한 줄로 확인할 수 있습니다.
`up` 메트릭은 정상이면 1, 다운이면 0입니다.
`count_ne_over_time(up[1h], 1)`은 "1이 아니었던 횟수"를 세줍니다.

```promql
# 최근 1시간 중 up이 1이 아니었던(= 다운이었던) 횟수
count_ne_over_time(up{job="octocat-supply"}[1h], 1)
```

검증 결과:
```
VM: 다운타임 횟수: 0 (1시간 내 다운 없음 ✅)
```

#### Prometheus에서는?

이 함수가 없어서 다음과 같이 우회해야 합니다:
```promql
# Prometheus: 복잡한 우회 필요
count_over_time((up{job="octocat-supply"} != 1)[1h:])
```

---

### 5-8. running_sum (누적 합계)

#### 개념 설명

시간이 지남에 따라 값이 어떻게 누적되는지 보여줍니다.
"오늘 하루 동안 총 몇 건의 요청이 들어왔나?"를 시각적으로 볼 때 유용합니다.

```promql
# 1분 단위 요청 증가량의 누적 합계
running_sum(increase(http_requests_total{job="octocat-supply", path="/api/products"}[1m]))
```

검증 결과:
```
VM: 누적합 = 56 ✅
```

#### Grafana 대시보드에서의 활용

- 일일 총 요청 수 누적 그래프
- 배포 후 누적 에러 수 추적
- Prometheus에서는 별도의 recording rule이 필요한 작업을 쿼리 한 줄로 처리

---

### 5번 전체 요약: Prometheus vs MetricsQL 비교표

| 기능 | Prometheus (PromQL) | VictoriaMetrics (MetricsQL) |
|------|--------------------|--------------------------|
| window 생략 | ❌ `rate(x)` → 에러 | ✅ `rate(x)` → 자동 선택 |
| 빈 결과 기본값 | ❌ 없음 (NaN 발생) | ✅ `rate(x[5m]) default 0` |
| 그래프 끊김 방지 | ❌ 5분 후 stale | ✅ `keep_last_value(x)` |
| 쿼리 시 라벨 추가 | ❌ 설정 파일만 가능 | ✅ `label_set(x, "k", "v")` |
| 쿼리 시 라벨 삭제 | ❌ 설정 파일만 가능 | ✅ `label_del(x, "instance")` |
| 구간 처음/끝 값 | ❌ 없음 | ✅ `range_first(x[5m])`, `range_last(x[5m])` |
| 중간값 | ⚠️ `quantile(0.5, x)` | ✅ `median(x)` |
| 특정 값 아닌 횟수 | ❌ 복잡한 우회 필요 | ✅ `count_ne_over_time(x[1h], 1)` |
| 누적 합계 | ❌ recording rule 필요 | ✅ `running_sum(increase(x[1m]))` |

> **핵심:** 기존 PromQL 쿼리는 그대로 쓰면서, 더 편리한 MetricsQL 기능을 점진적으로 도입할 수 있습니다.
> Prometheus → VictoriaMetrics 마이그레이션 시 기존 쿼리 수정은 불필요합니다.

---

## 6. Prometheus vs VictoriaMetrics 쿼리 비교

### 동일하게 동작하는 쿼리 (마이그레이션 안전)

| 쿼리 | 동작 |
|------|------|
| `rate(x[5m])` | ✅ 동일 |
| `sum by (label) (rate(x[5m]))` | ✅ 동일 |
| `histogram_quantile(0.95, ...)` | ✅ 동일 |
| `increase(x[1h])` | ✅ 동일 |
| `avg_over_time(x[5m])` | ✅ 동일 |
| `topk(5, rate(x[5m]))` | ✅ 동일 |

### VictoriaMetrics에서만 가능한 쿼리

| 기능 | MetricsQL | Prometheus |
|------|----------|-----------|
| window 생략 | `rate(x)` | ❌ 에러 |
| 빈 값 기본값 | `rate(x[5m]) default 0` | ❌ 없음 |
| gap 유지 | `keep_last_value(x)` | ❌ 없음 |
| 쿼리 시 라벨 변경 | `label_set(x, "k", "v")` | ❌ 없음 |
| 범위 첫/끝 값 | `range_first(x[5m])` | ❌ 없음 |
| 중간값 | `median(x)` | ❌ `quantile(0.5, x)` 필요 |
| 카운팅 | `count_values_over_time(x[5m])` | ❌ 없음 |

### rate() 동작 차이

```promql
rate(http_requests_total[5m])
```

| 항목 | Prometheus | VictoriaMetrics |
|------|-----------|----------------|
| Extrapolation | 시간 범위 외삽 → 실제보다 높게 나올 수 있음 | counter 증가분 기반 → 더 정확 |
| Counter reset 처리 | 단순 증가분 | 더 정교한 reset 감지 |
| 마지막 scrape 누락 | stale 마킹 | 설정 가능 (`keep_last_value`) |

---

## 7. 운영 알림 추천 룰

실제 서비스에서 설정하면 좋은 알림 기준:

```yaml
# victoriametrics alert rules 형식
groups:
  - name: octocat-supply
    rules:
    # 5xx 에러율 1% 초과 (5분간)
    - alert: HighErrorRate
      expr: |
        sum(rate(http_requests_total{job="octocat-supply", status=~"5.."}[5m]))
        / sum(rate(http_requests_total{job="octocat-supply"}[5m]))
        > 0.01
      for: 5m

    # P95 응답시간 500ms 초과
    - alert: HighLatency
      expr: |
        histogram_quantile(0.95,
          sum by (le) (rate(http_request_duration_seconds_bucket{job="octocat-supply"}[5m]))
        ) > 0.5
      for: 5m

    # Event Loop Lag 50ms 초과
    - alert: EventLoopBlocked
      expr: nodejs_eventloop_lag_seconds{job="octocat-supply"} > 0.05
      for: 3m

    # 메모리 400MB 초과 (컨테이너 limit 512MB 기준)
    - alert: HighMemory
      expr: process_resident_memory_bytes{job="octocat-supply"} > 400*1024*1024
      for: 10m

    # 타겟 다운
    - alert: TargetDown
      expr: up{job="octocat-supply"} == 0
      for: 1m
```

---

## 8. 쿼리 작성 시 주의사항

### rate() range 선택

```promql
# scrape_interval이 10s일 때:
rate(x[10s])  # ❌ 데이터 포인트 1~2개 → 부정확
rate(x[30s])  # ⚠️ 최소한이지만 불안정
rate(x[1m])   # ✅ 적절 (6개 포인트)
rate(x[5m])   # ✅ 안정적 (30개 포인트)
```

> **규칙:** range는 scrape_interval의 최소 4배 이상 사용.

### label cardinality 주의

```promql
# ❌ 위험: /api/products/1, /api/products/2... 무한 증가
http_requests_total{path=~"/api/products/.*"}

# ✅ 안전: 정규화된 경로 또는 집계
sum by (method) (rate(http_requests_total[5m]))
```

> label 값이 무한히 늘어나면 VictoriaMetrics 메모리/디스크를 소모한다.
> `req.originalUrl` 대신 라우트 패턴 (`/api/products/:id`)으로 정규화하는 것이 프로덕션 모범 사례.

### counter vs gauge 구분

```promql
# counter (누적값) → rate() 또는 increase() 사용
rate(http_requests_total[5m])       # ✅ 초당 변화율
increase(http_requests_total[1h])   # ✅ 1시간 증가량
http_requests_total                 # ⚠️ 누적값 그 자체 (그래프로 무의미)

# gauge (현재값) → 그대로 사용
process_resident_memory_bytes       # ✅ 현재 메모리
nodejs_eventloop_lag_seconds        # ✅ 현재 lag
```

---

## 참고

- [MetricsQL 공식 문서](https://docs.victoriametrics.com/metricsql/)
- [MetricsQL vs PromQL 비교](https://docs.victoriametrics.com/metricsql/#metricsql-features)
- [VictoriaMetrics Alerting](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#alerting)
- [USE Method (Brendan Gregg)](https://www.brendangregg.com/usemethod.html) - 시스템 성능 분석 프레임워크
- [RED Method (Tom Wilkie)](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/) - 서비스 모니터링 프레임워크

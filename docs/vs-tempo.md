# VictoriaTraces vs Grafana Tempo — 비교 및 PoC 가이드

> 📚 [← 전체 개요(README)](../README.md) · [카디널리티](cardinality.md) · [확장/HA](scaling.md)

이 문서는 **분산 트레이싱(traces)** 백엔드인 **VictoriaTraces**와 **Grafana Tempo**를 비교하고,
동일 트레이스로 나란히 평가하는 PoC 아키텍처를 정리합니다.
모든 사실은 공식 문서 기준이며, 불확실/미검증 항목은 명시했습니다(하단 Sources).

> ⚠️ **먼저 짚을 점**
> - **VictoriaMetrics(metrics) ↔ Tempo(traces)는 비교 대상이 아닙니다.** 서로 다른 관측성 축입니다.
>   Tempo의 직접 비교 대상은 **VictoriaTraces**입니다.
> - **VictoriaTraces는 아직 GA가 아닙니다** (2026 기준 `v0.x`, 최신 `v0.11.0`). 평가/PoC용으로 적합하며 프로덕션 채택은 성숙도를 감안하세요.
> - VictoriaMetrics가 주장하는 효율 수치(RAM 3.7x 등)는 **벤더 자체 벤치마크**로, 독립 검증된 값이 아닙니다.

---

## 1. 관측성 3축에서의 위치

| 축 | 신호 | VictoriaMetrics 진영 | Grafana 진영 |
|----|------|----------------------|--------------|
| Metrics | 수치 시계열 | **VictoriaMetrics** | Mimir/Prometheus |
| Logs | 로그 | VictoriaLogs | Loki |
| **Traces** | 분산 추적 | **VictoriaTraces** | **Tempo** |

> Metrics는 "무엇이 얼마나"(집계 경향), Traces는 "어느 요청이 어디서"(개별 요청 원인). 함께 씁니다.

---

## 2. 사실 비교표 (공식 문서 기준)

| 항목 | VictoriaTraces | Grafana Tempo |
|------|----------------|---------------|
| 성숙도 | **Pre-GA, `v0.x`** (최신 `v0.11.0`) | GA, 널리 사용 |
| Docker 이미지 | `victoriametrics/victoria-traces` | `grafana/tempo` |
| 바이너리 | `victoria-traces` (릴리스: `victoria-traces-prod`) | `tempo` |
| 기본 포트 | **`10428`** 단일(수집+쿼리+VMUI+/metrics) | OTLP `4317`(gRPC)/`4318`(HTTP), 쿼리 API `3200` |
| 저장 모델 | **로컬 디스크**(일 단위 파티션), 외부 스토리지·DB 불필요 | **오브젝트 스토리지**(S3/GCS/Azure Blob) 중심, dev는 로컬 FS |
| 수집 프로토콜 | **OTLP 전용** (HTTP `/insert/opentelemetry/v1/traces` + gRPC) | OTLP + Jaeger + Zipkin + OpenCensus |
| 쿼리 API | **Jaeger JSON API**(안정, `/select/jaeger`) + **TraceQL 서브셋**(실험적, `/select/tempo`, ≥v0.9.4) | **TraceQL**(네이티브/완전) |
| Grafana 데이터소스 | **Jaeger**(권장) 또는 **Tempo**(실험적 부분지원) | **Tempo**(네이티브/완전) |
| 네이티브 쿼리언어 | LogsQL(VictoriaLogs 공유) | TraceQL |
| 운영 복잡도 | 낮음(단일 바이너리, 의존성 없음) | 상대적으로 높음(오브젝트 스토리지 버킷 필요) |
| 서비스 그래프 | 실험적, 기본 off (`-servicegraph.enableTask=true`) | 지원(metrics-generator) |

### 핵심 차별점
- **저장소 철학이 정반대**: VictoriaTraces는 "의존성 없는 단일 바이너리 + 로컬 디스크", Tempo는 "값싼 오브젝트 스토리지에 대량 저장".
- **수집**: 둘 다 OTLP를 받으므로 **동일 트레이스 소스로 공정 비교 가능**. Tempo는 Jaeger/Zipkin도 직접 수용.
- **Grafana 통합 성숙도**: Tempo는 네이티브 완전 지원. VictoriaTraces는 Jaeger 데이터소스가 안정적이고, Tempo/TraceQL 호환은 **실험적·부분**(일부 TraceQL 함수/드릴다운 미지원 명시).

---

## 3. PoC 아키텍처 — 동일 트레이스를 양쪽에 fan-out

```
[telemetrygen 또는 HotROD]  ──OTLP──▶ [OpenTelemetry Collector] ──┬─OTLP/HTTP─▶ VictoriaTraces
   (동일 트레이스 소스)                    (1 receiver, 2 exporter)  │   :10428/insert/opentelemetry/v1/traces
                                                                   └─OTLP/gRPC─▶ Tempo :4317
                                                                                    │
                        Grafana: [Jaeger DS → VT :10428/select/jaeger]  +  [Tempo DS → Tempo :3200]
```

> OTel Collector가 한 번 받아 **두 백엔드로 동시 전송** → 입력이 동일하므로 apples-to-apples 비교. (VictoriaTraces 문서도 이 멀티플렉싱 패턴을 권장)

---

## 4. 실행 방법 (검증된 커맨드 — 공식 문서)

### 4-1. VictoriaTraces (단일 노드)
```bash
docker run --rm -it -p 10428:10428 \
  -v ./victoria-traces-data:/victoria-traces-data \
  docker.io/victoriametrics/victoria-traces:latest
# VMUI:        http://localhost:10428/select/vmui
# OTLP 수집:    http://localhost:10428/insert/opentelemetry/v1/traces
# Jaeger 쿼리:  http://localhost:10428/select/jaeger
```
주요 플래그: `-storageDataPath`, `-retentionPeriod`(기본 7d), `-retention.maxDiskSpaceUsageBytes`, `-servicegraph.enableTask=true`(서비스그래프).

### 4-2. Grafana Tempo (단일 노드, 로컬 FS)
```bash
docker run --rm -it -p 3200:3200 -p 4317:4317 -p 4318:4318 \
  -v ./tempo-data:/var/tempo \
  grafana/tempo:latest -config.file=/etc/tempo.yaml
# OTLP: 4317(gRPC)/4318(HTTP), 쿼리 API: 3200
```
> Tempo는 config 파일이 필요합니다(로컬 FS 백엔드 + OTLP receiver 설정). 오브젝트 스토리지(Azure Blob 등)를 붙이면 프로덕션 구성이 됩니다.

### 4-3. 트레이스 생성 (둘 중 택1)
```bash
# (A) 합성 트레이스 — 볼륨/벤치마크용
telemetrygen traces --otlp-endpoint <collector>:4317 --otlp-insecure --traces 1000

# (B) HotROD 데모앱 — 실제 서비스 호출 트레이스 (VictoriaTraces 문서 예시)
docker run -p8080-8083:8080-8083 --rm \
  --env OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://<host-ip>:10428/insert/opentelemetry/v1/traces \
  jaegertracing/example-hotrod:latest all
# 브라우저 http://127.0.0.1:8080/ 에서 클릭 → 트레이스 발생
```

### 4-4. Grafana 데이터소스 (본 PoC의 기존 Grafana 재사용)
```yaml
# VictoriaTraces — Jaeger 타입 (권장, 안정)
- name: VictoriaTraces
  type: jaeger
  url: http://<vt-host>:10428/select/jaeger
# Tempo — 네이티브
- name: Tempo
  type: tempo
  url: http://<tempo-host>:3200
```
> VictoriaTraces를 Tempo 데이터소스로도 붙일 수 있으나(실험적, `/select/tempo`), 일부 TraceQL/드릴다운은 미지원이라 **Jaeger 데이터소스가 안정적**입니다.

---

## 5. 비교 시 관전 포인트

| 관점 | 확인할 것 |
|------|-----------|
| 수집 | 동일 OTLP를 양쪽이 문제없이 받는가 (VT는 OTLP만) |
| 쿼리 UX | Tempo=TraceQL 네이티브 vs VT=Jaeger UI/실험적 TraceQL |
| 운영 | VT=단일 바이너리·로컬디스크 vs Tempo=오브젝트 스토리지 필요 |
| 리소스 | 동일 트레이스량에서 CPU/RAM/디스크 (벤더 주장 검증) |
| Grafana 통합 | Tempo 네이티브 완전 vs VT Jaeger 안정/Tempo 실험 |

---

## 6. 결론 요약

- **Tempo**: GA·성숙, TraceQL 네이티브, 오브젝트 스토리지 기반 대용량 — 클라우드 표준 스택에 적합.
- **VictoriaTraces**: 의존성 없는 단일 바이너리·로컬 디스크로 **운영이 단순**하고, VictoriaMetrics/Logs와 스택 일관성. 단 **Pre-GA**이며 Grafana TraceQL 호환은 실험적.
- **선택 기준**: 이미 VictoriaMetrics/Logs를 쓰고 운영 단순성을 원하면 VictoriaTraces 평가 가치가 큼. Grafana 네이티브 TraceQL·성숙도가 우선이면 Tempo.

---

## Sources (공식 문서)

- VictoriaTraces 개요/플래그/포트: https://docs.victoriametrics.com/victoriatraces/
- Quickstart(Docker/OTLP/HotROD/Jaeger DS): https://docs.victoriametrics.com/victoriatraces/quickstart/
- 데이터 수집(OTLP HTTP/gRPC): https://docs.victoriametrics.com/victoriatraces/data-ingestion/
- 쿼리(Jaeger API, Tempo/TraceQL 실험적): https://docs.victoriametrics.com/victoriatraces/querying/
- 로드맵(Pre-GA 상태): https://docs.victoriametrics.com/victoriatraces/roadmap/
- 저장소/릴리스: https://github.com/VictoriaMetrics/VictoriaTraces
- Grafana Tempo(이미지/포트/TraceQL/오브젝트스토리지): https://grafana.com/docs/tempo/latest/

> ⚠️ 미검증/불확실: VictoriaTraces의 네이티브 Jaeger/Zipkin 수집은 **없음**(OTLP만). Tempo/TraceQL 호환은 **실험적·부분**. 효율 수치는 **벤더 자체 벤치마크**. GA 일정 미공개.

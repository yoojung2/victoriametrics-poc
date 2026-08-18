# Step 2 — 앱 계측(prom-client)으로 실제 앱 메트릭 수집

> 📚 [← 전체 개요(README)](../README.md) · [Step 1: 설치](step1-install.md) · **Step 2: 앱 메트릭 연동**

Step 1에서 만든 VictoriaMetrics에, **실제 애플리케이션([octocat-supply](https://github.com/Azure-Samples/octocat-supply))의 트래픽 메트릭**을 흘려보내 vmui에서 쿼리로 확인합니다.

## 전체 구조

```
[octocat API + prom-client] --/metrics--> [vmagent] --remote_write--> [VictoriaMetrics :8428]
        ↑ loadgen.sh 가 트래픽 발생                (scrape 10s)              ↑ vmui 에서 쿼리
```

| 구성요소 | 역할 |
|----------|------|
| octocat-supply API | Express 앱. **prom-client 계측 추가**로 `/metrics` 노출 |
| vmagent | `/metrics`를 스크레이프 → VictoriaMetrics로 `remote_write` |
| VictoriaMetrics | Step 1의 VM(`:8428`)에서 저장/쿼리 |
| loadgen.sh | API에 HTTP 트래픽 발생 |

> **왜 계측이 필요한가?** octocat-supply는 기본적으로 `/metrics`가 **없습니다**(`prom-client` 미포함). 실제로 확인하면 404가 납니다:
> ```bash
> $ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/metrics
> 404          # Cannot GET /metrics
> ```
> 그래서 아래처럼 계측 코드를 추가해 200으로 만듭니다.

---

## 1. prom-client 계측 추가

### 1-1. 의존성 설치

```bash
cd octocat-supply/api
npm install prom-client
```

### 1-2. 계측 미들웨어 추가

[`step2/app/metrics-middleware.ts`](../step2/app/metrics-middleware.ts) 를 `api/src/metrics-middleware.ts` 로 복사합니다. 핵심:

- `collectDefaultMetrics()` — Node.js 프로세스 메트릭(CPU/메모리/GC 등) 자동 수집
- `http_requests_total` (Counter) — `method`/`route`/`status` 라벨별 요청 수
- `http_request_duration_seconds` (Histogram) — 요청 지연시간 분포

### 1-3. index.ts 연결

[`step2/app/index.ts.patch`](../step2/app/index.ts.patch) 참고. 실제 적용한 변경은 단 3곳:

```diff
 import { errorHandler } from './utils/errors';
+import { metricsMiddleware, metricsHandler } from './metrics-middleware';

 app.use(express.json());

+// Prometheus 계측: 모든 라우트보다 먼저 등록해 요청 수/지연시간 수집
+app.use(metricsMiddleware);
+// Prometheus 스크레이프 엔드포인트
+app.get('/metrics', metricsHandler);

 app.use('/api/deliveries', deliveryRoutes);
```

---

## 2. 앱 실행 후 /metrics 확인 (검증 완료)

```bash
cd octocat-supply/api
npm run dev          # -> Server is running on port 3000
```

```bash
# 상태코드 확인
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/metrics
200                                     # ← 이제 200! (계측 전에는 404)

# 트래픽 발생 후 계측 카운터 확인
$ curl -s http://localhost:3000/metrics | grep '^http_requests_total'
http_requests_total{method="GET",route="/metrics",status="200"} 1
http_requests_total{method="GET",route="/",status="200"} 30
http_requests_total{method="GET",route="/nonexistent",status="404"} 15
```

정상 동작 확인 ✓ (요청 수가 라벨별로 집계되고, 404도 별도 status로 잡힘)

> ⚠️ **알려진 관찰점 — route 라벨 세분화**
> Express 서브라우터(`app.use('/api/products', router)`)는 `req.route.path`가 `/`로 잡혀
> `/api/products`, `/api/branches` 등이 route=`/`로 합쳐집니다.
> 엔드포인트별로 나누려면 미들웨어에서 `req.baseUrl + (req.route?.path||'')`를 route 라벨로 쓰세요.
> (`metrics-middleware.ts` 주석에도 기록해 둠)

---

## 3. vmagent로 스크레이프 → VictoriaMetrics remote_write

Docker 없이 바이너리로 실행하는 예시입니다. ([`step2/vmagent/scrape.yml`](../step2/vmagent/scrape.yml))

```bash
# vmagent 바이너리 다운로드 (vmutils 번들에 포함)
VM_VERSION=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases/latest \
  | grep -oP '"tag_name":\s*"\K[^"]+')
wget "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/vmutils-linux-amd64-${VM_VERSION}.tar.gz"
tar -xzf vmutils-linux-amd64-${VM_VERSION}.tar.gz   # -> vmagent-prod 등 포함

# 스크레이프 + remote_write 실행 (VM_PUBIP = Step 1의 VM Public IP)
./vmagent-prod \
  -promscrape.config=step2/vmagent/scrape.yml \
  -remoteWrite.url=http://<VM_PUBIP>:8428/api/v1/write
```

`scrape.yml` 요약:
```yaml
global:
  scrape_interval: 10s
scrape_configs:
  - job_name: octocat-api
    metrics_path: /metrics
    static_configs:
      - targets: ['localhost:3000']
        labels: { app: octocat-api }
```

---

## 4. 트래픽 발생

[`scripts/loadgen.sh`](../scripts/loadgen.sh) — 여러 엔드포인트에 60초간 요청을 섞어 보냅니다(정상 + 404).

```bash
./scripts/loadgen.sh http://localhost:3000 60
```

---

## 5. VictoriaMetrics(vmui)에서 쿼리 확인 — ✅ 실측 검증 완료

`http://<VM_PUBIP>:8428/vmui` 접속 후 아래 쿼리를 실행합니다.
아래 수치는 `loadgen.sh`로 **805개 요청(7개 엔드포인트, 30초)** 을 발생시킨 뒤 실제로 조회한 결과입니다.

| 쿼리 | 의미 | 실측 결과 |
|------|------|-----------|
| `http_requests_total` | 라벨별 누적 요청 수 | 3 시리즈 (`/`=357, `/metrics`=13, `/nonexistent`=59) |
| `sum(rate(http_requests_total[1m]))` | 전체 초당 요청률(RPS) | **27.36 req/s** |
| `sum by (status) (rate(http_requests_total[1m]))` | 상태코드별 RPS | 200 → 23.48 / 404 → 3.88 |
| `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` | p95 응답시간 | **4.75 ms** |
| `process_resident_memory_bytes{app="octocat-api"}` | 앱 메모리(RSS) | 112.7 MB |

> 저장된 메트릭 종류: **48개** (`http_*`, `nodejs_*`, `process_*`)

CLI 검증 예 (실제 사용):
```bash
# URL 인코딩 이슈 피하려면 --data-urlencode 사용 권장
curl -s "http://<VM_PUBIP>:8428/api/v1/query" \
  --data-urlencode 'query=sum by (status) (rate(http_requests_total[1m]))' | jq .
```

---

## 6. 쿼리 시 중요한 점 (MetricsQL 실전 노트)

실측하며 확인한, 데이터를 "제대로" 보기 위한 핵심 포인트입니다.

### 6-1. Counter는 raw 값이 아니라 `rate()`로 본다
`http_requests_total`은 **단조 증가 카운터**입니다. raw 값(357, 59…)은 "시작 이후 누적"이라 그래프로는 의미가 약합니다.
초당 처리량은 반드시 `rate()`(구간 증가분/초)로 봅니다.
```promql
sum(rate(http_requests_total[1m]))          # 전체 RPS
sum by (route,status) (rate(...[1m]))        # 라벨별 분해
```

### 6-2. `[1m]` 같은 구간(range)은 scrape_interval의 4배 이상
`scrape_interval=5s`인데 `rate(...[5s])`처럼 너무 짧게 잡으면 구간 안에 데이터포인트가 1개뿐이라 `rate`가 비거나 튑니다.
**경험칙: range ≥ scrape_interval × 4** (여기선 `[1m]` 사용 → 5s×12포인트).

### 6-3. Histogram의 p95는 `_bucket` + `le`로 계산
지연시간 히스토그램은 `_bucket{le=...}`, `_sum`, `_count` 세 시리즈로 저장됩니다.
분위수는 반드시 `le` 라벨을 살려서 집계:
```promql
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```
`sum by (le)`를 빼먹으면 결과가 깨집니다. 정밀도는 미들웨어의 `buckets` 경계에 좌우됩니다.

### 6-4. instant query vs range query
- `/api/v1/query` (instant): 특정 시점의 값 1개 → 표/현재값 확인용
- `/api/v1/query_range` (range): 시간축 그래프 → vmui 그래프 탭이 이걸 씀
- vmui에서 데이터가 "안 보이면" 대부분 **우측 시간범위**가 데이터 밖이라서임 → `Last 15 minutes`로 조정

### 6-5. 라벨 카디널리티 주의
`route` 라벨에 `/api/products/123`처럼 **ID가 그대로 들어가면** 시리즈가 폭발합니다.
반드시 파라미터화된 경로(`/api/products/:id`)로 정규화하세요. (본 PoC의 알려진 관찰점 참고)

---

## 7. VictoriaMetrics vs Prometheus — 차이점

이 PoC는 "Prometheus 생태계(prom-client, PromQL, `/metrics`)"를 그대로 쓰되 **저장·쿼리 엔진만 VictoriaMetrics**로 바꾼 구조입니다. 핵심 차이를 정리합니다.

### 7-1. 수집 모델 — Prometheus 서버가 없다
| | Prometheus | 본 PoC(VictoriaMetrics) |
|---|---|---|
| 스크레이프 | Prometheus 서버가 직접 | **vmagent**가 스크레이프 |
| 저장 | Prometheus 로컬 TSDB | VictoriaMetrics(단일 바이너리) |
| 전송 | (자체 저장) | vmagent → `remote_write` → VM |

> 즉 Prometheus 서버 없이 `vmagent + VictoriaMetrics` 조합으로 대체합니다. `/metrics` 노출과 scrape config 문법은 **Prometheus와 100% 호환**이라 앱 계측 코드는 그대로 재사용됩니다.

### 7-2. 쿼리 언어 — PromQL ⊂ MetricsQL
VictoriaMetrics는 **MetricsQL**을 씁니다. PromQL의 상위 호환이라 기존 PromQL은 그대로 동작하고, 편의 기능이 추가됩니다:
- `rate(m)` 처럼 **구간 생략 가능**(기본 구간 자동), `range_*`, `histogram_quantile`의 개선판 등
- `WITH` 템플릿, `keep_metric_names`, 더 관대한 파싱

### 7-3. 저장/성능
- VictoriaMetrics는 **압축률·메모리 효율이 높고** 단일 바이너리로 운영이 단순 (Step 1처럼 systemd 하나면 끝)
- 높은 카디널리티/장기 보존에 상대적으로 유리, `-retentionPeriod`로 간단히 보존기간 설정

### 7-4. 호환 엔드포인트
- 쓰기: Prometheus `remote_write`, Influx, Graphite, OpenTSDB 등 다중 프로토콜 수용
- 읽기: Prometheus HTTP API(`/api/v1/query`, `/query_range`) 호환 → **Grafana에서 Prometheus 데이터소스로 그대로 연결 가능**

> 요약: **계측·수집 표준(Prometheus)은 유지**하고, **TSDB만 VictoriaMetrics로 교체**해 운영 단순성과 효율을 얻는 구성입니다.

---

## 8. VM에서 24시간 상시화 — systemd 서비스 구성 (✅ 실측 완료)

2~5절은 로컬 세션(터미널)에 묶여 실행돼서 **세션이 닫히면 종료**됩니다.
실제 서비스처럼 **재부팅·세션 종료와 무관하게 계속** 돌리려면 Azure VM 자체에 systemd 서비스로 올립니다.
아래는 VM(`52.141.7.189`)에 실제로 구성한 내용입니다.

### 8-1. 구성 요소 (3개 서비스 + VictoriaMetrics)

```
[loadgen.service] ──HTTP 무한루프──▶ [octocat-api.service :3000] ──/metrics──▶
   [vmagent.service] ──remote_write──▶ [victoriametrics.service :8428]  ◀── 쿼리
```

| 서비스 | 파일 | 역할 |
|--------|------|------|
| `octocat-api` | [step2/systemd/octocat-api.service](../step2/systemd/octocat-api.service) | 계측 앱(node dist/index.js), `/metrics` 노출 |
| `vmagent` | [step2/systemd/vmagent.service](../step2/systemd/vmagent.service) | scrape → 로컬 `:8428` remote_write |
| `loadgen` | [step2/systemd/loadgen.service](../step2/systemd/loadgen.service) + [loadgen-loop.sh](../step2/systemd/loadgen-loop.sh) | 무한 부하 루프 (`Restart=always`) |
| `victoriametrics` | (Step 1) | 저장/쿼리 |

### 8-2. 사전 준비 (VM에 Node + 앱 + vmagent)

```bash
# Node 20 설치
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 계측된 api 소스 배치 후 빌드
sudo mkdir -p /opt/octocat && sudo tar xzf octocat-api.tgz -C /opt/octocat
cd /opt/octocat/api && npm install --omit=dev && npm install prom-client && npx tsc

# vmagent 바이너리 배치 (Step 1의 vmutils 번들에 포함)
sudo mv vmagent-prod /usr/local/bin/vmagent && sudo chmod +x /usr/local/bin/vmagent
```

### 8-3. 설정/스크립트 배치 + 서비스 등록

```bash
sudo mkdir -p /etc/vmagent /var/lib/vmagent
sudo cp scrape.yml /etc/vmagent/scrape.yml
sudo cp loadgen-loop.sh /usr/local/bin/ && sudo chmod 755 /usr/local/bin/loadgen-loop.sh
sudo chown azureuser:azureuser /var/lib/vmagent

sudo cp octocat-api.service vmagent.service loadgen.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now octocat-api vmagent loadgen
```

### 8-4. 검증 (실측)

```bash
$ systemctl is-active octocat-api vmagent loadgen victoriametrics
active / active / active / active

# 순수 systemd 부하 상태 (로컬 프로세스 모두 종료 후)
$ curl -s "http://<VM_PUBIP>:8428/api/v1/query" \
    --data-urlencode 'query=sum by (status)(rate(http_requests_total{env="poc"}[1m]))'
# status=200 → 475 req/s,  status=404 → 68 req/s
```

3개 서비스 모두 `enabled` → **재부팅 후 자동 시작**. 세션과 무관하게 24시간+ 유지됩니다.

### 8-5. ⚠️ 구성 중 실제로 겪은 함정 (기록)

| 증상 | 원인 | 해결 |
|------|------|------|
| `vmagent` `activating`만 반복, `status=255` | `sudo cp`한 `scrape.yml`이 root 소유(600) → azureuser 실행 시 **permission denied** | `sudo chmod 644 /etc/vmagent/scrape.yml`, 디렉터리 `755` |
| `loadgen` `status=126 Permission denied` | `sudo cp`가 `chmod +x`를 덮어써 실행권한 상실 | `sudo chmod 755 /usr/local/bin/loadgen-loop.sh` |
| RPS가 비정상적으로 높음(중복) | 세션 로컬 loadgen과 systemd loadgen이 **동시 실행** | 로컬 프로세스 종료 후 systemd만 유지 |

### 8-6. 운영 명령

```bash
sudo systemctl status loadgen           # 상태 확인
sudo journalctl -u vmagent -f           # 로그 추적
sudo systemctl stop loadgen             # 부하 일시정지
sudo systemctl disable --now loadgen    # 부하 완전 중지 + 자동시작 해제
```

---

## 트러블슈팅

| 증상 | 원인/해결 |
|------|-----------|
| `/metrics` 404 | 계측 미적용. 미들웨어/라우트 등록 확인, `app.use(metricsMiddleware)`가 라우트보다 위인지 확인 |
| vmui에 데이터 없음 | vmagent `-remoteWrite.url` 오타/포트, VM NSG 8428 인바운드 확인 |
| route 라벨이 전부 `/` | 위 "알려진 관찰점" 참고 — `req.baseUrl` 조합 사용 |
| 카운터가 안 올라감 | 미들웨어가 `res.on('finish')`에서 집계 — 응답이 끝나야 반영됨 |

---

## 이 단계에서 실제로 만든 파일

```
step2/
├── app/
│   ├── metrics-middleware.ts   # prom-client 계측 미들웨어 (api/src/에 복사)
│   └── index.ts.patch          # index.ts 연결 diff (3곳 변경)
├── vmagent/
│   └── scrape.yml              # vmagent 스크레이프 설정
└── systemd/                    # VM 24시간 상시화 (8절)
    ├── octocat-api.service     # 앱 서비스
    ├── vmagent.service         # vmagent 서비스
    ├── loadgen.service         # 부하 서비스
    ├── loadgen-loop.sh         # 무한 부하 루프
    └── scrape.yml              # /etc/vmagent/scrape.yml 원본
scripts/
└── loadgen.sh                  # 트래픽 생성기 (일회성)
```

# Step 2: 샘플 앱 배포 & 메트릭 수집

octocat-supply 앱을 VM에 배포하고, VictoriaMetrics로 메트릭을 수집하여 vmui에서 확인합니다.

## 전체 흐름

```
octocat-supply (API :3000)
       │
       ├─ /metrics 엔드포인트 (prom-client)
       │
       ▼
VictoriaMetrics (promscrape → :8428)
       │
       ▼
vmui 대시보드에서 쿼리
```

---

## 사전 조건

- Step 1 완료 (VM에 VictoriaMetrics 구동 중)
- VM SSH 접속 가능

```bash
VM_IP=$(az vm show -d -g rg-victoriametrics -n vm-victoriametrics --query publicIps -o tsv)
ssh azureuser@$VM_IP
```

---

## 2-1. Node.js & 빌드 도구 설치

```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs make git
```

---

## 2-2. octocat-supply 앱 클론 & 설치

```bash
cd ~
git clone https://github.com/Azure-Samples/octocat-supply.git
cd octocat-supply
make install
```

---

## 2-3. Prometheus 메트릭 엔드포인트 추가

Express API에 `prom-client`를 추가하여 `/metrics` 엔드포인트를 노출합니다.

```bash
cd ~/octocat-supply/api
npm install prom-client
```

`api/src/index.ts` (또는 메인 진입점)에 아래 코드 추가:

```typescript
import { collectDefaultMetrics, register, Counter, Histogram } from 'prom-client';

// 기본 Node.js 메트릭 수집 (메모리, CPU, GC 등)
collectDefaultMetrics();

// HTTP 요청 카운터
const httpRequestsTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status'],
});

// HTTP 요청 지연시간
const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'path'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5],
});

// 미들웨어로 등록
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, path: req.path });
  res.on('finish', () => {
    httpRequestsTotal.inc({ method: req.method, path: req.path, status: res.statusCode });
    end();
  });
  next();
});

// /metrics 엔드포인트
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
```

---

## 2-4. 앱 실행

```bash
cd ~/octocat-supply
make dev &

# 동작 확인
curl http://localhost:3000/api/products
curl http://localhost:3000/metrics
```

`/metrics` 응답에 `http_requests_total`, `process_resident_memory_bytes` 등이 보이면 정상입니다.

---

## 2-5. VictoriaMetrics scrape 설정

VictoriaMetrics가 앱의 `/metrics`를 주기적으로 수집하도록 설정합니다.

```bash
# scrape 설정 파일 생성
sudo mkdir -p /etc/victoriametrics
sudo tee /etc/victoriametrics/promscrape.yml <<EOF
scrape_configs:
  - job_name: 'octocat-supply'
    scrape_interval: 10s
    static_configs:
      - targets: ['localhost:3000']
    metrics_path: '/metrics'
EOF
```

systemd 서비스에 promscrape 옵션 추가:

```bash
sudo sed -i 's|ExecStart=.*|ExecStart=/usr/local/bin/victoria-metrics -storageDataPath=/var/lib/victoria-metrics-data -httpListenAddr=:8428 -retentionPeriod=30d -promscrape.config=/etc/victoriametrics/promscrape.yml|' /etc/systemd/system/victoriametrics.service

sudo systemctl daemon-reload
sudo systemctl restart victoriametrics

# scrape 대상 확인
curl http://localhost:8428/targets
```

`/targets`에서 `octocat-supply` job이 `UP` 상태인지 확인합니다.

---

## 2-6. 트래픽 생성

```bash
# 단발 부하
for i in $(seq 1 200); do
  curl -s http://localhost:3000/api/products > /dev/null
  curl -s http://localhost:3000/api/orders > /dev/null
  curl -s http://localhost:3000/api/branches > /dev/null
  sleep 0.2
done

# 지속적 트래픽 (백그라운드, Ctrl+C로 중지)
while true; do
  curl -s http://localhost:3000/api/products > /dev/null
  curl -s http://localhost:3000/api/orders > /dev/null
  sleep 1
done
```

---

## 2-7. vmui에서 쿼리 확인

브라우저에서 `http://<VM_PUBLIC_IP>:8428/vmui` 접속 후 아래 쿼리를 실행합니다.

### 기본 확인

```promql
# scrape 대상 상태
up{job="octocat-supply"}

# 수집된 메트릭 목록
{job="octocat-supply"}
```

### HTTP 트래픽 분석

```promql
# 총 요청 수
http_requests_total{job="octocat-supply"}

# 초당 요청 수 (RPS)
rate(http_requests_total{job="octocat-supply"}[1m])

# 경로별 요청 수
sum by (path) (rate(http_requests_total[1m]))

# 상태코드별 분포
sum by (status) (http_requests_total)
```

### 응답 시간 분석

```promql
# 평균 응답 시간
rate(http_request_duration_seconds_sum[1m]) / rate(http_request_duration_seconds_count[1m])

# 95 퍼센타일 응답 시간
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### Node.js 런타임 메트릭

```promql
# 메모리 사용량
process_resident_memory_bytes{job="octocat-supply"}

# CPU 사용률
rate(process_cpu_seconds_total{job="octocat-supply"}[1m])

# Event Loop Lag
nodejs_eventloop_lag_seconds
```

---

## 2-8. (선택) NSG 포트 오픈

외부에서 vmui 접근이 필요한 경우:

```bash
az vm open-port \
  --resource-group rg-victoriametrics \
  --name vm-victoriametrics \
  --port 8428 \
  --priority 1010
```

> ⚠️ 프로덕션에서는 특정 IP만 허용하세요.

---

## 예상 결과

트래픽 생성 후 vmui에서 아래와 같은 그래프를 확인할 수 있습니다:

- `rate(http_requests_total[1m])` → 초당 요청 수 그래프
- `histogram_quantile(0.95, ...)` → 응답 시간 추이
- `process_resident_memory_bytes` → 메모리 사용량 변화

---

## 참고

- [VictoriaMetrics vmagent / scrape 문서](https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/#how-to-scrape-prometheus-exporters-such-as-node-exporter)
- [prom-client (Node.js)](https://github.com/siimon/prom-client)
- [octocat-supply 저장소](https://github.com/Azure-Samples/octocat-supply)

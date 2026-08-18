# Step 4: Grafana 대시보드 연동

VictoriaMetrics를 Grafana와 연동하여 시각화 대시보드를 구성합니다.
Grafana에서 VictoriaMetrics는 Prometheus 타입 데이터소스로 그대로 사용할 수 있습니다.

## 전체 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│  Azure VM (vm-victoriametrics)                               │
│                                                              │
│  ┌────────────────┐  scrape   ┌─────────────────────┐        │
│  │ octocat-supply │ ◀──────── │ VictoriaMetrics     │        │
│  │ :3000          │           │ :8428               │        │
│  └────────────────┘           └──────────┬──────────┘        │
│                                          │ query              │
│                                          ▼                    │
│                               ┌─────────────────────┐        │
│  ┌─ AKS port-forward ─┐      │ Grafana             │        │
│  │ VictoriaMetrics     │─────▶│ :3001               │        │
│  │ :9428               │      │                     │        │
│  └─────────────────────┘      └─────────────────────┘        │
│                                          │                    │
└──────────────────────────────────────────┼────────────────────┘
                                           │
                                           ▼
                               브라우저 (http://VM_IP:3001)
```

---

## 4-1. Grafana 설치

```bash
# GPG 키 및 저장소 등록
sudo apt-get install -y apt-transport-https software-properties-common
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# 설치 & 실행
sudo apt-get update
sudo apt-get install -y grafana
sudo systemctl enable --now grafana-server
```

### 포트 변경 (octocat-supply가 3000을 사용 중이므로)

```bash
# /etc/grafana/grafana.ini 수정
sudo sed -i 's/;http_port = 3000/http_port = 3001/' /etc/grafana/grafana.ini
sudo systemctl restart grafana-server

# 확인
curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/login
# 200
```

### NSG 포트 오픈

```bash
az network nsg rule create \
  --resource-group rg-victoriametrics \
  --nsg-name vm-victoriametricsNSG \
  --name AllowGrafana \
  --priority 1030 \
  --destination-port-ranges 3001 \
  --protocol Tcp \
  --access Allow \
  --direction Inbound \
  -o table
```

---

## 4-2. 데이터소스 연결

Grafana에서 VictoriaMetrics는 **Prometheus 타입** 데이터소스로 연결합니다.
별도의 플러그인이 필요 없습니다.

### Grafana API로 데이터소스 추가

```bash
# VM VictoriaMetrics (기본 데이터소스)
curl -X POST http://admin:admin@localhost:3001/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "VictoriaMetrics-VM",
    "type": "prometheus",
    "url": "http://localhost:8428",
    "access": "proxy",
    "isDefault": true
  }'

# AKS VictoriaMetrics (port-forward 9428)
curl -X POST http://admin:admin@localhost:3001/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "VictoriaMetrics-AKS",
    "type": "prometheus",
    "url": "http://localhost:9428",
    "access": "proxy",
    "isDefault": false
  }'
```

### GUI에서 추가하는 경우

1. Grafana 접속 → Connections → Data sources → Add data source
2. **Prometheus** 선택
3. URL에 `http://localhost:8428` 입력
4. **Save & Test** 클릭

> **핵심:** VictoriaMetrics는 Prometheus API를 100% 호환하므로 데이터소스 타입은 `Prometheus`를 선택합니다.

---

## 4-3. 대시보드 구성

12개 패널로 구성된 서비스 모니터링 대시보드를 만들었습니다.

### 패널 구성

| # | 패널명 | 타입 | 쿼리 | 검증 결과 |
|---|--------|------|------|-----------|
| 1 | **RPS** | TimeSeries | `sum by (path) (rate(http_requests_total{job="octocat-supply"}[1m]))` | /api/branches: 0.93 req/s ✅ |
| 2 | **HTTP Status 분포** | TimeSeries (stacked) | `sum by (status) (rate(http_requests_total{job="octocat-supply"}[1m]))` | 200: 6.63 req/s ✅ |
| 3 | **P95/P50 응답시간** | TimeSeries | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[1m])))` | P95 = 9.50 ms ✅ |
| 4 | **에러율 (5xx)** | Stat | `sum(rate(…{status=~"5.."}[5m])) / sum(rate(…[5m])) default 0` | 0.00% ✅ |
| 5 | **Uptime** | Stat | `up{job="octocat-supply"}` | UP (1) ✅ |
| 6 | **프로세스 메모리** | TimeSeries | `process_resident_memory_bytes` + `nodejs_heap_size_*` | RSS 97.2MB, Heap 18.6MB ✅ |
| 7 | **CPU 사용률** | TimeSeries | `rate(process_cpu_seconds_total[1m])` | 1.27% ✅ |
| 8 | **Event Loop Lag** | TimeSeries | `nodejs_eventloop_lag_seconds` + `_p99_seconds` | Mean 4.77ms ✅ |
| 9 | **GC Duration** | TimeSeries (stacked) | `rate(nodejs_gc_duration_seconds_sum[1m])` | minor 0.47ms/s ✅ |
| 10 | **Handles & FDs** | TimeSeries | `nodejs_active_handles_total` + `process_open_fds` | Handles 4, FDs 39 ✅ |
| 11 | **카디널리티** | Stat | `count({__name__!=""})` | 177 시계열 ✅ |
| 12 | **Scrape Duration** | TimeSeries | `scrape_duration_seconds{job="octocat-supply"}` | 4.00ms ✅ |

### 대시보드 레이아웃

```
┌─────────────────────────────┬─────────────────────────────┐
│  1. RPS (경로별)             │  2. HTTP Status 분포        │
│  TimeSeries                 │  TimeSeries (Stacked)       │
├─────────────────────────────┼──────────────┬──────────────┤
│  3. P95/P50 응답시간         │  4. 에러율    │  5. Uptime   │
│  TimeSeries                 │  Stat 0.00%  │  Stat UP     │
├─────────────────────────────┼──────────────┴──────────────┤
│  6. 프로세스 메모리 (RSS/Heap)│  7. CPU 사용률              │
│  TimeSeries                 │  TimeSeries                 │
├─────────────────────────────┼──────────────┬──────────────┤
│  8. Event Loop Lag          │  9. GC Duration              │
│  TimeSeries                 │  TimeSeries (Stacked)       │
├─────────────────────────────┼──────────────┼──────────────┤
│  10. Active Handles & FDs   │  11. 카디널리티│ 12. Scrape  │
│  TimeSeries                 │  Stat 177    │  TimeSeries  │
└─────────────────────────────┴──────────────┴──────────────┘
```

---

## 4-4. datasource 변수로 VM/AKS 전환

대시보드 상단의 `datasource` 변수로 VM ↔ AKS를 선택할 수 있습니다.

```
┌─────────────────────────────────────────────────────────┐
│ datasource: [VictoriaMetrics-VM ▾]                      │
│             [VictoriaMetrics-AKS]                        │
└─────────────────────────────────────────────────────────┘
```

- **VictoriaMetrics-VM**: `localhost:8428` → VM 바이너리 인스턴스
- **VictoriaMetrics-AKS**: `localhost:9428` → AKS port-forward

> 같은 대시보드로 양쪽 환경의 메트릭을 비교할 수 있습니다.

---

## 4-5. 접속 정보

| 항목 | 값 |
|------|-----|
| **Grafana URL** | `http://20.194.29.17:3001` |
| **초기 ID/PW** | `admin` / `admin` |
| **대시보드 직접 링크** | `http://20.194.29.17:3001/d/ahwsqq/octocat-supply-service-monitor` |
| **데이터소스 VM** | Prometheus 타입, `http://localhost:8428` |
| **데이터소스 AKS** | Prometheus 타입, `http://localhost:9428` |

---

## 4-6. Grafana를 systemd로 관리

Grafana는 설치 시 자동으로 systemd 서비스로 등록됩니다.

```bash
# 상태 확인
sudo systemctl status grafana-server

# 로그 확인
sudo journalctl -u grafana-server -f

# 재시작
sudo systemctl restart grafana-server

# 부팅 시 자동 시작 확인
sudo systemctl is-enabled grafana-server
```

### 설정 파일 위치

| 파일 | 경로 |
|------|------|
| 메인 설정 | `/etc/grafana/grafana.ini` |
| 데이터 | `/var/lib/grafana/` |
| 로그 | `/var/log/grafana/` |
| 플러그인 | `/var/lib/grafana/plugins/` |

---

## 4-7. 대시보드 JSON 백업 & 복원

### 내보내기

```bash
curl -s http://admin:admin@localhost:3001/api/dashboards/uid/ahwsqq \
  | python3 -m json.tool > dashboard-backup.json
```

### 가져오기

```bash
curl -X POST http://admin:admin@localhost:3001/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard-backup.json
```

---

## 트러블슈팅

### "No data" 표시될 때

1. 데이터소스 연결 확인: Data sources → Test
2. VictoriaMetrics가 실행 중인지 확인: `curl http://localhost:8428/api/v1/query?query=up`
3. job 이름이 맞는지 확인: `curl http://localhost:8428/api/v1/label/job/values`
4. 시간 범위 확인: 대시보드 우측 상단의 시간 범위를 "Last 1 hour"로 변경

### AKS 데이터소스가 안 될 때

AKS용 port-forward가 실행 중이어야 합니다:
```bash
kubectl port-forward -n vm svc/vmsingle-victoria-metrics-single-server 9428:8428 --address 0.0.0.0 &
```

### Grafana 포트 충돌

기본 포트 3000이 다른 앱과 충돌하면 `/etc/grafana/grafana.ini`에서 변경:
```ini
[server]
http_port = 3001
```

변경 후 `sudo systemctl restart grafana-server`

# VictoriaMetrics PoC

Azure 환경에서 VictoriaMetrics를 설치하고, 샘플 앱 트래픽을 수집하여 모니터링하는 PoC입니다.

## 구성

| Step | 내용 | 설명 |
|------|------|------|
| [Step 1](./step1/README.md) | 인프라 구성 & VM/AKS 설치 | Azure VM 바이너리 설치 + AKS Helm 설치 |
| [Step 2](./step2/README.md) | 샘플 앱 배포 & 메트릭 수집 | octocat-supply 앱 배포 → prom-client 계측 → vmui 쿼리 |
| [Step 3](./step3/README.md) | AKS 전체 구성 | ACR 이미지 빌드 → Helm 설치 → promscrape → 24h 부하 |
| [Step 4](./step4/README.md) | Grafana 대시보드 연동 | 데이터소스 연결 → 12패널 대시보드 → VM/AKS 전환 |
| [쿼리 가이드](./query-guide/README.md) | 실전 쿼리 & 개념 | MetricsQL vs PromQL, 카디널리티, 운영 알림 룰 |

## 아키텍처

```
┌──────────────────────────────────────────────────────────────┐
│  Azure VM (vm-victoriametrics)                               │
│                                                              │
│  ┌────────────────┐  scrape   ┌─────────────────────┐        │
│  │ octocat-supply │ ◀──────── │ VictoriaMetrics     │        │
│  │ :3000          │           │ :8428               │        │
│  │ + prom-client  │           └──────────┬──────────┘        │
│  └────────────────┘                      │ query              │
│                                          ▼                    │
│                               ┌─────────────────────┐        │
│  ┌─ AKS port-forward ─┐      │ Grafana             │        │
│  │ VictoriaMetrics     │─────▶│ :3001               │        │
│  │ :9428               │      └─────────────────────┘        │
│  └─────────────────────┘                                     │
└──────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  AKS (aks-victoriametrics)                      │
│                                                 │
│  octocat-supply (x2) ◀── VictoriaMetrics Helm   │
│  loadgen-24h              promscrape ConfigMap   │
└─────────────────────────────────────────────────┘
```

## 빠른 시작

```bash
# Step 1: 인프라 구성 → step1/README.md
# Step 2: 앱 배포 & 메트릭 수집 → step2/README.md
# Step 3: AKS 전체 구성 → step3/README.md
# Step 4: Grafana 대시보드 → step4/README.md
# 쿼리 가이드: 실전 쿼리 & 개념 → query-guide/README.md
```

## 접속 정보

| 서비스 | URL |
|--------|-----|
| vmui (VM) | `http://20.194.29.17:8428/vmui` |
| vmui (AKS) | `http://20.194.29.17:9428/vmui` |
| Grafana | `http://20.194.29.17:3001` (admin/admin) |
| 대시보드 | `http://20.194.29.17:3001/d/ahwsqq/octocat-supply-service-monitor` |

# VictoriaMetrics PoC

Azure 환경에서 VictoriaMetrics를 설치하고, 샘플 앱 트래픽을 수집하여 모니터링하는 PoC입니다.

## 구성

| Step | 내용 | 설명 |
|------|------|------|
| [Step 1](./step1/README.md) | 인프라 구성 & VM/AKS 설치 | Azure VM 바이너리 설치 + AKS Helm 설치 |
| [Step 2](./step2/README.md) | 샘플 앱 배포 & 메트릭 수집 | octocat-supply 앱 배포 → 트래픽 생성 → vmui 쿼리 |

## 아키텍처

```
┌─────────────────────────────────────────────────────┐
│  Azure VM (vm-victoriametrics)                      │
│                                                     │
│  ┌──────────────┐       ┌─────────────────────┐    │
│  │ octocat-     │:3000  │ VictoriaMetrics     │    │
│  │ supply API   │──────▶│ (scrape /metrics)   │    │
│  │ + prom-client│       │ :8428               │    │
│  └──────────────┘       └─────────────────────┘    │
│  ┌──────────────┐               │                  │
│  │ Frontend     │:5173          ▼                  │
│  └──────────────┘         vmui 대시보드            │
└─────────────────────────────────────────────────────┘
```

## 빠른 시작

```bash
# Step 1: 인프라 구성
# → step1/README.md 참고

# Step 2: 앱 배포 & 메트릭 수집
# → step2/README.md 참고
```

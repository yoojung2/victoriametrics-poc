# VictoriaMetrics PoC

Azure 환경에서 **VictoriaMetrics**를 설치하고, 실제 애플리케이션 메트릭을 수집·쿼리하는 단계별 PoC 저장소입니다.

## 단계별 가이드

| Step | 내용 | 문서 |
|------|------|------|
| **Step 1** | VictoriaMetrics 설치 (Azure VM 바이너리 + AKS Helm) | [docs/step1-install.md](docs/step1-install.md) |
| **Step 2** | 앱 계측(prom-client)으로 실제 앱 메트릭 수집 → vmagent → 쿼리 | [docs/step2-app-metrics.md](docs/step2-app-metrics.md) |
| **Step 3** | AKS에서 전체 파이프라인 재현 (앱 + vmagent + loadgen 24h 부하) | [docs/step3-aks-pipeline.md](docs/step3-aks-pipeline.md) |
| **쿼리 가이드** | VM·AKS 부하 기반 실전 운영 쿼리 (RED/USE, MetricsQL, 알람 예시) | [docs/query-guide.md](docs/query-guide.md) |
| **카디널리티** | 카디널리티 개념·폭발 원인·진단 쿼리 (실측 기반) | [docs/cardinality.md](docs/cardinality.md) |
| **확장/HA** | vmsingle vs vmcluster, scale-up/out·복제 판단 | [docs/scaling.md](docs/scaling.md) |

## 아키텍처

```
Step 1: VictoriaMetrics 설치
  ┌─ Azure VM (바이너리 + systemd) ── :8428 ─┐
  └─ AKS (Helm: victoria-metrics-single) ────┘

Step 2: 앱 메트릭 연동
  [octocat-supply API + prom-client] --/metrics--> [vmagent] --remote_write--> [VictoriaMetrics :8428]
          ↑ loadgen.sh 트래픽                        (scrape 10s)                  ↑ vmui 쿼리
```

## 디렉터리 구조

```
victoriametrics-poc/
├── README.md                        # (이 파일) 전체 개요
├── docs/
│   ├── step1-install.md             # Step 1: 설치 가이드
│   └── step2-app-metrics.md         # Step 2: 앱 메트릭 연동
├── scripts/
│   ├── install-vm-binary.sh         # VM 바이너리 설치 스크립트
│   └── loadgen.sh                   # 트래픽 생성기
├── systemd/
│   └── victoriametrics.service      # systemd 유닛 파일
└── step2/
    ├── app/
    │   ├── metrics-middleware.ts    # prom-client 계측 미들웨어
    │   └── index.ts.patch           # 앱 연결 diff
    └── vmagent/
        └── scrape.yml               # vmagent 스크레이프 설정
```

## 빠른 시작

1. **Step 1** — VictoriaMetrics를 VM(바이너리) 또는 AKS(Helm)에 설치 → [가이드](docs/step1-install.md)
2. **Step 2** — 샘플 앱에 계측을 붙여 실제 메트릭을 수집·쿼리 → [가이드](docs/step2-app-metrics.md)

## 검증 환경

- 구독: `ME-MngEnvMCAP663093-yoojunglee-2` / 리전: `koreacentral`
- VictoriaMetrics: `v1.150.0`

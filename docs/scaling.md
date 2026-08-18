# 확장(Scaling)과 HA — vmsingle vs vmcluster

> 📚 [← 전체 개요(README)](../README.md) · [쿼리 가이드](query-guide.md) · [카디널리티](cardinality.md)

본 PoC는 **vmsingle**(single-node)로 저장합니다. 부하가 커질 때 어떻게 확장되는지 정리합니다.

---

## 1. 핵심: vmsingle은 scale-out 불가

**vmsingle 인스턴스를 여러 대로 늘려 부하를 나누는 방식은 지원되지 않습니다.** 설계상 단일 노드입니다.

| | vmsingle (본 PoC) | vmcluster |
|---|---|---|
| 확장 | **수직(scale-up)** — CPU/RAM/디스크 증설 | **수평(scale-out)** — 노드 추가 |
| 데이터 분산 | ❌ 단일 노드 전량 저장 | ✅ vmstorage 샤딩 |
| 복제/HA | ❌ 단일 장애점 | ✅ `-replicationFactor` |
| 쓰기 확장 | 한 노드 한계까지 | vminsert 수평 확장 |

---

## 2. 부하가 커지면 벌어지는 일

1. **초기 — scale-up으로 버팀**
   vmsingle은 단일 바이너리로 수백만 active series까지 처리. VM 크기만 키우면(`B2s`→`D8s`…) 상당히 멀리 감. 대부분 서비스는 여기서 충분.
2. **한 노드 한계 도달 증상**
   - 디스크가 한 노드에 묶여 **용량 상한**
   - 고카디널리티 쿼리 **OOM** (→ [카디널리티 문서](cardinality.md))
   - 단일 노드라 재시작/장애 시 **수집·쿼리 중단**(HA 없음)
3. **해법 — vmsingle 여러 대(X), vmcluster 이전(O)**

---

## 3. vmcluster 구조 (scale-out)

```
[vmagent] --remote_write--> [vminsert] ──샤딩──> [vmstorage-0]
                            [vminsert]           [vmstorage-1]  ← 노드 추가 = 수평 확장
                                                 [vmstorage-2]
[vmui/Grafana] --query--> [vmselect] ──fan-out──> (모든 vmstorage)
```

| 컴포넌트 | 역할 | 확장성 |
|----------|------|--------|
| **vminsert** | 쓰기 라우팅, series 해시 샤딩 | stateless, 수평 |
| **vmstorage** | 실제 저장(샤드) | 노드 추가로 용량↑ |
| **vmselect** | 쿼리 fan-out/merge | stateless, 수평 |

- **HA:** `-replicationFactor=2` → series를 2개 vmstorage에 복제, 노드 1대 죽어도 무손실
- AKS라면 Helm `victoria-metrics-cluster` 또는 operator `VMCluster` CRD로 **vmstorage replica만 늘리면** 수평 확장

---

## 4. 언제 무엇을 선택하나

| 상황 | 선택 |
|------|------|
| 단일 서비스/PoC/중소 규모 | **vmsingle** (본 PoC) — 운영 단순, systemd 하나 |
| 한 노드 리소스로 부족 시작 | 먼저 **scale-up** (VM/파드 크기↑) |
| 용량·쓰기량이 한 노드 초과 | **vmcluster** 이전 |
| HA(무중단) 필요 | **vmcluster + replicationFactor≥2** |

> 요약: **vmsingle은 "키우기(up)"만 가능**, 진짜 "늘리기(out)"와 HA가 필요하면 vmcluster로 간다. 계측/쿼리/remote_write 인터페이스는 동일해서 **앱·vmagent 설정은 그대로 두고 저장 계층만 교체**하면 됩니다.

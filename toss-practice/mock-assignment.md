# 토스뱅크 DevOps 모의 과제 (2시간 / 4문항)

> 실제 과제 형식을 가정한 연습용입니다. 각 문항은 JD의 5단계 프레임
> **문제 정의 → 대안 도출 → 비교 검증 → 점진 적용 → 추가 개선** 으로 답하는 것을 권장합니다.
> 권장 배분: 문항당 25~30분. 먼저 **본인 답을 쓰고**, 그 다음 모범답안과 대조하세요.

---

## 문항 1. Kubernetes 트러블슈팅 (운영 장애 대응)

### 상황
배포 파이프라인을 통해 새 버전을 롤아웃했는데, 신규 Pod들이 `CrashLoopBackOff` 상태입니다.
`kubectl get pods` 결과:

```
NAME                          READY   STATUS             RESTARTS   AGE
payment-api-7d9f8c-abcde      0/1     CrashLoopBackOff   5          4m
payment-api-7d9f8c-fghij      0/1     CrashLoopBackOff   5          4m
payment-api-6c4b2a-klmno      1/1     Running            0          3h   # 구버전
```

기존(구버전) Pod는 정상이라 서비스는 아직 살아 있습니다.

**문제:** 원인을 어떻게 진단하고, 어떤 순서로 대응하겠습니까?

<details>
<summary>모범답안 / 평가 포인트</summary>

### 진단 절차 (말로 설명할 수 있어야 함)
1. **현상 격리** — 구버전 Pod가 Running이므로 *코드/이미지/설정의 신규 변경*이 원인일 가능성이 큼. 서비스는 구버전이 받쳐주므로 **긴급도는 중간** (장애가 아니라 롤아웃 실패).
2. `kubectl describe pod payment-api-7d9f8c-abcde`
   - `Events` 확인: ImagePull 실패? OOMKilled? Liveness probe 실패?
   - `Last State: Terminated, Reason: ...`, `Exit Code` 확인 (0 아닌 종료코드, 137=OOM, 1=앱 에러)
3. `kubectl logs payment-api-7d9f8c-abcde --previous`
   - 컨테이너가 재시작되므로 **`--previous`로 죽기 직전 로그**를 봐야 함. (이걸 아는 게 핵심)
4. 자주 나오는 원인 분기:
   - **앱 에러(Exit 1)**: 새 환경변수/ConfigMap 누락, DB 마이그레이션, 의존 서비스 연결 실패
   - **OOMKilled(137)**: 메모리 limit 부족 → `resources.limits.memory` 확인
   - **Liveness probe 실패**: 앱 기동 시간 > `initialDelaySeconds` → readiness/liveness 설정 점검
   - **설정 누락**: `kubectl get configmap/secret` 존재 여부, 키 이름 오타

### 대응 (점진 적용 + blast radius 최소화)
- 즉시: 신규 ReplicaSet은 실패 중이고 구버전이 트래픽을 받고 있으므로 **`kubectl rollout undo deployment/payment-api`로 롤백** → 안정 상태 확보 후 원인 분석.
- 근본 원인 수정 후 **카나리/소수 replica로 재배포**하여 검증.

### 추가 개선
- `maxUnavailable: 0`, `maxSurge: 1` 같은 롤링 전략으로 구버전 유지하며 점진 교체
- readiness probe로 트래픽 차단, PodDisruptionBudget으로 가용성 보장
- 배포 전 staging에서 동일 매니페스트 검증, CI에 헬스체크 게이트 추가

**평가 포인트:** `--previous` 로그를 아는가 / Exit code로 원인을 분기하는가 / "일단 롤백으로 안정화 후 분석" 이라는 운영 사고 / blast radius 언급
</details>

---

## 문항 2. Istio 트래픽 장애 (서비스 메시)

### 상황
Istio가 적용된 클러스터에서, 새로 배포한 `order-service`로 가는 요청이 간헐적으로
`503 UC (upstream connection termination)` 를 반환합니다.
- `order-service`는 정상 기동되어 있고 `kubectl logs`에는 에러가 없습니다.
- 같은 네임스페이스의 다른 서비스는 정상입니다.
- 클러스터는 `PeerAuthentication`으로 mTLS `STRICT` 모드입니다.

**문제:** 무엇을 의심하고, 어떤 순서로 원인을 좁혀가겠습니까?

<details>
<summary>모범답안 / 평가 포인트</summary>

### 의심 순서 (Istio 503은 패턴이 정해져 있음)
1. **사이드카 주입 여부** — `kubectl get pod <order> -o jsonpath='{.spec.containers[*].name}'`
   에 `istio-proxy`가 있는가? 없으면 mTLS STRICT 환경에서 **mesh 외부로 취급되어 503**.
   → 네임스페이스에 `istio-injection=enabled` 라벨 확인, Pod 재시작 필요.
2. **mTLS mismatch** — STRICT인데 클라이언트 또는 서버 한쪽만 사이드카가 있으면 평문 요청이 거부됨.
   `istioctl authn tls-check <pod>` 로 양쪽 TLS 기대값 확인.
3. **라우팅/서브셋 문제** — `DestinationRule`의 `subset`이 존재하지 않는 label을 가리키면 503.
   `istioctl proxy-config cluster/route <pod>` 로 실제 envoy 설정 확인.
4. **앱 레벨 connection 종료** — 503 **UC**는 upstream(=order-service)이 연결을 끊었다는 의미.
   - keep-alive timeout < Istio idle timeout → envoy가 죽은 커넥션 재사용 → 503
   - 이 경우 `DestinationRule`의 connection pool / `idleTimeout` 조정

### 진단 도구 (외워두면 좋음)
- `istioctl analyze` — 설정 정합성 자동 점검
- `istioctl proxy-config endpoints/cluster <pod>` — envoy가 보는 실제 endpoint
- envoy access log에서 `response_flags` 확인 (UC, UF, NR 등으로 원인 분기)

### 점진 적용 / 개선
- 의심 1순위(사이드카)부터 검증 → 가설 하나씩 제거
- 재발 방지: 네임스페이스 라벨 정책 강제(admission), `istioctl analyze`를 CI에 포함
- mTLS는 `STRICT`로 바로 가지 말고 `PERMISSIVE`로 마이그레이션 후 전환 (점진)

**평가 포인트:** 503의 envoy flag(UC/UF/NR) 의미를 아는가 / 사이드카·mTLS를 1순위로 의심하는가 / istioctl 도구를 아는가 / "STRICT 전환은 PERMISSIVE 경유" 라는 점진 운영 감각
</details>

---

## 문항 3. 빌드/배포 자동화 + 롤백 설계

### 상황
현재 팀은 새 이미지를 빌드한 뒤, 운영자가 수동으로 매니페스트의 이미지 태그를 바꾸고
`kubectl apply` 하는 방식으로 배포합니다. 배포가 하루 수십 건으로 늘면서:
- 휴먼 에러로 잘못된 태그 배포가 종종 발생
- 롤백 시 "직전에 뭐였는지" 추적이 어려움
- 누가 언제 무엇을 배포했는지 감사(audit)가 안 됨 (금융권 규제 이슈)

**문제:** 이 배포 프로세스를 어떻게 개선하겠습니까? 자동화 방안과 롤백/감사 전략을 포함해 설계하세요.

<details>
<summary>모범답안 / 평가 포인트</summary>

### 문제 정의
수동 배포 → 휴먼 에러, 추적성 부재, 감사 불가. 금융권은 **"변경 이력의 추적·승인·재현성"**이 규제 요구사항.

### 대안 도출 & 비교
| 방안 | 장점 | 단점 |
|------|------|------|
| CI에서 `kubectl apply` 자동화 | 도입 쉬움 | 클러스터 상태 = "마지막 apply", drift 추적 안 됨 |
| **GitOps (ArgoCD/Flux)** | Git이 single source of truth, 모든 변경=PR=감사로그, 롤백=git revert | 초기 학습/구축 비용 |
| Helm + CD 파이프라인 | 템플릿 재사용 | drift·감사는 별도 |

→ **GitOps 채택 권장.** 금융권 감사 요구사항과 가장 잘 맞음.

### 설계
1. **앱 코드 repo**와 **매니페스트(배포) repo** 분리.
2. CI: 빌드 → 이미지 푸시 → 매니페스트 repo에 **이미지 태그 자동 커밋(PR)**.
3. 운영 반영은 **PR 승인(리뷰어 2명 등)** 후 머지 → ArgoCD가 자동 동기화.
4. 이미지 태그는 `latest` 금지, **불변 태그(git SHA/버전)** 사용.

### 롤백 전략
- 롤백 = **이전 커밋으로 git revert** → ArgoCD가 자동으로 이전 상태 복원. "직전 상태"가 git 히스토리에 명확.
- 배포 방식은 **카나리/블루-그린**(Argo Rollouts)으로 자동 분석 + 자동 롤백 게이트.

### 감사/규제
- 모든 배포가 PR로 남음 = **누가/언제/무엇을/왜** 가 git log + 승인 기록으로 추적
- ArgoCD RBAC으로 환경별 배포 권한 분리(개발자는 dev, 운영 배포는 승인 필요)

### 점진 적용
- 한 번에 전체 전환 X → **신규/저위험 서비스부터** GitOps 적용 → 안정화 후 확대

**평가 포인트:** GitOps의 "Git=source of truth, 롤백=revert, 감사=PR" 핵심을 이해하는가 / 불변 태그 / 승인 워크플로우 / 점진 마이그레이션 / 금융 규제(추적성) 연결
</details>

---

## 문항 4. 모니터링 / 고가용성 (관측 가능성 + 안정성)

### 상황
운영 중인 `auth-service`가 새벽에 간헐적으로 응답이 느려진다는 제보가 들어옵니다.
- 현재 모니터링은 "Pod가 Running인지"만 보고 있어, 느려진 시점을 사후에 알 수 없습니다.
- `auth-service`는 replica 1개로 떠 있고, 노드 1대에 몰려 있습니다.

**문제:**
(a) 이 문제를 관측하기 위해 어떤 지표/알럿/대시보드를 설계하겠습니까?
(b) 이 서비스의 가용성을 높이기 위한 아키텍처 개선안은?

<details>
<summary>모범답안 / 평가 포인트</summary>

### (a) 관측 가능성 — RED/USE 방법론
- **RED (요청 단위 서비스 지표):** Rate(요청 수), Errors(에러율), Duration(레이턴시 분포)
  - 핵심은 **p50/p95/p99 레이턴시** — 평균이 아니라 분위수로 봐야 "간헐적 느림"이 잡힘
- **USE (리소스 지표):** Utilization, Saturation, Errors — CPU/메모리/디스크 I/O/네트워크
  - 새벽 느려짐 → CPU throttling(limit 도달), 메모리 압박, 노드 리소스 경합, GC, 배치 작업과 경합 의심
- **알럿:** p99 레이턴시 임계 초과 + 에러율 상승 시. 단순 임계값보다 **SLO 기반(error budget)** 권장.
- **대시보드:** Grafana에 RED 패널 + 노드 USE + Istio(있으면) request 메트릭 연동.
- 원인 추적엔 **분산 트레이싱**(Jaeger/Tempo)으로 어느 구간이 느린지 break down.

PromQL 예시(설명 가능해야):
```
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
rate(container_cpu_cfs_throttled_periods_total[5m])  # CPU throttling 탐지
```

### (b) 고가용성 개선
- **단일 replica → 다중 replica** (최소 2~3), HPA로 부하 기반 오토스케일
- **anti-affinity / topologySpreadConstraints** 로 여러 노드·존에 분산 (노드 1대 장애 = 전체 다운 방지)
- **PodDisruptionBudget** 으로 노드 드레인/업그레이드 시 최소 가용 replica 보장
- **readiness/liveness probe** 분리 — 느린 Pod를 트래픽에서 자동 제외
- 리소스 `requests/limits` 적정화로 CPU throttling 방지, QoS 보장
- (온프레미스 가정) 노드 풀을 가용 도메인 단위로 분산

### 점진 적용
- 먼저 관측부터 붙여 **근거 데이터 확보** → 원인 확인 후 아키텍처 변경 (추측 배포 X)

**평가 포인트:** p99/분위수의 중요성 / RED·USE 방법론 / CPU throttling 같은 구체적 원인 / SLO·error budget 개념 / replica·anti-affinity·PDB로 HA 설계 / "측정 먼저, 변경 나중" 순서
</details>

---

## 자기 평가 루브릭

각 문항을 풀고 스스로 체크:

- [ ] **문제 정의**가 명확한가 (현상/영향/긴급도)
- [ ] **대안을 2개 이상** 제시하고 trade-off를 비교했는가
- [ ] **진단 명령어/도구**를 구체적으로 알고 있는가 (외워서 나오는가)
- [ ] **롤백·blast radius·재발 방지** 같은 운영 사고가 드러나는가
- [ ] **점진 적용** 관점이 있는가 (한 번에 다 바꾸지 않기)
- [ ] **금융 규제/보안**(추적성, RBAC, 승인)을 의식했는가
- [ ] 모든 결정을 **면접에서 말로 설명**할 수 있는가

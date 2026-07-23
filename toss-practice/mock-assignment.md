# 토스뱅크 DevOps 모의 과제 (2시간 / 4문항)

> **이력서 맞춤 버전** — 각 문항은 본인이 실제로 겪은 경험에서 출발해서, 토스뱅크 환경(on-prem K8s + Istio + 금융 규제)으로 확장하는 구조입니다.
>
> AI를 참고하더라도 **"내가 왜 이 선택을 했는가"** 를 본인 언어로 설명할 수 있어야 합니다.
> 각 문항 끝의 **[자기 점검]** 항목이 바로 면접관의 꼬리질문입니다.
>
> 권장 배분: 문항당 25~30분. 모범답안은 본인 답 작성 후에 펼치세요.

---

## 문항 1. 커널 × K8s 연계 트러블슈팅

### 상황

토스뱅크 결제 서비스 Pod들이 특정 노드에서 **간헐적으로 TCP 연결이 끊기는** 현상이 보고됐습니다.
`kubectl get pods` 는 전부 Running이고, 애플리케이션 로그에는 단순 connection reset만 찍힙니다.
당신이 해당 노드에 접근해서 `dmesg | tail -20` 을 실행하자 아래가 보였습니다:

```
nf_conntrack: table full, dropping packet
nf_conntrack: table full, dropping packet
nf_conntrack: table full, dropping packet
```

이 노드에서 동작 중인 Pod 수는 평소보다 많지 않고, 트래픽도 특별히 급증하지 않았습니다.

**문제:**
(a) 이 현상의 근본 원인을 어떻게 특정하겠습니까? K8s 레이어와 커널 레이어 양쪽에서 확인할 것들을 서술하세요.
(b) 해결 방법과, K8s 환경에서 이 설정을 **영구적·일관성 있게** 적용하는 방법을 설계하세요.
(c) 같은 문제가 재발하지 않도록 어떤 모니터링을 추가하겠습니까?

<details>
<summary>모범답안 / 평가 포인트</summary>

### (a) 원인 특정

**커널 레이어 확인:**
```bash
# 현재 한계값과 사용량 확인
sysctl net.netfilter.nf_conntrack_max
sysctl net.netfilter.nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_count   # 현재 사용량

# conntrack 테이블 상세
cat /proc/net/nf_conntrack | wc -l              # 현재 항목 수
cat /proc/net/nf_conntrack | awk '{print $4}' | sort | uniq -c  # 상태별 분포
conntrack -L | grep TIME_WAIT | wc -l           # TIME_WAIT 누적 여부
```

**K8s 레이어 확인 — 왜 conntrack이 빨리 찼는가:**
- K8s에서는 kube-proxy(iptables 모드)가 모든 Service 트래픽을 NAT 처리 → **conntrack 항목 폭발적 생성**
- Pod 수 × Service 수 × 연결 수 = 예상보다 훨씬 많은 conntrack 항목
```bash
kubectl get nodes -o wide                     # 노드당 Pod 수
kubectl get pods -A -o wide | grep <노드명> | wc -l
kubectl get svc -A | wc -l                    # 서비스 수 (NAT 규칙 수)
```
- Istio 사이드카 + kube-proxy 이중 NAT: Istio 환경에서는 각 Pod의 사이드카가 추가 conntrack 항목을 만듦

**핵심 판단:** conntrack_max를 올리는 것과 timeout을 줄이는 것 중 무엇을 우선할지는 **TIME_WAIT 누적량**을 보고 결정. 타임아웃이 길어서 쌓이는 건지, 순수하게 max가 낮은 건지 구분해야 함.

### (b) 해결 및 K8s 영구 적용

단순 `sysctl -w`는 노드 재부팅 시 사라짐. K8s에서는 두 가지 방법:

**방법 1: DaemonSet으로 sysctl 배포 (권장)**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sysctl-tuner
  namespace: kube-system
spec:
  selector:
    matchLabels: { app: sysctl-tuner }
  template:
    metadata:
      labels: { app: sysctl-tuner }
    spec:
      hostNetwork: true
      hostPID: true
      initContainers:
      - name: sysctl
        image: busybox
        securityContext: { privileged: true }
        command:
        - sh
        - -c
        - |
          sysctl -w net.netfilter.nf_conntrack_max=1048576
          sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=300  # 기본 432000 → 5분으로
          sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
      containers:
      - name: pause
        image: gcr.io/google_containers/pause:3.1
```

**방법 2: kubelet의 allowedUnsafeSysctls / 노드 설정**
- `/etc/sysctl.d/99-conntrack.conf` 에 영구 설정 후 노드 이미지 포함 (IaC/Terraform으로 노드 프로비저닝 시 적용)

**설정값 근거 (단순 상향이 아니라 계산이 중요):**
```
nf_conntrack_max = 노드당 최대 Pod 수 × 서비스당 평균 연결 수 × 안전계수(1.5)
```

### (c) 모니터링
```
# node_exporter가 있으면 이미 메트릭 존재
node_nf_conntrack_entries          # 현재 사용량
node_nf_conntrack_entries_limit    # 한계값

# 알럿 (80% 도달 시 경고)
- alert: ConntrackUsageHigh
  expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
  for: 5m
```

**평가 포인트:**
- Docker WAS 경험에서 K8s 맥락으로 스스로 확장했는가
- "단순 상향" 이 아니라 timeout 단축으로 근본을 건드렸는가
- DaemonSet으로 **모든 노드에 일관성 있게** 적용하는 방법을 아는가
- 사후 모니터링까지 연결했는가

**[자기 점검 — 면접관이 물어볼 것]**
- "kube-proxy를 ipvs 모드로 바꾸면 이 문제가 해결되나요? 왜/왜 안 되나요?"
- "Istio 사이드카가 conntrack에 미치는 영향을 설명해보세요."
- "이 설정값(1048576)을 어떻게 계산했나요?"
</details>

---

## 문항 2. ArgoCD + HPA + Istio 카나리 삼자 설계

### 상황

당신은 이미 **ArgoCD의 Self-Heal이 HPA와 충돌**하여 무한 스케일다운이 발생하는 문제를
`ignoreDifferences`로 해결한 경험이 있습니다.

이제 토스뱅크에서 새로운 요구사항이 추가됐습니다:
- 결제 API의 신규 버전을 **카나리 방식(Istio VirtualService 가중치)**으로 점진 배포
- 카나리 가중치 변경(10% → 50% → 100%)도 **GitOps로 관리** (Git에 VirtualService 명세 포함)
- 동시에 HPA는 계속 동작해야 함

아래와 같은 충돌이 발생했습니다:
1. HPA가 스케일업 → ArgoCD가 replica 불일치 감지 → Self-Heal이 원복 (기존에 아는 문제)
2. **추가로**: 카나리 가중치를 Git에서 50%로 올렸더니, ArgoCD가 동기화 과정에서 현재 VirtualService를 잠깐 삭제했다가 재적용 → 그 순간 **트래픽이 전량 v1으로 몰림** (카나리 중단)

**문제:**
(a) 문제 2(카나리 중단)가 왜 발생하는지 설명하고, ArgoCD의 어떤 설정으로 방지할 수 있는지 서술하세요.
(b) ArgoCD + HPA + Istio 카나리를 **안전하게 함께 운영**하기 위한 설계를 제시하세요. 트레이드오프를 포함해서 서술하세요.
(c) 이 설계에서 **감사(audit) 로그**는 어떻게 남기겠습니까? (금융권 요구사항)

<details>
<summary>모범답안 / 평가 포인트</summary>

### (a) 카나리 중단 원인과 방지

**원인:** ArgoCD의 기본 sync 전략은 변경된 리소스를 `apply` 하지만, 일부 상황(리소스 삭제 후 재생성, `Prune` 옵션)에서는 삭제 후 재생성. VirtualService가 순간 없어지면 Istio가 기본 라운드로빈으로 fallback → v1/v2 가중치 없이 균등 분배 또는 전량 v1.

**방지:**
```yaml
# Application 레벨 sync policy
syncPolicy:
  syncOptions:
  - RespectIgnoreDifferences=true  # ignoreDifferences 적용 중 sync 시 무시
  - ApplyOutOfSyncOnly=true        # 변경된 리소스만 apply
  - ServerSideApply=true           # kubectl apply --server-side: 3-way merge로 충돌 방지
```

`ServerSideApply=true`가 핵심: 기존 apply는 "마지막으로 apply한 사람이 전체를 덮어씀" → 잠깐 삭제 가능성. 서버사이드 apply는 필드 단위 소유권 관리로 충돌을 merge.

### (b) 삼자 안전 운영 설계

```
Git repo 구조:
  apps/payment-api/
    deployment.yaml        # HPA 관리 대상 → replicas 필드는 ignoreDifferences
    hpa.yaml               # HPA 정의
    virtualservice.yaml    # 카나리 가중치 → 수동 PR로 점진 변경
    destinationrule.yaml

ArgoCD Application 설정:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers: [/spec/replicas]          # HPA 충돌 방지 (기존 해결책)
  - group: networking.istio.io
    kind: VirtualService
    jqPathExpressions: ['.spec.http[].route[].weight']  # 카나리 가중치도 예외? → 아니면 Argo Rollouts
```

**더 나은 대안: Argo Rollouts**
- VirtualService 가중치를 ArgoCD가 직접 관리하지 않고, **Argo Rollouts이 Rollout 오브젝트로 카나리 제어**
- Rollout → VirtualService 가중치 자동 조정 + 메트릭(Prometheus) 기반 자동 프로모션/롤백
- ArgoCD는 Rollout 오브젝트만 sync, 가중치 조정은 Rollouts에게 위임 → 충돌 없음

**트레이드오프:**
| 방식 | 장점 | 단점 |
|------|------|------|
| VirtualService를 Git에 직접 | 단순, 가중치가 Git에 명시 | sync 타이밍에 순단 가능, 수동 PR마다 배포 |
| Argo Rollouts | 자동 분석·롤백, 충돌 없음 | 추가 컴포넌트, 학습 비용 |
| ignoreDifferences로 weight 예외 | 즉시 적용 가능 | weight가 Git에서 벗어남 → GitOps 원칙 약화 |

### (c) 감사 로그 (금융권)

```
Git(Gitea) PR 히스토리 = 누가/언제/왜 가중치를 바꿨는지 → 코드 리뷰어 승인 포함
ArgoCD 이벤트 로그 → Application sync 이력 (Prometheus/Loki로 수집)
Kubernetes audit log → API 서버 레벨의 리소스 변경 기록
```
- PR 병합 = 배포 승인 기록. **2인 이상 approve** 정책 → 4-eyes 원칙 (금융 규제).
- ArgoCD RBAC: 운영자만 sync, 개발자는 PR까지만.

**평가 포인트:**
- `ignoreDifferences`를 이미 쓴 경험에서 **서버사이드 apply**로 한 단계 더 나아갔는가
- "Argo Rollouts" 대안을 알고 트레이드오프를 말할 수 있는가
- 감사 로그를 Git + ArgoCD + k8s audit 세 계층으로 연결했는가

**[자기 점검]**
- "ignoreDifferences로 weight를 예외 처리하면 GitOps의 어떤 원칙이 깨지나요?"
- "Argo Rollouts과 ArgoCD는 같은 팀이 만든 건데, 왜 충돌 없이 쓸 수 있나요?"
- "카나리 배포 중 롤백 기준을 어떻게 정하겠어요? 어떤 메트릭을 보나요?"
</details>

---

## 문항 3. 폐쇄망 온프레미스 배포 파이프라인 설계

### 상황

토스뱅크는 망분리 환경에서 운영됩니다. 현재 배포 방식:
- 개발자가 코드를 커밋 → CI 서버(인터넷 없음)에서 빌드 → 이미지를 내부 레지스트리에 푸시
- 운영자가 수동으로 `kubectl apply` 또는 ArgoCD Sync 버튼 수동 클릭
- 배포 기록은 메신저/이메일로만 남음

다음 요구사항을 모두 충족하는 **배포 파이프라인을 설계**하세요:
1. **GitOps 선언적 배포** (코드 커밋 → 자동 배포)
2. **컨테이너 이미지 취약점 스캔** (외부 인터넷 없이)
3. **금융감독원/KISA 감사 요건**: 배포 이력(누가/언제/무엇을), 2인 이상 승인, 롤백 이력
4. **이미지 무결성 검증** (내부 레지스트리에 올라온 이미지가 변조되지 않았는지)
5. **배포 실패 시 자동 롤백**

**문제:**
(a) 전체 파이프라인 아키텍처를 서술하세요 (컴포넌트와 데이터 흐름).
(b) 각 요구사항을 어떤 기술/도구로 구현했는지, 그리고 **왜 그것을 선택했는지** 설명하세요.
(c) 폐쇄망이라 외부 도구를 못 쓰는 상황에서 가장 어려운 제약은 무엇이고 어떻게 해결하겠습니까?

<details>
<summary>모범답안 / 평가 포인트</summary>

### (a) 파이프라인 아키텍처

```
[개발자]
  → git push → [Gitea (내부 Git)]
                    ↓ webhook
             [CI 서버 (Gitea Actions / Jenkins)]
                    ↓ 빌드 + 이미지 생성
             [Trivy (내부 취약점 스캔)]  ←── 취약점 DB는 정기적으로 Air-gap 업데이트
                    ↓ 스캔 통과 시만
             [내부 OCI 레지스트리 (Harbor)]
                    ↓ 이미지 서명 (Cosign + 내부 PKI)
             [매니페스트 repo (Gitea)]
                    ↓ PR 자동 생성 (이미지 태그 업데이트)
             [리뷰어 2인 승인]  ← 4-eyes 원칙
                    ↓ merge
             [ArgoCD (자동 sync)]
                    ↓
             [K8s 클러스터]
                    ↓ 배포 실패 감지
             [ArgoCD Rollouts / Argo CD automated rollback]
```

### (b) 기술 선택과 이유

| 요구사항 | 도구 | 선택 이유 |
|---------|------|---------|
| GitOps | **ArgoCD + Gitea** | 이미 검증된 폐쇄망 조합. Gitea는 Go 단일 바이너리라 설치/유지 단순. ArgoCD는 폴링 방식이라 Gitea webhook 없어도 동작 |
| 취약점 스캔 | **Trivy (오프라인 모드)** | 취약점 DB를 파일로 다운로드해서 내부 서버에 배포 가능. `trivy image --offline-scan`. Snyk/Prisma는 SaaS 의존 |
| 이미지 무결성 | **Cosign + Notation** | CNCF 표준. 내부 PKI(CA)로 서명 가능, 외부 Sigstore 없이 동작. Connaisseur나 Kyverno Admission Webhook으로 서명 없는 이미지 배포 차단 |
| 2인 승인 | **Gitea Branch Protection (required reviews ≥ 2)** | PR 없이는 머지 불가. 승인 기록이 Git 히스토리에 영구 보존 |
| 감사 로그 | Git 히스토리 + ArgoCD 이벤트 + K8s Audit log | 3계층: Git(누가/왜) + ArgoCD(언제/무엇을) + k8s audit(API 레벨) |
| 자동 롤백 | **Argo Rollouts** + ArgoCD 자동 동기화 | 메트릭 기반 게이트: 에러율 급증 시 자동 롤백. ArgoCD의 sync wave로 헬스체크 후 다음 단계 진행 |

### (c) 폐쇄망 최대 제약: 취약점 DB 업데이트

**문제:** Trivy는 취약점 DB(CVE)를 주기적으로 인터넷에서 받아야 함. 폐쇄망에서는 이 업데이트가 막힘.

**해결 방안:**
1. **DMZ 서버에서 주기적 다운로드** → 내부 네트워크로 단방향 전송 (자료 이관 프로세스)
2. **Trivy DB 파일을 내부 OCI 레지스트리에 저장**: `trivy image --db-repository harbor.internal/trivy-db` — Harbor가 DB 저장소 역할
3. **업데이트 주기 정의**: 금융 규제상 CVE DB는 최소 주 1회 업데이트 의무화(정책화)

→ 이 부분이 폐쇄망 운영의 핵심 운영 부담. "자동화" 못 하면 결국 사람이 하게 됨. CI에 "DB 최신성 검사" 게이트를 추가해서 DB가 7일 이상 오래됐으면 빌드 차단하도록 강제.

**평가 포인트:**
- 폐쇄망에서 Trivy 오프라인 모드, DB 업데이트 방법을 아는가
- Cosign/Notation으로 이미지 무결성을 K8s admission 레벨에서 강제하는가
- 감사 로그를 도구 하나로 때우지 않고 3계층 구조를 설계하는가
- "왜 이걸 선택했는가" 에 실제 사용 경험(Gitea, ArgoCD)이 연결되는가

**[자기 점검]**
- "Harbor를 못 쓰는 상황이면 이미지 레지스트리를 어떻게 운영하겠어요?"
- "이미지 서명 검증을 우회하는 방법이 있다면? 그걸 막으려면?"
- "배포 파이프라인 자체가 침해됐을 때 (CI 서버 해킹)를 어떻게 탐지하겠어요?"
</details>

---

## 문항 4. 컨테이너 메모리 누수 + 관측성 설계

### 상황

`auth-service` (Istio 사이드카 포함)가 배포 후 **정상 동작하다가 2~3일 뒤에 OOMKilled** 되는 패턴이 반복됩니다.
재기동하면 일시적으로 정상, 다시 메모리가 차오르는 누수 패턴입니다.

Grafana에서 확인한 컨테이너 메모리 그래프:

```
메모리 사용량(MB)
300 │                                    ╭─ OOMKilled
250 │                          ╭─────────╯
200 │              ╭───────────╯
150 │  ╭───────────╯
100 │──╯
    └─────────────────────────────────→ 시간(일)
      D+0       D+1       D+2       D+3
```

개발팀은 "애플리케이션 코드에 문제 없다"고 합니다.

**문제:**
(a) 애플리케이션 레이어 외에 **컨테이너/커널 레벨**에서 의심할 수 있는 원인을 나열하고 진단 방법을 서술하세요.
(b) Istio 사이드카(Envoy)가 메모리 누수의 원인일 수 있는 경우는 어떤 상황인가요?
(c) 이 패턴을 **사전에 탐지**하기 위한 PromQL 알럿과 대시보드를 설계하세요.
(d) OOM을 방지하기 위한 단기·장기 조치를 각각 제시하세요.

<details>
<summary>모범답안 / 평가 포인트</summary>

### (a) 앱 외 원인 진단

**컨테이너/커널 레벨 의심 원인:**

1. **커널 slab 메모리 누수** — 컨테이너 내부 메모리는 정상인데 호스트에서 slab이 증가
```bash
slabtop -s c        # 상위 slab 캐시 확인 (크기 기준 정렬)
cat /proc/slabinfo | sort -k3 -rn | head -20
# dentry/inode cache 폭증 → VFS 캐시 누수 (파일 시스템 집약 작업)
```

2. **tmpfs / emptyDir 누수** — 앱이 /tmp에 쓰고 안 지우면 컨테이너 메모리 한계 안에서 증가
```bash
kubectl -n default exec <pod> -- df -h   # /tmp 사용량
kubectl -n default exec <pod> -- ls -la /tmp
```

3. **Go/JVM 런타임 힙 증가** — 앱이 메모리를 요청하고 OS에 반환 안 하는 패턴
```bash
kubectl -n default exec <pod> -- cat /proc/<pid>/status | grep -i vmrss
kubectl -n default exec <pod> -- cat /sys/fs/cgroup/memory/memory.stat
# inactive_anon이 지속 증가하면 앱 힙이 GC 없이 쌓이는 것
```

4. **Transparent Huge Pages (THP)** — 단편화로 메모리 실효 용량 감소 (경험상)
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled  # always면 off 고려
```

**진단 순서:** 먼저 `memory.stat`의 `cache` vs `rss` 비율 → cache가 크면 VFS 누수 → `slabtop` → rss가 크면 앱 힙 → 앱 팀에 프로파일링 요청.

### (b) Envoy(Istio 사이드카) 메모리 누수 패턴

1. **xDS 설정 폭증**: 클러스터에 서비스가 많을수록 Envoy가 모든 서비스의 라우팅 정보를 메모리에 유지. `istioctl proxy-config cluster <pod> | wc -l` 로 cluster 수 확인.
   ```bash
   kubectl -n istio-system exec deploy/istiod -- curl -s localhost:15014/debug/endpointz | python3 -m json.tool | grep -c "clusterName"
   ```

2. **access log 버퍼**: Envoy access log를 stdout으로 대량 출력 시 버퍼 누적.

3. **통계(stats) 누수**: Envoy stats에 동적 태그가 너무 많으면 카디널리티 폭발 → 메모리 증가.

4. **Envoy 버전 버그**: 특정 Istio 버전의 알려진 메모리 누수. Istio release note 확인 필수.

진단:
```bash
kubectl -n default exec <pod> -c istio-proxy -- curl -s localhost:15000/stats/prometheus | grep "envoy_cluster_upstream_cx_active"
kubectl -n default exec <pod> -c istio-proxy -- curl -s localhost:15000/memory
```

### (c) 사전 탐지 PromQL

```promql
# 1. 메모리 증가 추세 탐지 (선형 회귀)
predict_linear(
  container_memory_working_set_bytes{container="auth-service"}[6h], 
  24*3600   # 24시간 뒤 예측값
) > 0.9 * <memory_limit>

# 2. OOM 이벤트 알럿
increase(kube_pod_container_status_restarts_total{container="auth-service"}[1h]) > 0
# + OOMKilled reason 확인
kube_pod_container_status_last_terminated_reason{reason="OOMKilled", container="auth-service"} == 1

# 3. Envoy 메모리 (사이드카)
container_memory_working_set_bytes{container="istio-proxy", pod=~"auth.*"}
```

**대시보드 패널 구성:**
- 앱 컨테이너 + istio-proxy 메모리를 **분리해서** 표시 (어느 쪽이 증가하는지)
- RSS vs cache 분리
- 24시간 예측선 표시 (predict_linear)
- 노드별 slab 메모리 (node_exporter)

### (d) 단기 / 장기 조치

**단기 (즉시):**
- memory limit 상향 (임시) + OOM 재시작 시 자동 알림
- `kubectl rollout restart` 스케줄 (cron 재기동) → 근본해결 아님, 임시방편

**장기 (근본):**
- Envoy 원인이면: Istio 업그레이드 or `--set values.pilot.enableProtocolSniffing=false` 등 튜닝
- 앱 원인이면: 언어별 메모리 프로파일러(pprof/async-profiler) + 코드 수정
- slab/VFS 원인이면: VFS 캐시 회수율 조정 (`vm.vfs_cache_pressure`) or tmpfs 마운트 정리
- 구조적으로: HPA로 메모리 기반 스케일아웃 + PDB로 가용성 확보 → OOMKilled가 나더라도 서비스 무중단

**평가 포인트:**
- 커널 slab 경험을 컨테이너 환경에 연결할 수 있는가
- Envoy 사이드카도 메모리 소비 주체임을 아는가 (컨테이너를 2개로 분리해서 보는가)
- predict_linear로 **사후가 아닌 사전** 탐지를 설계했는가
- 임시방편(재시작)과 근본 조치를 명확히 구분했는가

**[자기 점검]**
- "container_memory_working_set_bytes와 container_memory_usage_bytes의 차이는?"
- "Envoy xDS cluster 수를 줄이는 방법은? (Sidecar CRD)"
- "THP 비활성화를 K8s 환경에서 어떻게 적용하나요?"
</details>

---

## 자기 평가 루브릭

각 문항을 풀고 스스로 체크:

**공통 (모든 문항)**
- [ ] 문제 정의가 명확한가 (현상 / 영향 범위 / 긴급도)
- [ ] 대안을 2개 이상 제시하고 trade-off를 비교했는가
- [ ] **"왜 이 선택을 했는가"** 를 본인 언어로 설명할 수 있는가
- [ ] 점진 적용 / blast radius 최소화 관점이 있는가
- [ ] 재발 방지 / 모니터링을 연결했는가

**이력서 연계 체크**
- [ ] 문항 1: nf_conntrack 경험에서 K8s DaemonSet 적용까지 자연스럽게 확장했는가
- [ ] 문항 2: ignoreDifferences 경험에서 ServerSideApply / Argo Rollouts까지 나아갔는가
- [ ] 문항 3: Gitea + ArgoCD 조합에서 폐쇄망 취약점 DB 관리까지 설계했는가
- [ ] 문항 4: slab 메모리 경험을 Envoy 사이드카 진단과 연결했는가

**AI 활용 시 자기 점검**
- [ ] AI가 제시한 답을 그대로 썼는가 vs 본인 경험과 대조해서 "이건 맞다/이건 우리 환경에선 다르다"고 판단했는가
- [ ] [자기 점검] 꼬리질문에 즉시 답할 수 있는가 (여기서 AI 없이 막히면 위험)
- [ ] 본인이 실제로 해봤거나 근접하게 경험한 내용인지 → 면접에서 구체적 수치/상황을 물어봄

	# Argo Rollouts 최소 실습 시나리오 (K3s)

> **목표**: 면접에서 **"최근에 직접 띄워봤습니다"**라고 말할 수 있게 만드는 것.
> 도구를 마스터하는 게 아니라, **개념이 실물로 어떻게 동작하는지 눈으로 본 상태**를 만드는 것이 목적입니다.
>
> **소요 시간**: Lab 1~3은 2시간, Lab 4까지 3~4시간

---

## 실습 설계 의도

| Lab | 내용 | 면접에서 생기는 말 |
|---|---|---|
| 1 | 설치 + 기본 Canary | "Rollout 리소스로 단계별 배포를 직접 돌려봤습니다" |
| 2 | 수동 승격 · 중단 · 롤백 | "문제 감지 시 abort로 즉시 stable로 되돌아가는 걸 확인했습니다" |
| 3 | HPA와 함께 쓰기 | **기존 ArgoCD-HPA 충돌 경험과 직접 연결** |
| 4 ⭐ | **헤더 기반 라우팅 = 0단계 모드 재현** | **"블로그의 0단계 모드를 직접 재현해봤습니다"** ← 최고의 한 방 |

---

## 사전 준비

```bash
# K3s가 이미 있다면 생략
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

---

## Lab 1 — 설치와 첫 Canary (40분)

### 1-1. 컨트롤러 설치

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts get pods -w
```

### 1-2. kubectl 플러그인 설치 (필수 — 이게 있어야 관찰이 쉽습니다)

> ⚠️ **`exec format error`가 나면 아키텍처 불일치입니다.** OS/아키텍처를 자동 감지하는 아래 스크립트를 쓰세요.
> 이 플러그인은 **클라이언트 도구**라 K3s가 다른 서버에 있어도 로컬에 설치하면 됩니다(kubeconfig만 맞으면 됨).

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac

curl -fLO "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-${OS}-${ARCH}"
chmod +x "kubectl-argo-rollouts-${OS}-${ARCH}"
sudo mv -f "kubectl-argo-rollouts-${OS}-${ARCH}" /usr/local/bin/kubectl-argo-rollouts

kubectl argo rollouts version
```

**macOS라면 Homebrew가 더 간단합니다.**

```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

### 1-3. Rollout 리소스 만들기

> 💡 **핵심 개념**: `Rollout`은 **Deployment를 대체하는 CRD**입니다. Deployment의 `strategy` 자리에 단계별 배포 정의가 들어갑니다.
---
`rollout-demo.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: demo
spec:
  replicas: 5
  strategy:
    canary:
      steps:
        - setWeight: 20      # 카나리 20%
        - pause: {duration: 30s}
        - setWeight: 40
        - pause: {}          # 무기한 대기 → 사람이 promote 해야 진행
        - setWeight: 60
        - pause: {duration: 30s}
        - setWeight: 80
        - pause: {duration: 30s}
  revisionHistoryLimit: 2
  selector:
    matchLabels: {app: demo}
  template:
    metadata:
      labels: {app: demo}
    spec:
      containers:
        - name: demo
          image: argoproj/rollouts-demo:blue
          ports: [{containerPort: 8080}]
          resources:
            requests: {memory: 32Mi, cpu: 5m}
---
apiVersion: v1
kind: Service
metadata:
  name: demo
spec:
  selector: {app: demo}
  ports: [{port: 80, targetPort: 8080}]
```

```bash
kubectl apply -f rollout-demo.yaml
kubectl argo rollouts get rollout demo --watch
```

### 1-4. 새 버전 배포하고 단계 진행 관찰 ⭐

```bash
kubectl argo rollouts set image demo demo=argoproj/rollouts-demo:yellow
```

**`--watch` 창에서 반드시 확인할 것**

- `setWeight: 20`에서 **canary 파드가 1개(5개 중 20%)** 만 뜨는 것
- `pause: {}`에서 **진행이 멈추고 대기 상태**가 되는 것
- Stable ReplicaSet과 Canary ReplicaSet이 **동시에 공존**하는 것

> 🔎 **여기서 얻는 이해**: 트래픽 라우터(Istio 등)가 없으면 Argo Rollouts는 **파드 개수 비율로 카나리 비중을 근사**합니다. 진짜 트래픽 비율 제어는 라우터가 있어야 가능합니다. — **면접에서 이 차이를 말할 수 있으면 좋습니다.**

### 1-5. 승격

```bash
kubectl argo rollouts promote demo          # 다음 단계로
kubectl argo rollouts promote demo --full   # 남은 단계 전부 건너뛰고 완료
```

---

## Lab 2 — 중단과 롤백 (20분)

배포 도중 문제를 발견한 상황을 만들어봅니다.

```bash
# 새 배포 시작
kubectl argo rollouts set image demo demo=argoproj/rollouts-demo:red

# pause 중에 "문제 발견" → 중단
kubectl argo rollouts abort demo
kubectl argo rollouts get rollout demo --watch
```

**확인할 것**: canary 파드가 사라지고 **stable 버전으로 즉시 복귀**하는 것

```bash
# 이전 리비전으로 되돌리기
kubectl argo rollouts undo demo
kubectl argo rollouts undo demo --to-revision=2
```

> 💬 **면접에서 쓸 문장**: "abort하면 트래픽이 곧바로 stable로 돌아가고, canary ReplicaSet만 정리됩니다. 배포 히스토리가 리비전으로 남아 있어서 되돌리는 데 수십 초면 됩니다."
> → 페이타랩 블로그의 **"수십 초 안에 이전 버전으로 복구"**와 정확히 연결됩니다.

---

## Lab 3 — HPA × ArgoCD Self-Heal 충돌 재현 (60분) ⭐⭐ 이번 실습의 두 번째 하이라이트

> **목적**: 본인이 Deployment에서 겪었던 충돌이 **Rollout 리소스에서도 동일하게 재현되는지** 직접 확인하는 것.
> 이걸 해두면 면접에서 **"제가 겪은 문제가 이 환경에서는 어떻게 되는지 궁금해서 직접 붙여봤습니다"**라고 말할 수 있습니다. 경험이 학습으로 이어졌다는 가장 좋은 증거입니다.

### 3-0. 사전 준비 — 두 가지 함정

**① metrics-server 확인**

K3s는 metrics-server를 기본 포함합니다. 동작하는지만 확인하세요.

```bash
kubectl top pods
# error: Metrics API not available  → 아직 준비 중이거나 비활성. 1~2분 후 재시도
```

**② `cpu request` 값을 올려야 합니다** ⚠️

Lab 1의 Rollout은 `cpu: 5m`으로 되어 있는데, 이 값이면 **아이들 상태의 오버헤드만으로도 60%를 넘겨서** HPA가 즉시 maxReplicas까지 올라갑니다. 실험이 안 됩니다.

HPA의 Utilization은 **실사용량 ÷ request**로 계산되기 때문에, request가 작으면 사용률이 과장됩니다.

```bash
# rollout-demo.yaml 수정
#   resources:
#     requests: {memory: 32Mi, cpu: 50m}
kubectl apply -f rollout-demo.yaml
```

> 🔗 **면접에서 쓸 수 있는 디테일입니다.** "HPA가 Utilization을 request 기준으로 계산하기 때문에, request를 낮게 잡으면 사용률이 부풀려져서 불필요한 스케일아웃이 일어납니다." — 실습해본 사람만 아는 부분입니다.

### 3-1. HPA를 Rollout에 연결

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1   # ← Deployment가 아니라 Rollout
    kind: Rollout
    name: demo
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: 60}
```

```bash
kubectl apply -f hpa.yaml
kubectl get hpa demo -w
```

**❓ 왜 Deployment가 아닌 리소스를 HPA가 스케일할 수 있을까**

`Rollout` CRD가 **`/scale` 서브리소스를 구현**하기 때문입니다. HPA는 대상 리소스의 종류를 몰라도 되고, `scale` 서브리소스만 있으면 replicas를 읽고 쓸 수 있습니다.

> 🔑 **면접용 한 문장**: "HPA는 대상이 Deployment인지 Rollout인지 몰라도 됩니다. `scale` 서브리소스만 구현돼 있으면 스케일할 수 있는 구조라서, 커스텀 리소스도 HPA 대상이 될 수 있습니다."

**확인**

```bash
kubectl get hpa demo
# TARGETS가 <unknown>이면 metrics-server 또는 request 미설정 문제
```

### 3-2. 부하를 걸어 스케일아웃 관찰

```bash
# 부하 생성기
kubectl run load --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://demo/; done"

# 다른 창에서 관찰
watch kubectl get hpa,rollout,pods
```

replicas가 3에서 올라가는 것을 확인한 뒤 부하를 멈춥니다.

```bash
kubectl delete pod load
```

> 💡 **스케일인은 느립니다.** 기본 안정화 시간(`stabilizationWindowSeconds`)이 **5분**이라 바로 안 줄어듭니다. 이것도 실습으로만 체감되는 부분입니다 — 페이타랩이 "Autoscaler가 개입할 때는 이미 늦었다"고 한 이유와 같은 맥락입니다. **스케일 판단에는 항상 지연이 있습니다.**

### 3-3. ⭐ 충돌 재현 — 여기가 핵심

**ArgoCD 설치 (이미 있으면 생략)**

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**Rollout을 Git에 올리고 Application으로 등록**

이때 **매니페스트에 `replicas: 5`를 명시한 채로** 둡니다. 이게 충돌의 씨앗입니다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <본인 Git 저장소>
    path: manifests
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true        # ← 이걸 켜야 재현됩니다
```

**재현 절차**

1. 위 Application을 적용하고 Synced 상태 확인
2. 부하를 걸어 HPA가 replicas를 5 → 8로 올리게 만듦
3. **관찰**

```bash
kubectl argo rollouts get rollout demo --watch
kubectl get application demo -n argocd -w
```

**보이는 현상**

- HPA가 replicas를 8로 올림
- ArgoCD가 "Git에는 5인데 클러스터는 8" → **OutOfSync** 판정
- Self-Heal이 다시 5로 되돌림
- 부하는 그대로니 HPA가 또 8로 올림
- **무한 반복** — 파드가 계속 뜨고 죽습니다

> 🔑 **여기서 확인되는 사실**: 리소스가 Deployment든 Rollout이든 **문제의 구조는 완전히 같습니다.** 원인은 리소스 종류가 아니라 **"하나의 필드를 두 개의 컨트롤러가 서로 다른 근거로 관리한다"**는 데 있습니다.

### 3-4. 해결 — 소유권 나누기

```yaml
spec:
  ignoreDifferences:
    - group: argoproj.io          # ← Deployment는 apps
      kind: Rollout
      jsonPointers:
        - /spec/replicas
```

적용 후 다시 부하를 걸어보면 **HPA가 올린 값이 유지되고 Synced 상태도 정상**입니다.

**더 나은 방법 — 애초에 선언하지 않기**

```yaml
# Rollout 매니페스트에서 replicas 필드를 아예 제거
# HPA가 관리할 값을 Git에 적을 이유가 없음
```

이러면 `ignoreDifferences`도 필요 없습니다. **예외 처리보다 애초에 충돌 지점을 만들지 않는 쪽이 낫습니다.**

> 💬 **면접에서 이 순서로 말하면 좋습니다**
> "제가 당시엔 `ignoreDifferences`로 풀었는데, 다시 해보니 **매니페스트에서 replicas를 아예 빼는 게 더 깔끔**하더군요. HPA가 관리할 값을 Git에 적어두는 것 자체가 충돌의 원인이었습니다."
>
> → **같은 문제를 다시 보고 더 나은 답을 찾았다**는 서사가 됩니다. 성장했다는 증거로 읽힙니다.

### 3-5. 심화 — 카나리 진행 중에 HPA가 동작하면?

시간이 있으면 여기까지 해보세요. **역질문 소재가 나옵니다.**

부하를 건 상태에서 `set image`로 카나리 배포를 시작하고 관찰합니다.

```bash
kubectl argo rollouts set image demo demo=argoproj/rollouts-demo:green
watch kubectl get rs -l app=demo
```

**볼 것**

- HPA는 Rollout 전체의 `spec.replicas`를 조정합니다
- Rollout 컨트롤러는 그 값을 **stable과 canary에 단계 비율대로 배분**합니다
- 즉 두 컨트롤러가 **서로 다른 층위**에서 일합니다 — HPA는 총량, Rollout은 분배

**생각해볼 지점**

HPA는 파드 CPU 평균으로 판단하는데, 이 평균에는 **stable과 canary가 섞여 있습니다.** 만약 카나리 버전에 성능 회귀가 있어서 CPU를 더 먹으면, HPA는 그걸 "부하 증가"로 읽고 스케일아웃할 수 있습니다.

> 💬 **역질문으로 아주 좋습니다**
> "Canary 배포 중에는 HPA가 보는 CPU 평균에 신·구 버전이 섞이는데, 카나리 버전의 성능 회귀와 실제 부하 증가를 어떻게 구분하시나요?"
>
> **실습하지 않으면 나올 수 없는 질문**입니다.

### ✅ Lab 3에서 얻는 것

- [x] HPA가 커스텀 리소스를 스케일하는 원리 (`scale` 서브리소스)
- [x] `cpu request`가 HPA 판단에 미치는 영향
- [x] 스케일인 안정화 지연 (기본 5분)
- [x] **Self-Heal × HPA 충돌이 Rollout에서도 동일하게 재현됨을 직접 확인**
- [x] `ignoreDifferences`보다 **replicas를 아예 선언하지 않는 것**이 낫다는 결론
- [x] 카나리 중 HPA의 층위 분리와 그 한계

---

## Lab 4 ⭐ — 헤더 기반 라우팅 = 페이타랩 "0단계 모드" 재현

> **이 실습이 이번 준비의 하이라이트입니다.** 페이타랩이 만든 "0단계 모드"가 Argo Rollouts에서 어떤 기능으로 구현 가능한지 직접 확인하는 것입니다.

### 개념 매핑

| 페이타랩 "0단계 모드"         | Argo Rollouts 기능                  |
| --------------------- | --------------------------------- |
| 워크로드는 뜨지만 외부 트래픽 0%   | `setWeight: 0` + `setCanaryScale` |
| QA용 특수 헤더 요청만 canary로 | **`setHeaderRoute`**              |

`setHeaderRoute`는 지정한 헤더가 매칭되는 요청만 canary 서비스로 보내는 스텝입니다. **현재는 Istio 등 헤더 라우팅을 지원하는 트래픽 라우터와 함께 써야 동작합니다.**

### 4-1. Istio 설치 (K3s에 경량으로)

```bash
curl -L https://istio.io/downloadIstio | sh -
cd istio-*/bin && sudo mv istioctl /usr/local/bin/
istioctl install --set profile=minimal -y
kubectl label namespace default istio-injection=enabled
```

### 4-2. 0단계 모드 스텝 구성

```yaml
  strategy:
    canary:
      canaryService: demo-canary      # 별도 Service 필요
      stableService: demo-stable
      trafficRouting:
        istio:
          virtualService:
            name: demo-vsvc
            routes: [primary]
      steps:
        # === 0단계 모드 ===
        - setCanaryScale:
            replicas: 1               # 파드는 뜨되
        - setWeight: 0                # 외부 트래픽은 0%
        - setHeaderRoute:             # QA 헤더만 canary로
            name: qa-route
            match:
              - headerName: X-QA-Canary
                headerValue:
                  exact: "true"
        - pause: {}                   # 여기서 QA 수행
        # === 통상 Canary 진행 ===
        - setHeaderRoute: {name: qa-route}   # 헤더 라우팅 해제(빈 값)
        - setWeight: 20
        - pause: {duration: 1m}
        - setWeight: 50
        - pause: {duration: 1m}
```

### 4-3. 검증

```bash
# 일반 요청 → stable만 응답해야 함
curl http://<ingress>/color

# QA 헤더 요청 → canary가 응답해야 함
curl -H "X-QA-Canary: true" http://<ingress>/color
```

> 💬 **면접에서 쓸 문장** (가장 강력)
> "블로그에서 0단계 모드를 읽고 인상 깊어서, Argo Rollouts에서 어떻게 구현 가능한지 직접 확인해봤습니다. `setWeight: 0`으로 외부 트래픽을 차단하고 `setHeaderRoute`로 QA 헤더 요청만 흘려보내니 같은 동작이 나오더군요. 다만 페이타랩은 여기에 **Kafka 통신까지 라우팅 대상으로 만들기 위해 Gateway를 직접 제작**하셨다고 봤는데, 그 부분이 가장 어려운 지점이었을 것 같습니다."

**이 한 문장이 주는 신호**
1. 블로그를 제대로 읽었다
2. 읽고 끝내지 않고 손으로 확인했다
3. 그들이 추가로 해결한 어려움이 무엇인지 정확히 이해했다

---

## Lab 5 (선택) — AnalysisTemplate 맛보기 (30분)

자동 승격 판단의 핵심입니다. Prometheus 없이 개념만 볼 거면 `job` 기반으로도 가능합니다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      interval: 30s
      count: 3
      successCondition: result[0] >= 0.95
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{status!~"5.."}[2m]))
            /
            sum(rate(http_requests_total[2m]))
```

steps에 `- analysis: {templates: [{templateName: success-rate}]}`를 넣으면 **지표가 기준 미달일 때 자동으로 abort**됩니다.

> 💬 이걸 돌려봤다면 역질문이 날카로워집니다: **"Analysis는 어떤 지표를 기준으로 잡으셨나요? 3분 주문 취소 같은 비즈니스 지표도 승격 판단에 넣으시나요?"**

---

## ✅ 실습 후 정리해둘 것

- [ ] Rollout이 Deployment와 다른 점 한 문장
- [ ] 트래픽 라우터 유무에 따른 차이 (파드 비율 근사 vs 실제 트래픽 분배)
- [ ] abort / undo / promote 각각 언제 쓰는지
- [ ] HPA + Rollout 조합에서 관찰한 것
- [ ] 0단계 모드 재현 결과와, 페이타랩이 추가로 푼 문제(Kafka)

## ⚠️ 그래도 지킬 경계

실습 몇 시간으로 **운영 경험이 되지는 않습니다.** 면접에서는 이렇게 말하세요.

> "프로덕션 운영 경험은 아니고, 개념을 확인하려고 로컬 K3s에 직접 띄워본 수준입니다."

그다음에 관찰한 것을 말하면, **정직하면서도 준비된 사람**으로 읽힙니다.

---

## 참고

- [Argo Rollouts — Traffic Management](https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/)
- [Header-Based traffic routing using Argo Rollouts](https://www.infraspec.dev/blog/header-based-traffic-routing-using-argo-rollouts/)
- [페이타랩 — 0단계 모드가 나온 글](https://blog.paytalab.com/field-devops)

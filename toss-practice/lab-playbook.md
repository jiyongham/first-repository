# 토스뱅크 DevOps 실습 랩 플레이북

> 환경: kind `kind-toss-practice` (3노드) + Istio 1.30.1 + Prometheus/Grafana/Jaeger/Kiali
> 샘플 앱: Istio **bookinfo** (productpage → reviews(v1/v2/v3) → ratings, details) + sleep(디버그 클라이언트)
> `default` 네임스페이스는 `istio-injection=enabled` (사이드카 자동 주입).
>
> **사용법:** 각 실습은 ① 고장 주입 → ② 증상 확인 → ③ **스스로 진단(여기서 멈추고 직접 해보기)** → ④ 원인/정답 → ⑤ 복구. 타이머 켜고 진단 시간을 재보세요.

---

## 0. 접근 / 관측 도구 띄우기

kind는 LoadBalancer EXTERNAL-IP를 못 주므로(`<pending>`) port-forward로 접근합니다.

```bash
# 앱 외부 접근 (별도 터미널에서 각각 실행, 백그라운드 유지)
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80 &
# → http://localhost:8080/productpage

# 관측 대시보드
kubectl -n istio-system port-forward svc/kiali 20001:20001 &      # http://localhost:20001  (메시 토폴로지/트래픽)
kubectl -n istio-system port-forward svc/grafana 3000:3000 &      # http://localhost:3000   (RED 메트릭 대시보드)
kubectl -n istio-system port-forward svc/prometheus 9090:9090 &   # http://localhost:9090   (PromQL)
istioctl dashboard jaeger &                                       # 분산 트레이싱
```

부하 생성기 (실습 내내 켜두면 대시보드가 살아납니다):

```bash
# sleep Pod에서 productpage를 반복 호출
kubectl -n default exec deploy/sleep -c sleep -- \
  sh -c 'while true; do curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/productpage; sleep 0.3; done'
```

---

## 실습 1 — CrashLoopBackOff (문항 1: K8s 트러블슈팅)

### ① 고장 주입 — 메모리 limit을 비현실적으로 낮게
```bash
kubectl -n default set resources deploy/reviews-v2 --limits=memory=8Mi
```

### ② 증상 확인
```bash
kubectl -n default get pods -l app=reviews
# reviews-v2 가 CrashLoopBackOff / OOMKilled 로 빠짐
```

### ③ 스스로 진단 (여기서 멈추고 직접) ⏱
> 힌트: describe의 `Last State`, exit code, `logs --previous`

### ④ 정답
```bash
kubectl -n default describe pod -l version=v2 | grep -A5 "Last State"
#   Reason: OOMKilled, Exit Code: 137  ← 137 = OOM
kubectl -n default get pod -l version=v2 -o jsonpath='{..containers[*].resources}'
```
- **원인**: 컨테이너가 메모리 limit(8Mi)을 즉시 초과 → 커널이 kill(137) → 재시작 반복.
- 핵심 학습: `logs --previous`로 죽기 직전 로그 / exit 137 = OOM / describe의 Last State.

### ⑤ 복구
```bash
kubectl -n default set resources deploy/reviews-v2 --limits=memory=256Mi
# 또는
kubectl -n default rollout undo deploy/reviews-v2
```

> **변형 연습**: `kubectl -n default set image deploy/details-v1 details=docker.io/istio/examples-bookinfo-details-v1:NONEXISTENT`
> → `ImagePullBackOff`. describe의 Events에서 pull 실패 확인. 복구는 `rollout undo`.

---

## 실습 2 — Istio 503 (문항 2: 서비스 메시)

### 시나리오 A — DestinationRule subset이 없는 버전을 가리킴
```bash
# reviews 트래픽을 존재하지 않는 subset(v4)로 보냄
kubectl -n default apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts: [reviews]
  http:
  - route:
    - destination: { host: reviews, subset: v4 }   # v4는 DestinationRule에 없음
EOF
```

#### ② 증상
```bash
kubectl -n default exec deploy/sleep -c sleep -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/productpage
kubectl -n default exec deploy/sleep -c sleep -- \
  curl -s -w "\n%{http_code}\n" http://reviews:9080/reviews/1
# productpage 페이지에서 reviews 부분이 503
```

#### ③ 스스로 진단 ⏱
> 힌트: `istioctl proxy-config route`, `istioctl analyze`, envoy `response_flags`(NR=No Route)

#### ④ 정답
```bash
istioctl analyze -n default
#   → "subset not found" 류 경고
istioctl proxy-config cluster deploy/productpage -n default | grep reviews
#   → reviews|v4 cluster에 endpoint 없음
```
- **원인**: VirtualService가 가리키는 subset이 DestinationRule에 정의되지 않음 → envoy가 라우팅 대상 없음 → 503/NR.

#### ⑤ 복구
```bash
kubectl -n default delete virtualservice reviews
```

### 시나리오 B — mTLS STRICT + 사이드카 없는 클라이언트
```bash
# 1) default 네임스페이스에 mTLS STRICT 강제
kubectl -n default apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default }
spec: { mtls: { mode: STRICT } }
EOF

# 2) 사이드카 없는 클라이언트 생성 (주입 비활성)
kubectl -n default run nosidecar --image=curlimages/curl \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --restart=Never --command -- sleep 3600
sleep 5
```

#### ② 증상
```bash
kubectl -n default exec nosidecar -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/productpage
# 연결 실패 / 56 / 503  (평문 요청이 STRICT mTLS에 거부됨)
```

#### ③ 스스로 진단 ⏱
> 사이드카 없는 Pod는 평문으로 보내는데 서버는 STRICT(mTLS만 허용) → 거부.
> `kubectl get pod nosidecar -o jsonpath='{.spec.containers[*].name}'` 에 istio-proxy 없음 확인.

#### ④ 핵심 학습
- **503/연결거부 1순위 의심 = 사이드카 주입 여부 + mTLS 모드 mismatch.**
- 운영 교훈: STRICT는 한 번에 켜지 말고 **PERMISSIVE**(평문+mTLS 둘 다 허용)로 마이그레이션 후 전환.

#### ⑤ 복구
```bash
kubectl -n default delete pod nosidecar
kubectl -n default delete peerauthentication default
```

---

## 실습 3 — 카나리 배포 & 롤백 (문항 3: 빌드/배포)

bookinfo의 reviews v1(별점 없음)/v2(검정 별)/v3(빨강 별)로 트래픽 비중을 조절해봅니다.

### ① 안전한 기준선: 100% v1
```bash
kubectl -n default apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews }
spec:
  hosts: [reviews]
  http:
  - route:
    - { destination: { host: reviews, subset: v1 }, weight: 100 }
EOF
```

### ② 카나리: v3에 10%만
```bash
kubectl -n default apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews }
spec:
  hosts: [reviews]
  http:
  - route:
    - { destination: { host: reviews, subset: v1 }, weight: 90 }
    - { destination: { host: reviews, subset: v3 }, weight: 10 }
EOFk
```
→ Kiali 그래프에서 트래픽이 90/10으로 갈리는 것 확인. 부하 생성기를 켜두고 보세요.

### ③ 연습 과제
- v3 비중을 10 → 50 → 100으로 점진 증가시키며 Kiali/Grafana에서 에러율 관찰.
- **"롤백"**: 문제가 보이면 weight를 100% v1로 되돌리는 게 GitOps에서 `git revert`에 해당.
  실무에선 이 VirtualService가 git repo에 있고, 변경=PR=감사로그라는 점을 서술할 수 있어야 함.

### ⑤ 복구
```bash
kubectl -n default delete virtualservice reviews
```

---

## 실습 4 — 모니터링 / 고가용성 (문항 4)

### A. 레이턴시 주입 후 p99 관측 (관측 가능성)
```bash
# productpage→ratings 호출에 7초 지연을 50% 확률로 주입
kubectl -n default apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: ratings }
spec:
  hosts: [ratings]
  http:
  - fault:
      delay: { percentage: { value: 50 }, fixedDelay: 7s }
    route:
    - destination: { host: ratings, subset: v1 }
EOF
```
- 부하 생성기를 켜둔 채 **Grafana → Istio Service Dashboard**에서 productpage의 p50/p99 레이턴시가 벌어지는 것 확인.
- Prometheus(9090)에서 직접 PromQL:
```
histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{destination_service=~"productpage.*"}[1m])) by (le))
```
- 학습: **평균은 멀쩡한데 p99만 튀는** 전형적 "간헐적 느림". 평균이 아니라 분위수를 봐야 잡힌다.
- 복구: `kubectl -n default delete virtualservice ratings`

### B. 고가용성 (HA)
```bash
# 현재 단일 replica → 다중화
kubectl -n default scale deploy/productpage-v1 --replicas=3
kubectl -n default get pods -l app=productpage -o wide   # 노드 분산 확인

# 노드에 골고루 퍼지도록 topologySpread + PDB
kubectl -n default apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: productpage-pdb }
spec:
  minAvailable: 2
  selector: { matchLabels: { app: productpage } }
EOF
```
- 연습: replica가 worker / worker2에 분산됐는지 `-o wide`의 NODE 컬럼으로 확인.
- `kubectl drain toss-practice-worker --ignore-daemonsets --delete-emptydir-data` 시도 → PDB가 minAvailable=2를 지키며 드레인을 제어하는 것 관찰. (실습 후 `kubectl uncordon`)
- 서술 포인트: replica 다중화 + anti-affinity/topologySpread + PDB + readiness probe = HA의 기본 4종.

---

## 전체 초기화 (랩 리셋)

```bash
kubectl -n default delete virtualservice --all
kubectl -n default delete peerauthentication --all
kubectl -n default delete pdb --all
kubectl -n default delete pod nosidecar --ignore-not-found
kubectl -n default rollout undo deploy/reviews-v2 2>/dev/null
# bookinfo 자체를 다 지우려면:
# kubectl -n default delete -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/bookinfo/platform/kube/bookinfo.yaml
```

---

## 진단 명령어 치트시트 (손에 익히기)

```bash
# K8s
kubectl describe pod <pod>                 # Events / Last State / Exit code
kubectl logs <pod> -c <ctr> --previous     # 죽기 직전 로그
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl top pod -n <ns>                     # (metrics-server 필요)

# Istio
istioctl analyze -n <ns>                    # 설정 정합성
istioctl proxy-config route|cluster|endpoint <pod>   # envoy 실제 설정
istioctl proxy-status                       # 사이드카 동기화 상태
istioctl authn tls-check <pod>              # mTLS 기대값 (구버전), 또는 proxy-config 로 확인
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}'  # istio-proxy 주입 여부
```

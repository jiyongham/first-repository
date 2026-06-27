# ArgoCD + GitHub Actions 실습 플레이북

> 환경: kind `kind-toss-practice` (3노드) + ArgoCD
> 레포: `github.com/jiyongham/first-repository`
> 샘플 앱: Go HTTP 서버 (`sample-app/`) — `/`, `/health` 엔드포인트
>
> **전체 플로우:**
> `코드 수정 → git push (main)` → GitHub Actions (테스트 → 이미지 빌드 → GHCR 푸시 → 매니페스트 태그 업데이트) → ArgoCD (변경 감지 → 자동 Sync) → kind 클러스터에 배포
>
> **사용법:** 각 단계는 ① 설정/실행 → ② 확인 → ③ **스스로 해보기** → ④ 다음 단계 순으로 진행합니다.

---

## 레포 파일 구조

```
workplace/
├── sample-app/          ← 앱 소스 (main.go, Dockerfile)
├── k8s/                 ← ArgoCD가 감시하는 매니페스트 (deployment.yaml, service.yaml)
├── argocd/              ← ArgoCD Application CRD
└── .github/workflows/
    └── ci-cd.yaml       ← CI(테스트) + CD(빌드/푸시/매니페스트 업데이트)
```

---

## 0. 사전 준비

### kind 클러스터 확인

```bash
kubectl cluster-info --context kind-toss-practice
kubectl get nodes
# control-plane, worker, worker2 — 3노드 Ready 확인
```

### GHCR 패키지 공개 설정 (최초 1회)

첫 이미지 푸시 후 GitHub에서:
1. `github.com/jiyongham` → **Packages** → `sample-app`
2. **Package settings** → **Change visibility** → **Public**

> kind 클러스터는 `imagePullSecrets` 없이 public 이미지만 바로 pull 가능합니다.
> private으로 유지하려면 아래 시크릿을 먼저 생성하세요:
> ```bash
> kubectl create secret docker-registry ghcr-credentials \
>   --docker-server=ghcr.io \
>   --docker-username=jiyongham \
>   --docker-password=<GITHUB_PAT> \
>   -n default
> ```
> 그 후 `k8s/deployment.yaml`의 `imagePullSecrets` 주석을 해제합니다.

---

## 실습 1 — ArgoCD 설치 및 UI 접근

### ① ArgoCD 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod가 모두 Running 될 때까지 대기 (1~2분 소요)
kubectl -n argocd get pods -w
# argocd-server, argocd-repo-server, argocd-application-controller 등 Running 확인
```

### ② UI 접근 및 로그인

```bash
# 별도 터미널에서 port-forward 유지
kubectl port-forward svc/argocd-server -n argocd 8081:443 &

# 초기 admin 패스워드 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

브라우저에서 `https://localhost:8081` 접속 → `admin` / 위에서 출력된 패스워드로 로그인.

> TLS 인증서 경고는 "고급 → 진행"으로 무시합니다 (자체 서명 인증서).

### ③ CLI 로그인 (선택)

```bash
argocd login localhost:8081 \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d) \
  --insecure
```

---

## 실습 2 — ArgoCD Application 등록

### ① Application 생성

```bash
kubectl apply -f argocd/application.yaml
```

`argocd/application.yaml` 핵심 내용:
```yaml
source:
  repoURL: https://github.com/jiyongham/first-repository.git
  targetRevision: main
  path: k8s                  # k8s/ 디렉토리를 감시
destination:
  namespace: default
syncPolicy:
  automated:
    prune: true              # git에서 삭제된 리소스는 클러스터에서도 삭제
    selfHeal: true           # 클러스터 상태가 git과 달라지면 자동 복구
```

### ② 최초 Sync 확인

```bash
# ArgoCD CLI
argocd app get sample-app

# kubectl
kubectl -n argocd get application sample-app
# STATUS: Synced / HEALTH: Healthy 확인 (1~2분 소요)
```

UI에서: **Applications → sample-app** 클릭 → 리소스 트리 (Deployment, Service, Pod) 확인.

### ③ 배포된 앱 확인

```bash
kubectl get pods -l app=sample-app
# sample-app-xxx-yyy 2개 Running 확인

kubectl port-forward svc/sample-app 8082:80 &
curl http://localhost:8082/
# Hello from sample-app! version: dev
```

> `version: dev`는 Dockerfile의 기본값입니다. CI를 타면 git SHA로 교체됩니다.

---

## 실습 3 — GitHub Actions CI/CD 파이프라인 실행

### ① 코드 수정 후 push

```bash
# sample-app/main.go 수정 — 응답 메시지 변경
# 예: "Hello from sample-app!" → "Hello from sample-app v2!"

git add sample-app/main.go
git commit -m "feat: update greeting message"
git push origin main
```

> `paths: ['sample-app/**']` 조건이 있으므로 `sample-app/` 이하를 수정해야 워크플로우가 트리거됩니다.

### ② GitHub Actions 진행 확인

`github.com/jiyongham/first-repository/actions` 에서 실시간 확인.

워크플로우 2-job 구조:
```
[ci job]                          [push job]
  ① go test ./...        →통과→    ③ docker build + push (GHCR)
  ② SHORT_SHA 추출                 ④ k8s/deployment.yaml image 태그 업데이트
                                   ⑤ git commit & push (bot 커밋)
```

### ③ 스스로 확인해보기 ⏱

- Actions 탭에서 각 step 로그 확인
- `k8s/deployment.yaml`의 image 태그가 `ghcr.io/jiyongham/sample-app:<SHA>`로 바뀌었는지 GitHub에서 확인
- ArgoCD UI에서 sync 상태가 **OutOfSync → Syncing → Synced** 로 바뀌는 과정 관찰

### ④ ArgoCD 자동 Sync 확인

```bash
# ArgoCD가 감지하고 자동 배포 (기본 polling 3분 간격, webhook 설정 시 즉시)
kubectl -n argocd get application sample-app -w
# SYNC STATUS: Synced, HEALTH STATUS: Healthy

# 새 Pod로 교체됐는지 확인 (롤링 업데이트)
kubectl get pods -l app=sample-app
kubectl rollout status deploy/sample-app
```

### ⑤ 새 버전 앱 확인

```bash
curl http://localhost:8082/
# Hello from sample-app v2! version: <SHORT_SHA>
```

---

## 실습 4 — GitOps 롤백

ArgoCD에서 롤백 = git history를 되돌리는 것입니다.

### 방법 A: git revert (권장, 감사 로그 보존)

```bash
# 직전 커밋(이미지 태그 업데이트 bot 커밋) revert
git revert HEAD --no-edit
git push origin main
# → ArgoCD가 이전 태그로 자동 재배포
```

### 방법 B: ArgoCD UI에서 이전 히스토리로 롤백

UI → **sample-app** → **History and Rollback** → 원하는 revision 선택 → **Rollback**

> 단, `syncPolicy.automated.selfHeal: true`가 켜져 있으면 ArgoCD가 곧 다시 git 최신 상태로 덮어씁니다.
> UI 롤백 후 유지하려면 자동 Sync를 임시로 끄거나 git 자체를 revert 해야 합니다.

### ③ 스스로 해보기 ⏱

- `git revert` 후 Actions 탭에서 워크플로우가 **트리거되지 않는 것** 확인
  (revert 커밋은 `sample-app/**` 경로를 건드리지 않으므로 CI 스킵)
- ArgoCD만 이전 이미지 태그를 감지해 배포하는 것 확인

---

## 실습 5 — selfHeal 실습 (ArgoCD 핵심 개념)

### ① 클러스터 상태를 강제로 git과 다르게 만들기

```bash
# kubectl로 직접 replica 수 변경
kubectl scale deploy/sample-app --replicas=5
kubectl get pods -l app=sample-app
# 5개 Running
```

### ② ArgoCD가 복구하는 것 확인 ⏱ (~1분 이내)

```bash
kubectl get pods -l app=sample-app -w
# 자동으로 2개로 줄어드는 것 관찰 (k8s/deployment.yaml의 replicas: 2로 복구)
```

ArgoCD UI: **OutOfSync → Syncing → Synced** 사이클 관찰.

> **핵심 학습**: `selfHeal: true`는 클러스터에 직접 kubectl로 변경해도 git 상태로 자동 복구합니다.
> 운영에서 "hotfix를 kubectl로 적용했는데 몇 분 뒤 사라짐" 현상의 원인이 바로 이것입니다.
> GitOps에서는 **모든 변경은 반드시 git을 통해** 해야 합니다.

---

## ArgoCD Sync 주기 단축 (Webhook 설정, 선택)

기본 polling 간격은 3분입니다. GitHub Webhook을 설정하면 push 즉시 Sync됩니다.

```bash
# ArgoCD Server 외부 접근 URL 필요 (ngrok 등으로 임시 터널)
# 예: ngrok http 8081
# GitHub 레포 → Settings → Webhooks → Add webhook
# Payload URL: https://<ngrok-url>/api/webhook
# Content type: application/json
# Events: Just the push event
```

> kind 로컬 환경에서는 ngrok 없이도 3분 polling으로 충분합니다.

---

## 진단 명령어 치트시트

```bash
# ArgoCD
argocd app get sample-app                    # 앱 상태 요약
argocd app history sample-app                # 배포 히스토리
argocd app diff sample-app                   # git vs 클러스터 diff
argocd app sync sample-app                   # 수동 Sync 강제 실행
argocd app rollback sample-app <revision>    # 특정 revision으로 롤백

# kubectl
kubectl -n argocd get application sample-app -o yaml   # 전체 Application 상태
kubectl rollout status deploy/sample-app               # 배포 진행 상황
kubectl rollout history deploy/sample-app              # 배포 히스토리
kubectl describe deploy/sample-app | grep Image        # 현재 이미지 태그 확인

# GitHub CLI (Actions 로그)
gh run list --repo jiyongham/first-repository          # 최근 Actions 실행 목록
gh run watch --repo jiyongham/first-repository         # 현재 실행 중인 run 실시간 추적
gh run view <run-id> --log                             # 특정 run 로그 출력
```

---

## 전체 초기화

```bash
# ArgoCD Application 삭제 (cascade: 클러스터 리소스도 함께 삭제)
kubectl delete -f argocd/application.yaml

# ArgoCD 자체 삭제
kubectl delete namespace argocd

# 배포된 앱 삭제 (cascade 삭제 안 했을 경우)
kubectl delete deploy/sample-app svc/sample-app -n default

# port-forward 종료
pkill -f "port-forward"
```

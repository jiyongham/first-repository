# GoCD 실습 플레이북

> 환경: Docker Compose (로컬) + kind `kind-toss-practice`
> 레포: `github.com/jiyongham/first-repository`
> 샘플 앱: Go HTTP 서버 (`sample-app/`)
>
> **전체 플로우:**
> `코드 수정 → git push (main)` → GoCD (테스트 → 이미지 빌드 → GHCR 푸시 → 매니페스트 업데이트) → ArgoCD (자동 Sync) → kind 클러스터 배포

---

## GoCD vs GitHub Actions — 핵심 차이

| 항목 | GitHub Actions | GoCD |
|------|---------------|------|
| 실행 위치 | GitHub 호스팅 러너 | 자체 Agent (서버 직접 관리) |
| 파이프라인 단위 | workflow → job → step | pipeline → stage → job → task |
| 의존성 | job-level (`needs:`) | stage-level (순차 강제) |
| 시각화 | 선형 로그 | 파이프라인 DAG 그래프 |
| 트리거 | 이벤트 기반 (webhook) | Material polling + webhook |
| 아티팩트 전달 | `actions/upload-artifact` | 내장 artifact 시스템 |
| 시크릿 | GitHub Secrets | 보안 환경변수 / Secret Config |
| 롤백 | 없음 (수동 revert) | UI에서 이전 빌드로 즉시 재실행 |

**GoCD의 핵심 철학:** GoCD는 **CD(Continuous Delivery)**에 특화된 툴입니다.
파이프라인이 자체 서버에서 실행되므로 복잡한 배포 워크플로우, 환경별 승인 게이트, 파이프라인 간 의존성을 세밀하게 제어할 수 있습니다.

---

## 파일 구조

```
workplace/
├── .gocd/
│   └── sample-app.gocd.yaml    ← GoCD 파이프라인 정의 (Pipeline as Code)
├── gocd/
│   ├── docker-compose.yaml     ← GoCD 서버 + 에이전트
│   ├── server/Dockerfile       ← YAML Config Plugin 내장 서버 이미지
│   ├── agent/Dockerfile        ← Go + Docker CLI 포함 에이전트 이미지
│   ├── setup.sh                ← 초기 설정 자동화 스크립트
│   └── playbook.md             ← 이 파일
├── sample-app/                 ← Go 앱 소스
├── k8s/                        ← ArgoCD가 감시하는 K8s 매니페스트
└── argocd/                     ← ArgoCD Application CRD
```

---

## GoCD 핵심 개념

```
Pipeline          : 전체 배포 워크플로우 단위
  └─ Stage        : 순차 실행 단계 (이전 Stage 실패 시 중단)
       └─ Job     : Stage 내 병렬 실행 가능한 작업 단위
            └─ Task : 실제 실행 명령어

Material          : 파이프라인 트리거 소스 (git, 다른 pipeline 등)
Agent             : 실제 Job을 실행하는 워커 (Resource 태그로 매칭)
Artifact          : Stage 간 파일 전달 메커니즘
```

이번 파이프라인 구조:
```
[Material: git push to main → sample-app/** 변경 감지]
         ↓
  [Stage 1: test]
    Job: unit-test (resource: go)
      → go test -v ./...
         ↓ (성공 시 자동 진행)
  [Stage 2: build-and-push]
    Job: docker (resource: docker)
      → docker build + push to GHCR
         ↓ (성공 시 자동 진행)
  [Stage 3: update-manifest]
    Job: git-push (resource: go)
      → sed k8s/deployment.yaml + git push
         ↓
  [ArgoCD가 변경 감지 → kind 클러스터 배포]
```

---

## 사전 준비

### Docker Desktop 시작
GoCD는 Docker Compose로 실행됩니다. Docker Desktop이 실행 중이어야 합니다.

```bash
# Docker 상태 확인
docker info | head -5
```

---

## 실습 1 — 환경 시작

### ① 이미지 빌드 및 컨테이너 시작

```bash
cd workplace/gocd
docker compose build          # 서버(YAML 플러그인 포함) + 에이전트 이미지 빌드
docker compose up -d          # 백그라운드 실행
docker compose logs -f        # 로그 실시간 확인 (Ctrl+C로 빠져나오기)
```

서버 기동까지 약 1~2분 소요됩니다.

### ② GoCD UI 접속 및 초기 설정

브라우저에서 `http://localhost:8153` 접속.

**최초 접속 시 설정 마법사 진행:**
1. **Admin Password** 설정 (기억하기 쉬운 값으로)
2. 설정 완료 후 로그인

### ③ 설정 스크립트 실행

```bash
cd workplace/gocd
./setup.sh <설정한_admin_패스워드>
# 예: ./setup.sh my-gocd-pass
```

스크립트가 자동으로:
- Agent Auto-Register Key 설정 (에이전트 자동 등록 허용)
- Config Repository 등록 (`.gocd/` 디렉토리 → 파이프라인 자동 로드)

---

## 실습 2 — 에이전트 및 파이프라인 확인

### ① Agent 활성화 확인

```bash
# 에이전트 로그 확인
docker compose logs gocd-agent | tail -20
```

UI에서: **Agents** 메뉴 → `local-agent-01` 상태가 **Idle** 인지 확인.
- `Building`: 파이프라인 실행 중
- `Idle`: 대기 중 (정상)
- `Lost Contact` / `Missing`: 네트워크 문제

### ② 파이프라인 로드 확인

UI: **Admin → Config Repositories** → `first-repository` 항목에 녹색 체크 확인.

이후 **Pipelines** 메뉴에 `sample-app` 파이프라인이 자동으로 나타납니다.

### ③ GITHUB_TOKEN 보안 환경변수 설정

> **중요:** 이 단계를 건너뛰면 Stage 2 (Docker Push)와 Stage 3 (Git Push)가 실패합니다.

1. UI: **Admin → Pipelines → sample-app**
2. 좌측 메뉴 **Environment Variables** 클릭
3. **Add** → **Secure Variable** 선택
4. Name: `GITHUB_TOKEN`, Value: GitHub PAT (권한: `packages:write`, `contents:write`)
5. **Save** 클릭

**GitHub PAT 발급 방법:**
`github.com → Settings → Developer settings → Personal access tokens → Tokens (classic)`
- `write:packages` (GHCR 이미지 푸시)
- `contents:write` (k8s/deployment.yaml 커밋 푸시)

---

## 실습 3 — 파이프라인 실행

### ① 코드 수정 후 push

```bash
# sample-app/main.go 수정 — 응답 메시지 변경
# "Hello from sample-app v2!" → "Hello from sample-app v3!"

git add sample-app/main.go
git commit -m "feat: update greeting for gocd practice"
git push origin main
```

### ② GoCD 파이프라인 실시간 관찰

UI에서 `sample-app` 파이프라인 클릭:
- 각 Stage (test → build-and-push → update-manifest) 진행 상황 확인
- Stage 클릭 → Job 클릭 → 콘솔 로그 실시간 확인

```
[test]          ■■■■■■■■■■ ✓  (go test 통과)
[build-and-push] ■■■■■■■■■■ ✓  (docker build + ghcr push)
[update-manifest] ■■■■■■■■■■ ✓  (k8s manifest update)
```

### ③ 결과 확인

```bash
# GHCR에 새 이미지 푸시됐는지 확인
gh api user/packages/container/sample-app/versions --jq '.[0].metadata.container.tags'

# k8s/deployment.yaml 이미지 태그 업데이트 확인
git pull && grep "image:" k8s/deployment.yaml

# ArgoCD가 감지해 배포했는지 확인 (kind 클러스터 실행 중일 경우)
kubectl -n argocd get application sample-app
kubectl get pods -l app=sample-app
```

---

## 실습 4 — GoCD 고유 기능 실습

### ① 수동 Stage 게이트 (Manual Approval)

Stage 2를 수동 승인 방식으로 변경합니다. 실제 운영에서 "프로덕션 배포 전 사람이 승인"하는 패턴입니다.

`.gocd/sample-app.gocd.yaml` 에서 `build-and-push` Stage 수정:
```yaml
- build-and-push:
    approval:
      type: manual          # success → manual 로 변경
      allow_only_on_success: true
```

변경 후 `git push` → GoCD가 설정 파일을 다시 읽음.
다음 파이프라인 실행 시 Stage 1 완료 후 Stage 2에서 멈춤 → UI에서 수동으로 "▶ Trigger" 버튼 클릭.

### ② 파이프라인 롤백

GoCD는 UI에서 이전 빌드를 바로 재실행할 수 있습니다.

UI: **Pipelines → sample-app** → 이전 빌드 번호 클릭 → **Re-run** 버튼.

> GitHub Actions와의 차이: GoCD는 **이전 Stage 결과(아티팩트 포함)를 재사용**해
> 전체 파이프라인을 다시 돌리지 않고 특정 Stage부터 재실행 가능합니다.

### ③ 파이프라인 스케줄링 (Cron)

매일 새벽 2시에 자동 실행 (야간 빌드 패턴):

`.gocd/sample-app.gocd.yaml` 에 추가:
```yaml
pipelines:
  sample-app:
    timer:
      spec: "0 0 2 * * ?"    # Quartz cron: 매일 02:00
      only_on_changes: true  # 변경사항 없으면 스킵
```

---

## 실습 5 — 환경 분리 (Environments)

GoCD의 `environments`를 사용해 dev/staging/prod 환경을 분리합니다.

`.gocd/sample-app.gocd.yaml` 하단에 추가:
```yaml
environments:
  development:
    environment_variables:
      DEPLOY_ENV: dev
    pipelines:
      - sample-app
```

환경별로 다른 Agent를 배치하고 승인 게이트를 추가하면 dev → staging → prod 프로모션 파이프라인을 구성할 수 있습니다.

---

## 진단 명령어

```bash
# GoCD 컨테이너 상태
docker compose ps
docker compose logs gocd-server | grep -i error
docker compose logs gocd-agent | tail -30

# 파이프라인 API로 상태 확인
curl -su admin:<password> http://localhost:8153/go/api/pipelines/sample-app/status \
  -H "Accept: application/vnd.go.cd.v1+json" | jq

# 파이프라인 수동 트리거
curl -su admin:<password> -X POST \
  http://localhost:8153/go/api/pipelines/sample-app/schedule \
  -H "Confirm: true"

# 에이전트 목록 확인
curl -su admin:<password> http://localhost:8153/go/api/agents \
  -H "Accept: application/vnd.go.cd.v7+json" | jq '.[] | {hostname, status}'
```

---

## 환경 초기화

```bash
cd workplace/gocd

# 컨테이너 + 볼륨 전체 삭제
docker compose down -v

# 이미지도 삭제
docker compose down -v --rmi all
```

---

## GitHub Actions vs GoCD — 언제 무엇을 쓸까?

| 상황 | 추천 |
|------|------|
| 오픈소스 / 소규모 팀 | GitHub Actions (무료, 설정 간단) |
| 복잡한 다단계 배포 파이프라인 | GoCD (시각화, 단계별 승인 강점) |
| 보안 규정상 코드가 외부 서버에 가면 안 됨 | GoCD (자체 서버) |
| 여러 환경(dev/stg/prod) 프로모션 | GoCD (Environments 기능) |
| 파이프라인 간 의존성 복잡 | GoCD (upstream/downstream pipeline) |

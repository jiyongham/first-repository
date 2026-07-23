AWS SAA + EKS 실습 플레이북 | 함지용

> 목표: (1) SAA-C03 취득, (2) EKS 핸즈온으로 이력서의 "AWS 개인 실습" → **"개인 환경 구축·검증"** 격상, (3) 면접에서 쓸 트러블슈팅 스토리 확보.
> 원칙: **모든 실습은 이력서 한 줄 + 면접 2분 스토리로 환산될 수 있어야 한다.**

---

## 0. 전체 전략 (한눈에)

- **기간**: 파트타임 기준 6~8주. SAA 이론(주 3~4시간) + EKS 실습(주말 집중 2~3시간)을 병행.
- **순서**: 비용 가드레일 설정 → SAA 기초(IAM/VPC) → EKS 랩 1~4 → SAA 나머지 도메인 → EKS 랩 5~9 → SAA 응시 → 이력서 격상.
- **왜 병행이 되나**: SAA의 VPC/IAM/EC2/ELB/RDS 이론이 EKS 실습에서 그대로 손에 익습니다. 이론과 실습이 겹치는 게 이 조합의 핵심 이점.
- **지용님 가속 포인트**: 네트워크(서브넷/라우팅/보안그룹)와 Linux는 이미 강하니 VPC·보안 도메인은 빠르게 통과. 서버리스(Lambda/API GW/SQS/SNS)·앱 통합·스토리지 클래스가 상대적으로 새 영역이니 여기에 시간 배분.

---

## 1. ⚠️ 비용 가드레일 (제일 먼저 — 안 하면 요금 폭탄)

EKS는 **프리티어가 없습니다.** 컨트롤플레인만으로 시간당 약 $0.10(≈월 $72), 여기에 NAT Gateway(~$0.045/h), ALB(~$0.0225/h + LCU), EC2 노드가 붙습니다. **실습은 집중해서 하고 끝나면 반드시 삭제**하는 게 핵심.

**시작 전 필수 세팅:**
- [x] **Billing 알림**: Budgets에서 월 $30(또는 본인 한도) 예산 + 50%/80%/100% 알림 이메일 설정
- [x] **CloudWatch 결제 경보**: `EstimatedCharges` 지표에 $10, $30 경보
- [x] **리전 고정**: `ap-northeast-2`(서울) 하나만 사용 — 여러 리전에 리소스 흩어지면 삭제 누락 발생
- [x] **루트 계정 잠금**: 루트에 MFA 걸고, 실습은 IAM 사용자(또는 IAM Identity Center)로. ← 이건 SAA IAM 도메인 실습이기도 함
- [x] **비용 절감 습관**: 세션 끝나면 `eksctl delete cluster`, NAT Gateway·ALB·EIP 잔존 확인, `terraform destroy`

> 💡 요금·프리티어 조건은 시점·리전마다 다르니 실습 당일 AWS 요금 페이지에서 재확인.

---

## 2. SAA-C03 학습 트랙

### 2-1. 시험 개요
- 코드 **SAA-C03**, Associate 등급, 선수요건 없음. 객관식/복수응답 약 65문항, 130분.
- 4개 도메인: ① 보안 아키텍처 설계 ② 복원력(Resilient) 아키텍처 ③ 고성능 아키텍처 ④ 비용 최적화 아키텍처.
- 정확한 도메인 비중·응시료·합격선은 응시 직전 AWS 공식 인증 페이지에서 확인.

### 2-2. 추천 자료 (택1~2 + 문제은행 필수)
- **강의**: Stephane Maarek(Udemy, 실전형·빠름) 또는 Adrian Cantrill(깊이·네트워크 설명 탁월 — 지용님 취향에 맞을 것).
- **문제은행(필수)**: Tutorials Dojo(Jon Bonso) 모의고사 — 이거 안 풀면 불합격 위험. 오답 해설이 학습의 절반.
- **공식**: AWS Skill Builder의 SAA 공식 문제 세트, AWS 백서(Well-Architected Framework는 꼭 정독).

### 2-3. 주차별 계획 (6주 예시)
- **1주 — IAM & 계정 보안**: IAM 사용자/그룹/역할/정책, STS, IAM Identity Center, MFA, 정책 시뮬레이터. → EKS 랩 1과 직결.
- **2주 — VPC & 네트워킹**: 서브넷/라우팅/IGW/NAT/보안그룹/NACL/VPC Endpoint/PrivateLink/TGW/Route53. → 지용님 강점이라 빠르게, 단 **TGW/PrivateLink는 아정당·한국신용데이터 우대라 확실히**.
- **3주 — 컴퓨팅 & 스토리지**: EC2 유형/구매옵션(Spot/RI/SP), EBS/EFS/S3(스토리지 클래스·수명주기·암호화), ELB(ALB/NLB), Auto Scaling.
- **4주 — DB & 서버리스**: RDS/Aurora(읽기복제·Multi-AZ), DynamoDB, ElastiCache, Lambda/API Gateway/SQS/SNS/EventBridge. → **RDS는 지용님 DB 강점과 연결, ElastiCache/서버리스는 새 영역이니 집중**.
- **5주 — 아키텍처 패턴 & 비용**: 디커플링, 캐싱(CloudFront), 재해복구 패턴(Backup/Restore~Multi-Site), 비용 최적화, Well-Architected 5대 기둥.
- **6주 — 모의고사 반복**: TD 모의고사 3~5회, 80%+ 안정되면 응시 예약.

### 2-4. 지용님 강점→약점 매핑
- **이미 아는 것(빠르게)**: 네트워킹 계층(서브넷/라우팅/보안그룹 = 온프렘 조닝과 개념 동일), Linux/EC2, DR 개념(ADG/GSLB 경험 → Multi-AZ/Route53 페일오버로 매핑), IAM(전사 IAM/RBAC 경험 → AWS IAM 정책으로 이식).
- **새로 파는 것(집중)**: 서버리스 3종(Lambda/API GW/DynamoDB), S3 스토리지 클래스·수명주기, ElastiCache, CloudFront, 비용 최적화 도구(Cost Explorer/Savings Plans).

---

## 3. EKS 실습 트랙 (핵심 — 이력서 자산화)

> 각 랩은 **[목표] → [핵심 작업] → [이력서/면접 포인트]** 구조. 산출물은 GitHub(기존 `sample-app`/`.github` 리포)에 커밋해서 증빙화.

### 3-0. 사전 준비 (랩 0)
- [x] AWS CLI v2, `eksctl`, `kubectl`, `helm`, `terraform` 설치
- [ ] IAM 사용자 생성 + `aws configure`(액세스키는 최소권한, 실습 후 폐기)
- [ ] 기존 폐쇄망 PoC(K3s)와의 차이를 의식하며 진행 — "온프렘에서 직접 운영한 컨트롤플레인/네트워크를 관리형(EKS)에서 어떻게 추상화하는가"가 면접 서사

### 랩 1 — 클러스터 생성 (eksctl → 이후 Terraform으로 재작성)
- **[목표]** IaC로 EKS 클러스터를 세우고, 관리형 노드그룹 이해
- **[핵심 작업]**
  ```yaml
  # cluster.yaml (eksctl)
  apiVersion: eksctl.io/v1alpha5
  kind: ClusterConfig
  metadata:
    name: lab-eks
    region: ap-northeast-2
    version: "1.30"   # 실습 당일 지원 버전 확인
  iam:
    withOIDC: true    # IRSA 전제
  managedNodeGroups:
    - name: ng-spot
      instanceTypes: ["t3.large"]
      spot: true       # 비용 절감
      desiredCapacity: 2
      minSize: 1
      maxSize: 3
  ```
  ```bash
  eksctl create cluster -f cluster.yaml
  kubectl get nodes
  ```
  → 익숙해지면 **동일 클러스터를 Terraform(`terraform-aws-modules/eks`)으로 재작성**. 이게 "Terraform으로 EKS 구축" 이력서 근거가 됨.
- **[이력서/면접 포인트]** "eksctl/Terraform으로 EKS 클러스터를 IaC로 구축, Spot 노드그룹으로 비용 최적화" / 면접: OIDC provider가 왜 필요한가(→ IRSA)

### 랩 2 — IRSA (IAM Roles for Service Accounts)
- **[목표]** 파드에 노드 IAM이 아닌 최소권한 역할 부여 (보안 핵심)
- **[핵심 작업]** `eksctl utils associate-iam-oidc-provider` → `eksctl create iamserviceaccount`로 특정 SA에 정책 연결 → 파드에서 AWS API 호출 검증
- **[이력서/면접 포인트]** "IRSA로 파드 단위 최소권한 IAM 설계" — 지용님 **전사 IAM/RBAC/직무분리 실무와 정면 연결**되는 강력한 카드. 안랩·힐링페이퍼 보안 축에 특히 좋음

### 랩 3 — AWS Load Balancer Controller + Ingress (ALB)
- **[목표]** 쿠버네티스 Ingress → ALB 자동 프로비저닝, SAA의 ELB/Route53과 연결
- **[핵심 작업]** Helm으로 AWS LB Controller 설치(IRSA 권한 부여) → Ingress 리소스 생성 → ALB·타겟그룹 자동 생성 확인 → (선택) ACM 인증서 + Route53 도메인
- **[이력서/면접 포인트]** "ALB Ingress, ACM/Route53 연동" — 모요·매드업·부릉 JD의 ALB/Route53 스택 직격. 면접: L7 라우팅이 온프렘 GSLB/조닝과 어떻게 대응되는가

### 랩 4 — ArgoCD 연결 (기존 PoC 이식)
- **[목표]** 폐쇄망 K3s PoC의 GitOps를 EKS로 이식 — "온프렘 PoC를 클라우드로 옮겼다"는 서사 완성
- **[핵심 작업]** ArgoCD 설치 → 기존 Helm Chart/Kustomize 리포를 EKS에 배포 → HPA-ArgoCD Self-Heal 충돌 재현·해결(ignoreDifferences) 확인
- **[이력서/면접 포인트]** PoC의 GitOps 트러블슈팅을 **관리형 환경에서도 재현**했다 = PoC가 "랩 장난감"이 아니라 이식 가능한 역량임을 증명

### 랩 5 — Karpenter (오토스케일링)
- **[목표]** 노드 오토스케일링 — 아정당/모요/골프존 우대 직격
- **[핵심 작업]** Karpenter 설치 → NodePool/EC2NodeClass 정의 → 부하 생성(파드 대량 배포)해 노드 자동 프로비저닝/축소 관찰 → Cluster Autoscaler와의 차이 이해
- **[이력서/면접 포인트]** "Karpenter 기반 노드 오토스케일링 구축·검증" → 아정당에서 "학습 중"이던 걸 실증으로. 면접: 용량 산정 온프렘 실무 + Karpenter 자동화의 연결

### 랩 6 — External Secrets + Secrets Manager
- **[목표]** 시크릿 외부화 — 안랩(Okta/Vault)·힐링페이퍼(External Secrets 명시) 우대
- **[핵심 작업]** External Secrets Operator 설치(IRSA) → Secrets Manager에 시크릿 저장 → ExternalSecret으로 K8s Secret 동기화
- **[이력서/면접 포인트]** "External Secrets Operator + AWS Secrets Manager 시크릿 관리" → 힐링페이퍼 우대 직격, 안랩 SSO/시크릿 축과 연결

### 랩 7 — RDS 연동 (DB 강점 × 갭 메우기)
- **[목표]** EKS 앱 ↔ RDS(MySQL/PostgreSQL) 연결 — 골프존·모요·크림의 RDS 요건 + 지용님 DB 강점 결합
- **[핵심 작업]** RDS(프리티어 db.t3.micro, Multi-AZ 옵션) 생성 → 보안그룹으로 EKS 노드만 접근 허용 → 앱에서 접속 → 슬로우 쿼리/파라미터그룹 살펴보기(온프렘 AWR 경험과 대응)
- **[이력서/면접 포인트]** "RDS 운영(파라미터그룹, Multi-AZ, 보안그룹 격리)" → 관리형 DB 이해 실증. 면접: 온프렘 이기종 DB 운영 경험이 RDS로 어떻게 이식되는가(가장 강한 스토리)

### 랩 8 — 관측성 (CloudWatch Container Insights / Prometheus)
- **[목표]** EKS 모니터링 — 전 JD 공통 Observability
- **[핵심 작업]** CloudWatch Container Insights 활성화 또는 kube-prometheus-stack 설치 → 대시보드/알람 → (여력) OTEL Collector 얹기(토스인슈어런스 OTEL 우대)
- **[이력서/면접 포인트]** "EKS 관측성(Container Insights/Prometheus) 구성" → 기존 PMM/Grafana 실무와 연속선

### 랩 9 — 정리 & 트러블슈팅 노트
- **[목표]** 삭제 습관 + 면접 소재 정리
- **[핵심 작업]** `eksctl delete cluster` → 잔존 리소스(ENI/EIP/ALB/NAT/EBS) 콘솔 확인 → **실습 중 겪은 에러 3~5개를 "문제→원인→해결" 노트로** 기록
- **[이력서/면접 포인트]** 실습 중 실제 막힌 지점(예: IRSA 신뢰정책 오류, LB Controller 서브넷 태그 누락, Karpenter 프로비저닝 실패)이 **가장 진짜 같은 면접 스토리**가 됨. PoC 트러블슈팅과 같은 포맷으로 축적

---

## 4. 실습 → 이력서 격상 매핑 (완료 후 요청하면 일괄 반영)

| 실습 완료 | 이력서 표현 격상 |
|---|---|
| 랩 1~2 | "AWS(개인 실습)" → **"AWS EKS 개인 환경 구축·검증 (Terraform/eksctl, IRSA 최소권한)"** |
| 랩 3 | ALB/Route53을 스택에서 "학습 중" → **"개인 환경 구축"** |
| 랩 5 | Karpenter "학습 중" → **"개인 환경 구축·검증"** (아정당·모요·골프존) |
| 랩 6 | External Secrets/Vault "미경험" → **"External Secrets + Secrets Manager 구성"** (힐링페이퍼·안랩) |
| 랩 7 | RDS "학습 중" → **"RDS 운영 실습(Multi-AZ, 파라미터그룹)"** (골프존·크림·모요) |
| SAA 취득 | 자격증란에 **"AWS Certified Solutions Architect – Associate"** 추가 + 전 이력서 "AWS 학습 중" 제거 |

> ⚠️ 정직성 원칙 유지: 실습으로 한 건 "개인 환경 구축·검증"까지. "프로덕션 운영"으로는 절대 격상하지 않음. 이게 지용님이 지금까지 지켜온 신뢰의 축.

---

## 5. 면접 스토리 만들기 (실습의 진짜 목적)

- **전환 서사**: "온프렘 4,000 VM에서 컨트롤플레인·네트워크·스토리지·IAM을 직접 운영했고, 그 위에 EKS를 얹어 관리형이 추상화한 계층(IRSA, LB Controller, Karpenter)을 개인 환경에서 구축·검증했다. 추상화 아래를 아는 상태에서 위를 배웠다."
- **트러블슈팅 카드**: 랩에서 실제 겪은 에러 3개를 "문제 정의 → 데이터 수집 → 가설 검증 → 해결 → 재발 방지" 포맷으로. (기존 커널 RCA 4건과 같은 구조)
- **DB 브리지**: "온프렘 이기종 DB 운영·AWR 슬로우 쿼리 딥다이브 경험 → RDS 파라미터그룹·Multi-AZ·슬로우 쿼리로 이식" — 가장 강한 연결고리

---

## 6. 진도 체크리스트

**SAA**
- [ ] 강의 완주  - [ ] Well-Architected 백서 정독  - [ ] TD 모의고사 80%+ ×3  - [ ] 응시 예약  - [ ] 합격

**EKS 랩**
- [ ] 랩0 도구설치  - [ ] 랩1 클러스터(eksctl)  - [ ] 랩1b Terraform 재작성  - [ ] 랩2 IRSA  - [ ] 랩3 ALB Ingress  - [ ] 랩4 ArgoCD 이식  - [ ] 랩5 Karpenter  - [ ] 랩6 External Secrets  - [ ] 랩7 RDS  - [ ] 랩8 관측성  - [ ] 랩9 정리+트러블슈팅 노트

**비용**
- [ ] 예산 알림 설정  - [ ] 매 세션 후 클러스터 삭제  - [ ] 월말 Cost Explorer로 잔존 리소스 점검

---

## 7. 지원 전략과의 연결

- **지금(자격증 전)**: 온프렘을 자산으로 보는 고승률 그룹(토스인슈어런스·모두싸인·뱅크샐러드·미리디)부터 제출.
- **랩 1~5 완료 시점**: 하드 갭 그룹(골프존·부릉·크림·페이타랩)의 "학습 중"을 "구축·검증"으로 격상 후 제출.
- **SAA 취득 시점**: 전 이력서 자격증란 반영 + AWS 표현 일괄 상향. 모요·아정당 같은 하드 자격요건 공고도 재도전 가능.

> 완료되는 대로 알려주시면 이력서 일괄 격상과 GitHub 리포 정리(면접 시연용)를 도와드리겠습니다.

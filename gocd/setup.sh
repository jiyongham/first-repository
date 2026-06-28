#!/bin/bash
# GoCD 초기 설정 스크립트 (인증 없는 모드 대응)
# 사용법: ./setup.sh

set -e

GOCD_URL="http://localhost:8153/go"
REPO_URL="https://github.com/jiyongham/first-repository.git"
AUTO_REGISTER_KEY="practice-gocd-key"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
err()   { echo "[ERROR] $*" >&2; exit 1; }

# 인증 없이 curl 호출 (GoCD 초기 상태: everyone is admin)
api() { curl -sf "$@"; }

# ─── 1. 서버 응답 대기 ────────────────────────────────────────────────────────
info "GoCD 서버 응답 대기 중..."
until curl -sf "${GOCD_URL}/api/v1/health" > /dev/null 2>&1; do
  echo "  아직 준비 중... (5초 후 재시도)"
  sleep 5
done
ok "GoCD 서버 응답 확인!"

# ─── 2. YAML Config Plugin 설치 ──────────────────────────────────────────────
info "YAML Config Plugin 설치 중..."

PLUGIN_JAR="/tmp/yaml-config-plugin.jar"
PLUGIN_URLS=(
  "https://github.com/gocd-contrib/gocd-yaml-config-plugin/releases/download/0.14.4/yaml-config-plugin-0.14.4.jar"
  "https://github.com/gocd-contrib/gocd-yaml-config-plugin/releases/download/0.14.3/yaml-config-plugin-0.14.3.jar"
  "https://github.com/gocd-contrib/gocd-yaml-config-plugin/releases/download/0.14.2/yaml-config-plugin-0.14.2.jar"
)

PLUGIN_DOWNLOADED=false
for URL in "${PLUGIN_URLS[@]}"; do
  info "  시도: $URL"
  if curl -fsSL -o "$PLUGIN_JAR" "$URL" 2>/dev/null; then
    PLUGIN_DOWNLOADED=true
    ok "  다운로드 성공!"
    break
  fi
done

if $PLUGIN_DOWNLOADED; then
  docker exec gocd-server mkdir -p /go-working-dir/plugins/external 2>/dev/null || true
  docker cp "$PLUGIN_JAR" gocd-server:/go-working-dir/plugins/external/yaml-config-plugin.jar
  ok "Plugin 복사 완료. 서버 재시작 중..."
  docker restart gocd-server

  info "재시작 대기 중..."
  sleep 20
  until curl -sf "${GOCD_URL}/api/v1/health" > /dev/null 2>&1; do
    echo "  재시작 중... (5초 후 재시도)"
    sleep 5
  done
  ok "서버 재시작 완료!"
else
  warn "Plugin 다운로드 실패. UI에서 수동 설치 필요"
fi

# ─── 3. Agent Auto-Register Key 설정 ─────────────────────────────────────────
info "Agent 자동 등록 키 설정 중..."

CONFIG_RESPONSE=$(curl -sf \
  -H "Accept: application/xml" \
  "${GOCD_URL}/api/admin/config.xml")

CONFIG_MD5=$(curl -sI \
  -H "Accept: application/xml" \
  "${GOCD_URL}/api/admin/config.xml" \
  | grep -i "x-cruise-config-md5" | awk '{print $2}' | tr -d '\r')

if echo "$CONFIG_RESPONSE" | grep -q "agentAutoRegisterKey"; then
  info "agentAutoRegisterKey 이미 설정됨. 건너뜀."
else
  UPDATED_CONFIG=$(echo "$CONFIG_RESPONSE" | \
    sed "s|<server |<server agentAutoRegisterKey=\"${AUTO_REGISTER_KEY}\" |")

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Accept: application/xml" \
    -H "Content-Type: application/xml" \
    -H "X-Cruise-Config-MD5: ${CONFIG_MD5}" \
    -d "${UPDATED_CONFIG}" \
    "${GOCD_URL}/api/admin/config.xml")

  [[ "$HTTP_STATUS" == "200" ]] \
    && ok "Agent Auto-Register Key 설정 완료!" \
    || warn "설정 실패 (HTTP $HTTP_STATUS)"
fi

# ─── 4. Config Repository 등록 ───────────────────────────────────────────────
info "Config Repository 등록 중 (.gocd/ 디렉토리)..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "Accept: application/vnd.go.cd.v4+json" \
  -H "Content-Type: application/json" \
  -d "{
    \"id\": \"first-repository\",
    \"plugin_id\": \"yaml.config.plugin\",
    \"material\": {
      \"type\": \"git\",
      \"attributes\": {
        \"url\": \"${REPO_URL}\",
        \"branch\": \"main\",
        \"auto_update\": true
      }
    },
    \"rules\": [{
      \"directive\": \"allow\",
      \"action\": \"refer\",
      \"type\": \"*\",
      \"resource\": \"*\"
    }]
  }" \
  "${GOCD_URL}/api/admin/config_repos")

case "$HTTP_STATUS" in
  200|201) ok "Config Repository 등록 완료!" ;;
  422)     ok "Config Repository 이미 등록됨. 건너뜀." ;;
  404)     warn "Plugin 미로드 상태 (HTTP 404). 1분 후 재실행하거나 UI에서 수동 등록하세요." ;;
  *)       warn "등록 실패 (HTTP $HTTP_STATUS)" ;;
esac

# ─── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  GoCD 설정 완료!"
echo "  UI: http://localhost:8153"
echo ""
echo "  다음 단계:"
echo "  1. Agents 탭 → local-agent-01 이 Idle 상태인지 확인"
echo "  2. Admin > Config Repositories → first-repository 확인"
echo "  3. Pipelines → sample-app 파이프라인 확인"
echo "  4. Admin > Pipelines > sample-app > Environment Variables"
echo "     → Secure Variable: GITHUB_TOKEN = <GitHub PAT>"
echo "============================================================"

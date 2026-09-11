#!/usr/bin/env bash
# Sets up the MCP stack on a running platform-mesh local-setup cluster and
# wires OIDC so MCP clients authenticate with bearer tokens:
#
#   - installs the access-vw and mcp-vw charts
#   - patches the FrontProxy with /services/access + /services/mcp mappings
#     and Keycloak OIDC authentication
#   - binds the APIExport and impersonator RBAC in the demo workspaces
#   - seeds a Keycloak demo user and a public client with direct grants
#   - extracts the kcp serving CA for client-side TLS trust
#
# Prerequisites:
#   - platform-mesh local-setup cluster (kind), kcp-operator >= v0.9.0
#   - kcp admin kubeconfig, e.g. from the helm-charts repo:
#       local-setup/scripts/createKcpAdminKubeconfig.sh
#   - mkcert (local-setup signs the gateway with the mkcert root CA)
#
# Usage:
#   KCP_ADMIN_KUBECONFIG=/path/to/admin.kubeconfig hack/setup-platform-mesh.sh
#
# By default the charts install from this repo's charts/ directory; set
# CHART_SOURCE=oci (and optionally CHART_VERSION) to install the published
# platform-mesh kcp-access-vw / kcp-mcp-vw charts instead.
set -euo pipefail

CONTEXT=${KUBE_CONTEXT:-kind-platform-mesh}
NS=${NAMESPACE:-platform-mesh-system}
KCP_ADMIN_KUBECONFIG=${KCP_ADMIN_KUBECONFIG:?set KCP_ADMIN_KUBECONFIG to the kcp admin kubeconfig}
DEMO_WORKSPACES=${DEMO_WORKSPACES:-"root:platform-mesh-system root:orgs"}
DEMO_USER=${DEMO_USER:-alice@example.com}
DEMO_PASSWORD=${DEMO_PASSWORD:-alice-password}
KEYCLOAK_URL=${KEYCLOAK_URL:-https://portal.localhost:8443/keycloak}
REALM=${REALM:-welcome}
CLIENT_ID=${CLIENT_ID:-kcp-mcp}
EXTERNAL_URL=${EXTERNAL_URL:-https://kcp.api.portal.localhost:8443}
# CHART_SOURCE=local installs the charts from this repo; CHART_SOURCE=oci
# installs the published platform-mesh charts at CHART_VERSION.
CHART_SOURCE=${CHART_SOURCE:-local}
CHART_VERSION=${CHART_VERSION:-0.1.0}
OCI_REPO=${OCI_REPO:-oci://ghcr.io/platform-mesh/helm-charts}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${CHART_SOURCE}" in
  local)
    ACCESS_CHART=("${ROOT}/charts/access-vw")
    MCP_CHART=("${ROOT}/charts/mcp-vw")
    ;;
  oci)
    ACCESS_CHART=("${OCI_REPO}/kcp-access-vw" --version "${CHART_VERSION}")
    MCP_CHART=("${OCI_REPO}/kcp-mcp-vw" --version "${CHART_VERSION}")
    ;;
  *)
    echo "CHART_SOURCE must be 'local' or 'oci', got '${CHART_SOURCE}'" >&2
    exit 1
    ;;
esac

KC="kubectl --context ${CONTEXT} -n ${NS}"

step() { echo; echo "==> $*"; }

step "Discovering traefik ClusterIP for hostAliases"
TRAEFIK_IP=$(kubectl --context "${CONTEXT}" -n default get svc traefik -o jsonpath='{.spec.clusterIP}')
echo "traefik: ${TRAEFIK_IP}"
HOSTALIASES_VALUES=$(mktemp)
trap 'rm -f "${HOSTALIASES_VALUES}"' EXIT
cat > "${HOSTALIASES_VALUES}" <<EOF
hostAliases:
  - ip: ${TRAEFIK_IP}
    hostnames:
      - root.kcp.localhost
      - kcp.api.portal.localhost
      - portal.localhost
EOF

step "Installing charts"
# The mcp-vw chart mounts this secret for direct OIDC token validation.
${KC} create secret generic mcp-oidc-issuer-ca \
  --from-file=ca.crt="$(mkcert -CAROOT)/rootCA.pem" \
  --dry-run=client -o yaml | ${KC} apply -f -
helm upgrade --install access-vw "${ACCESS_CHART[@]}" \
  --kube-context "${CONTEXT}" -n "${NS}" \
  -f "${ROOT}/examples/platform-mesh/access-vw.values.yaml" \
  -f "${HOSTALIASES_VALUES}"
helm upgrade --install mcp-vw "${MCP_CHART[@]}" \
  --kube-context "${CONTEXT}" -n "${NS}" \
  -f "${ROOT}/examples/platform-mesh/mcp-vw.values.yaml" \
  -f "${HOSTALIASES_VALUES}"

step "Patching FrontProxy path mappings"
if ! ${KC} get frontproxy frontproxy -o json \
    | jq -e '.spec.additionalPathMappings[]? | select(.path == "/services/access")' > /dev/null; then
  ${KC} patch frontproxy frontproxy --type=json \
    --patch-file "${ROOT}/examples/platform-mesh/frontproxy-pathmappings.yaml"
else
  echo "already present"
fi

step "Enabling OIDC on the FrontProxy"
${KC} patch frontproxy frontproxy --type=merge \
  --patch-file "${ROOT}/examples/platform-mesh/frontproxy-oidc.yaml"
${KC} rollout status deployment/frontproxy-front-proxy --timeout=180s

step "Waiting for the access APIExport (created by the access-vw init container)"
KCP_SERVER=$(kubectl --kubeconfig "${KCP_ADMIN_KUBECONFIG}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
KCP_SERVER=${KCP_SERVER%%/clusters/*}
kcp_ws() { # kcp_ws <workspace> <kubectl args...>
  local ws=$1; shift
  kubectl --kubeconfig "${KCP_ADMIN_KUBECONFIG}" --server "${KCP_SERVER}/clusters/${ws}" "$@"
}
for _ in $(seq 60); do
  kcp_ws root:access:controllers get apiexport access.contrib.kcp.io > /dev/null 2>&1 && break
  sleep 5
done
kcp_ws root:access:controllers get apiexport access.contrib.kcp.io > /dev/null

step "Seeding demo workspaces: ${DEMO_WORKSPACES}"
for ws in ${DEMO_WORKSPACES}; do
  echo "-- ${ws}"
  kcp_ws "${ws}" apply -f "${ROOT}/examples/platform-mesh/kcp/apibinding-consumer.yaml"
  kcp_ws "${ws}" apply -f "${ROOT}/examples/platform-mesh/kcp/mcp-impersonator-rbac.yaml"
  kcp_ws "${ws}" create clusterrolebinding mcp-demo-user-admin \
    --clusterrole=cluster-admin --user="oidc:${DEMO_USER}" \
    --dry-run=client -o yaml | kcp_ws "${ws}" apply -f -
done

step "Waiting for the virtual workspace pods"
${KC} rollout status deployment/access-vw-virtual-workspace --timeout=300s
${KC} rollout status deployment/mcp-vw-virtual-workspace --timeout=300s

step "Exposing MCP on mcp.portal.localhost (OAuth discovery bypasses the front-proxy)"
${KC} get secret root-server-ca -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | ${KC} create configmap mcp-vw-backend-ca --from-file=ca.crt=/dev/stdin \
      --dry-run=client -o yaml | ${KC} apply -f -
kubectl --context "${CONTEXT}" apply -f "${ROOT}/examples/platform-mesh/mcp-route.yaml"

step "Seeding Keycloak realm '${REALM}' (user ${DEMO_USER}, client ${CLIENT_ID})"
KC_ADMIN_USER=$(${KC} get secret keycloak-admin -o jsonpath='{.data.username}' | base64 -d)
KC_ADMIN_PW=$(${KC} get secret keycloak-admin -o jsonpath='{.data.secret}' | base64 -d)
ADMIN_TOKEN=$(curl -sk -d "client_id=admin-cli" -d "username=${KC_ADMIN_USER}" \
  -d "password=${KC_ADMIN_PW}" -d "grant_type=password" \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" | jq -r .access_token)
kc_api() { # kc_api <method> <path> [json-body]
  local method=$1 path=$2 body=${3:-}
  curl -sk -X "${method}" -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    ${body:+-H "Content-Type: application/json" -d "${body}"} \
    "${KEYCLOAK_URL}/admin/realms/${REALM}${path}"
}

USER_ID=$(kc_api GET "/users?username=${DEMO_USER}&exact=true" | jq -r '.[0].id // empty')
if [ -z "${USER_ID}" ]; then
  kc_api POST /users "{\"username\":\"${DEMO_USER}\",\"email\":\"${DEMO_USER}\",\"firstName\":\"Demo\",\"lastName\":\"User\",\"enabled\":true,\"emailVerified\":true}" > /dev/null
  USER_ID=$(kc_api GET "/users?username=${DEMO_USER}&exact=true" | jq -r '.[0].id')
fi
kc_api PUT "/users/${USER_ID}" "{\"firstName\":\"Demo\",\"lastName\":\"User\",\"email\":\"${DEMO_USER}\",\"emailVerified\":true,\"requiredActions\":[]}" > /dev/null
kc_api PUT "/users/${USER_ID}/reset-password" "{\"type\":\"password\",\"value\":\"${DEMO_PASSWORD}\",\"temporary\":false}" > /dev/null

INTERNAL_CLIENT_ID=$(kc_api GET "/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')
if [ -z "${INTERNAL_CLIENT_ID}" ]; then
  kc_api POST /clients "{\"clientId\":\"${CLIENT_ID}\",\"publicClient\":true,\"directAccessGrantsEnabled\":true,\"standardFlowEnabled\":true,\"redirectUris\":[\"*\"],\"protocol\":\"openid-connect\"}" > /dev/null
  INTERNAL_CLIENT_ID=$(kc_api GET "/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
fi
if ! kc_api GET "/clients/${INTERNAL_CLIENT_ID}/protocol-mappers/models" \
    | jq -e '.[] | select(.name == "kcp-mcp-audience")' > /dev/null; then
  # kcp validates that the token audience matches the configured client ID.
  kc_api POST "/clients/${INTERNAL_CLIENT_ID}/protocol-mappers/models" \
    "{\"name\":\"kcp-mcp-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"${CLIENT_ID}\",\"access.token.claim\":\"true\"}}" > /dev/null
fi

step "Enabling OAuth client discovery (anonymous DCR + default audience)"
# MCP clients register themselves via RFC 7591 dynamic client registration.
# Keycloak's anonymous DCR policy requires either host or client-URI
# verification; clients redirect to localhost, so trust that and drop the
# request-origin check (the request reaches Keycloak through the gateway).
TRUSTED_HOSTS=$(kc_api GET "/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
  | jq '[.[] | select(.providerId == "trusted-hosts" and .subType == "anonymous")][0]')
echo "${TRUSTED_HOSTS}" | jq '.config["trusted-hosts"] = ["localhost","127.0.0.1"]
    | .config["host-sending-registration-request-must-match"] = ["false"]
    | .config["client-uris-must-match"] = ["true"]' \
  | kc_api PUT "/components/$(echo "${TRUSTED_HOSTS}" | jq -r .id)" "$(cat)" > /dev/null

# Dynamically registered clients get their own client_id; a realm-default
# scope with an audience mapper keeps their tokens acceptable to the server,
# which validates audience against ${CLIENT_ID}.
SCOPE_ID=$(kc_api GET /client-scopes | jq -r ".[] | select(.name == \"kcp-mcp-audience\") | .id")
if [ -z "${SCOPE_ID}" ]; then
  kc_api POST /client-scopes "{\"name\":\"kcp-mcp-audience\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"false\",\"display.on.consent.screen\":\"false\"},\"protocolMappers\":[{\"name\":\"kcp-mcp-audience\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-audience-mapper\",\"config\":{\"included.client.audience\":\"${CLIENT_ID}\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\"}}]}" > /dev/null
  SCOPE_ID=$(kc_api GET /client-scopes | jq -r ".[] | select(.name == \"kcp-mcp-audience\") | .id")
fi
kc_api PUT "/default-default-client-scopes/${SCOPE_ID}" > /dev/null

step "Extracting the kcp serving CA for client-side TLS trust"
mkdir -p "${ROOT}/.secret"
${KC} get secret root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${ROOT}/.secret/kcp-ca.crt"
echo "${ROOT}/.secret/kcp-ca.crt"

step "Verifying end to end"
TOKEN=$(KEYCLOAK_URL="${KEYCLOAK_URL}" REALM="${REALM}" CLIENT_ID="${CLIENT_ID}" \
  DEMO_USER="${DEMO_USER}" DEMO_PASSWORD="${DEMO_PASSWORD}" "${ROOT}/hack/get-token.sh")
curl -s --cacert "${ROOT}/.secret/kcp-ca.crt" -H "Authorization: Bearer ${TOKEN}" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"apiVersion":"access.contrib.kcp.io/v1alpha1","kind":"SelfClusterAccessReview"}' \
  "${EXTERNAL_URL}/services/access/apis/access.contrib.kcp.io/v1alpha1/selfclusteraccessreviews" \
  | jq '.status'
echo "-- OAuth discovery metadata:"
curl -sk "https://mcp.portal.localhost:8443/.well-known/oauth-protected-resource/services/mcp" | jq .

cat <<EOF

Done. MCP endpoint: https://mcp.portal.localhost:8443/services/mcp

Point any MCP client at it with no credentials; it discovers Keycloak via
OAuth protected-resource metadata, registers itself, and opens a browser
login (${DEMO_USER} / ${DEMO_PASSWORD}). TLS is the mkcert root, already
trusted on this machine. For Copilot Chat, copy examples/copilot/mcp.json
to .vscode/mcp.json.

For scripting or debugging without a browser, hack/get-token.sh prints a
bearer token to pass as an Authorization header directly.
EOF

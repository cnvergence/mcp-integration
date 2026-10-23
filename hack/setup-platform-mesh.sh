#!/usr/bin/env bash
# Sets up the MCP stack on a running platform-mesh local-setup cluster:
#
#   - installs the access-vw and mcp-vw charts; mcp-vw validates MCP bearer
#     tokens itself against the local-setup Keycloak
#   - patches the FrontProxy with the /services/access mapping (the
#     front-proxy carries no OIDC configuration and never sees MCP tokens)
#   - binds the APIExport and impersonator RBAC in the demo workspaces
#     (kustomize, examples/platform-mesh/kcp)
#   - configures the Keycloak welcome realm declaratively via a
#     keycloak-config-cli Job (examples/platform-mesh/keycloak); the demo
#     user and client live in that ConfigMap, not in this script
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
# The kcp-access-vw / kcp-mcp-vw charts install from the published
# platform-mesh OCI registry; override the *_CHART_VERSION vars to pin
# other releases.
set -euo pipefail

CONTEXT=${KUBE_CONTEXT:-kind-platform-mesh}
NS=${NAMESPACE:-platform-mesh-system}
KCP_ADMIN_KUBECONFIG=${KCP_ADMIN_KUBECONFIG:?set KCP_ADMIN_KUBECONFIG to the kcp admin kubeconfig}
DEMO_WORKSPACES=${DEMO_WORKSPACES:-"root:platform-mesh-system root:orgs"}
# The demo identity, client and RBAC subject are declared in
# examples/platform-mesh/{keycloak,kcp}; these vars only drive the final
# token verification and must match those manifests.
DEMO_USER=${DEMO_USER:-alice@example.com}
DEMO_PASSWORD=${DEMO_PASSWORD:-alice-password}
KEYCLOAK_URL=${KEYCLOAK_URL:-https://portal.localhost:8443/keycloak}
REALM=${REALM:-welcome}
CLIENT_ID=${CLIENT_ID:-kcp-mcp}
MCP_URL=${MCP_URL:-https://mcp.portal.localhost:8443/services/mcp}
ACCESS_CHART_VERSION=${ACCESS_CHART_VERSION:-0.1.0}
# 0.2.0 is the first kcp-mcp-vw release with the requestheader values the
# demo depends on; older charts silently drop them and mcp-vw keeps
# trusting the kcp requestheader CA instead of the dedicated one.
MCP_CHART_VERSION=${MCP_CHART_VERSION:-0.2.0}
OCI_REPO=${OCI_REPO:-oci://ghcr.io/platform-mesh/helm-charts}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ACCESS_CHART=("${OCI_REPO}/kcp-access-vw" --version "${ACCESS_CHART_VERSION}")
MCP_CHART=("${OCI_REPO}/kcp-mcp-vw" --version "${MCP_CHART_VERSION}")

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
# Dedicated requestheader CA for mcp-vw; the chart mounts its secret.
${KC} apply -f "${ROOT}/examples/platform-mesh/mcp-vw-requestheader-ca.yaml"
${KC} wait certificate mcp-vw-requestheader-ca --for=condition=Ready --timeout=120s
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
  kcp_ws "${ws}" apply -k "${ROOT}/examples/platform-mesh/kcp"
done

step "Waiting for the virtual workspace pods"
${KC} rollout status deployment/access-vw-virtual-workspace --timeout=300s
${KC} rollout status deployment/mcp-vw-virtual-workspace --timeout=300s

step "Exposing MCP on mcp.portal.localhost (OAuth discovery bypasses the front-proxy)"
${KC} get secret root-server-ca -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | ${KC} create configmap mcp-vw-backend-ca --from-file=ca.crt=/dev/stdin \
      --dry-run=client -o yaml | ${KC} apply -f -
kubectl --context "${CONTEXT}" apply -f "${ROOT}/examples/platform-mesh/mcp-route.yaml"

step "Configuring Keycloak realm '${REALM}' declaratively (keycloak-config-cli Job)"
# Job specs are immutable; drop any previous run before re-applying.
${KC} delete job mcp-keycloak-config --ignore-not-found
${KC} apply -f "${ROOT}/examples/platform-mesh/keycloak/mcp-realm-config.yaml"
${KC} wait --for=condition=complete job/mcp-keycloak-config --timeout=180s

step "Extracting the kcp serving CA for client-side TLS trust"
mkdir -p "${ROOT}/.secret"
${KC} get secret root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${ROOT}/.secret/kcp-ca.crt"
echo "${ROOT}/.secret/kcp-ca.crt"

step "Verifying end to end"
TOKEN=$(KEYCLOAK_URL="${KEYCLOAK_URL}" REALM="${REALM}" CLIENT_ID="${CLIENT_ID}" \
  DEMO_USER="${DEMO_USER}" DEMO_PASSWORD="${DEMO_PASSWORD}" "${ROOT}/hack/get-token.sh")
echo "-- MCP initialize as ${DEMO_USER}:"
curl -s --cacert "$(mkcert -CAROOT)/rootCA.pem" \
  -H "Authorization: Bearer ${TOKEN}" \
  -X POST -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"setup-check","version":"0"}}}' \
  "${MCP_URL}" | sed -n 's/^data: //p' | jq '.result.serverInfo'
echo "-- MCP tokens must not work on the kcp API (expect 401):"
curl -s -o /dev/null -w '%{http_code}\n' --cacert "${ROOT}/.secret/kcp-ca.crt" \
  -H "Authorization: Bearer ${TOKEN}" \
  https://kcp.api.portal.localhost:8443/clusters/root/apis | grep -x 401
echo "-- OAuth discovery metadata:"
curl -s --cacert "$(mkcert -CAROOT)/rootCA.pem" \
  "https://mcp.portal.localhost:8443/.well-known/oauth-protected-resource/services/mcp" | jq .

cat <<EOF

Done. MCP endpoint: ${MCP_URL}

Point any MCP client at it with no credentials; it discovers Keycloak via
OAuth protected-resource metadata, registers itself, and opens a browser
login (${DEMO_USER} / ${DEMO_PASSWORD}). TLS is the mkcert root, already
trusted on this machine. For Copilot Chat, copy examples/copilot/mcp.json
to .vscode/mcp.json.

Tokens are only valid on the MCP endpoint: the kcp front-proxy rejects
them, so an MCP credential can never be replayed against the kcp API.
EOF

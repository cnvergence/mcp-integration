#!/usr/bin/env bash
# Sets up the full MCP stack behind the Agent Router (formerly Envoy AI
# Gateway) on a running platform-mesh local-setup cluster:
#
#   - runs hack/setup-platform-mesh.sh for the base MCP stack
#   - installs Envoy Gateway and the Agent Router via Helm
#   - applies the Gateway, MCPRoute and Traefik HTTPRoute from
#     examples/platform-mesh/agent-router
#
# The MCPRoute validates callers' bearer tokens (issuer and audience)
# against the same Keycloak realm and terminates OAuth at the router: it
# asserts the caller's kcp identity to mcp-vw via X-Remote-User over mutual
# TLS (requestheader authentication), so the user token never leaves the
# router. The kcp front-proxy is not on this path.
#
# Usage:
#   KCP_ADMIN_KUBECONFIG=/path/to/admin.kubeconfig hack/setup-agent-router.sh
#
# The router is published through the local-setup Traefik gateway at
# https://agent-router.portal.localhost:8443/mcp.
set -euo pipefail

CONTEXT=${KUBE_CONTEXT:-kind-platform-mesh}
NS=${NAMESPACE:-platform-mesh-system}
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION:-v1.9.1}
AGENT_ROUTER_VERSION=${AGENT_ROUTER_VERSION:-v1.2.0}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KC="kubectl --context ${CONTEXT} -n ${NS}"

step() { echo; echo "==> $*"; }

step "Running the front-proxy setup"
"${ROOT}/hack/setup-platform-mesh.sh"

step "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --kube-context "${CONTEXT}" \
  --namespace envoy-gateway-system --create-namespace \
  -f "${ROOT}/examples/platform-mesh/agent-router/envoy-gateway-values.yaml" \
  --wait --timeout 180s

step "Installing Agent Router ${AGENT_ROUTER_VERSION}"
helm upgrade --install agent-router-crds oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version "${AGENT_ROUTER_VERSION}" \
  --kube-context "${CONTEXT}" \
  --namespace envoy-ai-gateway-system --create-namespace \
  --wait --timeout 60s
helm upgrade --install agent-router oci://docker.io/envoyproxy/ai-gateway-helm \
  --version "${AGENT_ROUTER_VERSION}" \
  --kube-context "${CONTEXT}" \
  --namespace envoy-ai-gateway-system --create-namespace \
  --wait --timeout 180s

step "Applying the Gateway, MCPRoute and HTTPRoute"
kubectl --context "${CONTEXT}" apply -k "${ROOT}/examples/platform-mesh/agent-router"

step "Waiting for the requestheader client certificate"
kubectl --context "${CONTEXT}" -n "${NS}" wait certificate \
  agent-router-requestheader-client --for=condition=Ready --timeout=120s

step "Waiting for the router"
kubectl --context "${CONTEXT}" -n "${NS}" wait gateway agent-router \
  --for=condition=Accepted --timeout=180s
# On kind the Gateway never reaches Programmed because there is no load
# balancer. Wait for the Envoy deployment instead, which Envoy Gateway
# creates in its own namespace.
kubectl --context "${CONTEXT}" -n envoy-gateway-system wait deployment \
  -l gateway.envoyproxy.io/owning-gateway-name=agent-router \
  --for=condition=Available --timeout=180s

echo
echo "==> Agent Router deployed"
echo "==> MCP endpoint: https://agent-router.portal.localhost:8443/mcp"

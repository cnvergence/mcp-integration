#!/usr/bin/env bash
# Prints a bearer token for the demo user, for use as an Authorization
# header by MCP clients:
#
#   curl -H "Authorization: Bearer $(hack/get-token.sh)" ...
set -euo pipefail

KEYCLOAK_URL=${KEYCLOAK_URL:-https://portal.localhost:8443/keycloak}
REALM=${REALM:-welcome}
CLIENT_ID=${CLIENT_ID:-kcp-mcp}
DEMO_USER=${DEMO_USER:-alice@example.com}
DEMO_PASSWORD=${DEMO_PASSWORD:-alice-password}
SCOPE=${SCOPE:-kcp-mcp}

RESPONSE=$(curl -sk -d "client_id=${CLIENT_ID}" -d "username=${DEMO_USER}" \
  -d "password=${DEMO_PASSWORD}" -d "grant_type=password" -d "scope=${SCOPE}" \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token")

TOKEN=$(echo "${RESPONSE}" | jq -r '.access_token // empty')
if [ -z "${TOKEN}" ]; then
  echo "token request failed: $(echo "${RESPONSE}" | jq -r '.error_description // .error // .')" >&2
  exit 1
fi
echo "${TOKEN}"

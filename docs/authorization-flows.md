# Authorization flows

How an MCP client gets authorized in each setup, drawn after the
[authorization flow diagram](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization#authorization-flow-steps)
in the MCP authorization spec (2026-07-28). The participants keep the spec's
roles:

| Spec role | Setup 1 | Setup 2 |
| --- | --- | --- |
| Client | MCP client, e.g. Copilot Chat | same |
| MCP Server (Resource Server) | mcp-vw at `https://mcp.portal.localhost:8443/services/mcp` | Agent Router at `https://agent-router.portal.localhost:8443/mcp` |
| Authorization Server | Keycloak, realm `welcome` (`https://portal.localhost:8443/keycloak/realms/welcome`) | same |

Two participants are added: mcp-vw as the router's backend in Setup 2, and
kcp, which both setups call with impersonation. Client registration uses
dynamic client registration, the one mechanism these setups support. Client ID
Metadata Documents are left out because Keycloak does not support them yet.

## Setup 1: direct

Traefik terminates TLS and forwards to mcp-vw. mcp-vw serves the protected
resource metadata and validates bearer tokens itself.

```mermaid
sequenceDiagram
    participant B as User-Agent (Browser)
    participant C as Client
    participant M as MCP Server (Resource Server)<br/>mcp-vw
    participant A as Authorization Server<br/>Keycloak realm welcome
    participant K as kcp

    C->>M: MCP request without token
    M->>C: HTTP 401 Unauthorized with WWW-Authenticate header<br/>Bearer resource_metadata=".../.well-known/oauth-protected-resource/services/mcp"
    Note over C: Extract resource_metadata URL from WWW-Authenticate

    C->>M: Request Protected Resource Metadata
    M->>C: Return metadata<br/>resource=https://mcp.portal.localhost:8443/services/mcp<br/>authorization_servers=[.../keycloak/realms/welcome]<br/>scopes_supported=[kcp-mcp]

    Note over C: Parse metadata and extract authorization server(s)<br/>Client determines AS to use

    C->>A: GET Authorization server metadata endpoint
    Note over C,A: Try OAuth 2.0 and OpenID Connect discovery endpoints in priority order<br/>.../keycloak/realms/welcome/.well-known/openid-configuration answers
    A-->>C: Authorization server metadata
    Note over C: Validate issuer, verify S256 in code_challenge_methods_supported

    C->>A: POST /realms/welcome/clients-registrations/openid-connect
    Note over A: Anonymous dynamic client registration, redirect URIs limited to localhost<br/>New client may request the optional scope kcp-mcp
    A->>C: Client Credentials (public client_id)

    Note over C: Generate PKCE parameters<br/>Include resource parameter<br/>Apply scope selection strategy (scope=kcp-mcp from scopes_supported)<br/>Record expected issuer
    C->>B: Open browser with authorization URL + code_challenge + resource
    B->>A: Authorization request with resource parameter
    Note over A: User authorizes (alice@example.com)<br/>resource parameter ignored, audience granted by the requested kcp-mcp scope
    A->>B: Redirect to callback with authorization code + iss
    B->>C: Authorization code callback
    Note over C: Validate iss against recorded issuer (RFC 9207)
    C->>A: Token request + code_verifier + resource
    A->>C: Access token (aud includes kcp-mcp) (+ refresh token)

    C->>M: MCP request with access token
    Note over M: Validate issuer, signature, aud includes kcp-mcp<br/>Caller is oidc:alice@example.com
    M->>K: Requests as mcp-virtual-workspace<br/>Impersonate-User: oidc:alice@example.com
    K-->>M: Authorized by workspace RBAC as the caller
    M-->>C: MCP response
    Note over C,M: MCP communication continues with valid token
```

## Setup 2: behind the Agent Router

The Agent Router is the resource server the client sees. It serves the
protected resource metadata, validates the token and asserts the caller's
identity to mcp-vw with requestheader authentication over mutual TLS. The
bearer token is not forwarded past the router.

```mermaid
sequenceDiagram
    participant B as User-Agent (Browser)
    participant C as Client
    participant R as MCP Server (Resource Server)<br/>Agent Router
    participant A as Authorization Server<br/>Keycloak realm welcome
    participant M as mcp-vw
    participant K as kcp

    C->>R: MCP request without token
    R->>C: HTTP 401 Unauthorized with WWW-Authenticate header<br/>Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp",<br/>scope="kcp-mcp"
    Note over C: Extract resource_metadata URL and scope from WWW-Authenticate

    C->>R: Request Protected Resource Metadata
    R->>C: Return metadata<br/>resource=https://agent-router.portal.localhost:8443/mcp<br/>authorization_servers=[.../keycloak/realms/welcome]<br/>scopes_supported=[kcp-mcp]

    Note over C: Parse metadata and extract authorization server(s)<br/>Client determines AS to use

    C->>A: GET Authorization server metadata endpoint
    Note over C,A: Try OAuth 2.0 and OpenID Connect discovery endpoints in priority order<br/>.../keycloak/realms/welcome/.well-known/openid-configuration answers
    A-->>C: Authorization server metadata
    Note over C: Validate issuer, verify S256 in code_challenge_methods_supported

    C->>A: POST /realms/welcome/clients-registrations/openid-connect
    Note over A: Anonymous dynamic client registration, redirect URIs limited to localhost<br/>New client may request the optional scope kcp-mcp
    A->>C: Client Credentials (public client_id)

    Note over C: Generate PKCE parameters<br/>Include resource parameter<br/>Apply scope selection strategy (scope=kcp-mcp from the challenge)<br/>Record expected issuer
    C->>B: Open browser with authorization URL + code_challenge + resource
    B->>A: Authorization request with resource parameter
    Note over A: User authorizes (alice@example.com)<br/>resource parameter ignored, audience granted by the requested kcp-mcp scope
    A->>B: Redirect to callback with authorization code + iss
    B->>C: Authorization code callback
    Note over C: Validate iss against recorded issuer (RFC 9207)
    C->>A: Token request + code_verifier + resource
    A->>C: Access token (aud includes kcp-mcp,<br/>kcp_user=oidc:alice@example.com) (+ refresh token)

    C->>R: MCP request with access token
    Note over R: Validate issuer, signature, aud includes kcp-mcp<br/>X-Remote-User set from the kcp_user claim, client value discarded<br/>Authorization header not forwarded
    R->>M: Backend request over mTLS (client cert CN=agent-router)<br/>X-Remote-User: oidc:alice@example.com
    Note over M: requestheader authentication against<br/>mcp-vw-requestheader-ca, allowed name agent-router
    M->>K: Requests as mcp-virtual-workspace<br/>Impersonate-User: oidc:alice@example.com
    K-->>M: Authorized by workspace RBAC as the caller
    M-->>R: MCP response
    R-->>C: MCP response
    Note over C,R: MCP communication continues with valid token
```

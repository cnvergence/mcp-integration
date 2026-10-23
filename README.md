# mcp-integration

## About this project

Platform-mesh integration for the kcp MCP stack. The stack is two [platform-mesh/helm-charts](https://github.com/platform-mesh/helm-charts) charts wrapping the [contrib-virtual-workspaces](https://github.com/kcp-dev/contrib-virtual-workspaces) images:

- **kcp-access-vw** installs the access virtual workspace. It answers `SelfClusterAccessReview` requests, so a client can list the workspaces its user can access.
- **kcp-mcp-vw** installs the MCP virtual workspace. It is an MCP server that limits every session to the workspaces the caller can access. It acts on resources via impersonation, so kcp authorizes each request as the caller.

Both charts render [kcp-operator](https://github.com/kcp-dev/kcp-operator) `VirtualWorkspace` and `Kubeconfig` resources. Operator v0.9.0 or newer is required.

## Two setups

Both setups run on a [platform-mesh local-setup](https://github.com/platform-mesh/helm-charts) kind cluster. Pick one:

- **Setup 1** exposes the MCP server directly through the platform-mesh Traefik gateway.
- **Setup 2** additionally deploys the [Agent Router](https://theagentrouter.ai) as an MCP-aware gateway in front of the MCP server.

Prerequisites for both:

- a running platform-mesh local-setup kind cluster with kcp-operator v0.9.0 or newer
- a kcp admin kubeconfig, created with `local-setup/scripts/createKcpAdminKubeconfig.sh`
- `mkcert`, `helm` and `jq`

## Setup 1: direct

```sh
KCP_ADMIN_KUBECONFIG=/path/to/helm-charts/.secret/kcp/admin.kubeconfig \
  hack/setup-platform-mesh.sh
```

The script:

- installs both charts from the published OCI registry
- adds the `/services/access` front-proxy path mapping, used by the MCP server to query the access virtual workspace with its own client certificate
- exposes the MCP server with OAuth discovery on `https://mcp.portal.localhost:8443/services/mcp`; the MCP server validates the bearer tokens itself, and the kcp front-proxy never accepts them
- applies the demo workspace manifests (`examples/platform-mesh/kcp`, APIBinding, impersonator RBAC, demo user RBAC) in each demo workspace
- configures the Keycloak welcome realm through a `keycloak-config-cli` Job (`examples/platform-mesh/keycloak`), so the demo user, client and OAuth registration policy are declared as data, not scripted REST calls
- verifies the stack end to end

The script is demo glue only. All configuration it applies lives in declarative files under `examples/platform-mesh/`. The FrontProxy changes are the one exception, see the migration plan below.

The MCP endpoint is `https://mcp.portal.localhost:8443/services/mcp`.

## Setup 2: behind the Agent Router

The Agent Router (formerly Envoy AI Gateway) terminates the caller's OAuth entirely. It validates the JWT against Keycloak — issuer, signature and the `kcp-mcp` audience — serves the OAuth protected-resource metadata, and asserts the caller's kcp identity to the MCP virtual workspace via the `X-Remote-User` header over mutual TLS. This is the same requestheader mechanism the kcp front-proxy uses towards shards, and the same pattern enterprise gateways use for backend identity (Google IAP, AWS ALB OIDC, Azure Easy Auth): the user token never leaves the router, so there is no token to pass through, replay or leak downstream.

```sh
KCP_ADMIN_KUBECONFIG=/path/to/helm-charts/.secret/kcp/admin.kubeconfig \
  hack/setup-agent-router.sh
```

The script runs Setup 1 first, then installs Envoy Gateway and the Agent Router with helm and applies the manifests from `examples/platform-mesh/agent-router/`:

- a `GatewayClass`, `Gateway` and `EnvoyProxy` listening on plain HTTP port 8080, with a backend TLS client certificate issued from a CA dedicated to mcp-vw requestheader trust (`requestheader-cert.yaml`); kcp shards do not trust that CA, so the certificate asserts identities to mcp-vw and nothing else
- an `MCPRoute` that validates JWTs against the Keycloak welcome realm — issuer, signature and the `kcp-mcp` audience — maps the token's `kcp_user` claim to the `X-Remote-User` header (overwriting any client-supplied value) and routes `/mcp` directly to the MCP virtual workspace
- an `HTTPRoute` on the local-setup Traefik gateway that publishes the router at `https://agent-router.portal.localhost:8443`, like the other platform-mesh hosts

The `kcp_user` claim is set by the realm configuration from Setup 1: a `kcp-user` attribute on the demo user and claim + audience mappers on the optional `kcp-mcp` client scope, which clients request because it is advertised as `scopes_supported` (only clients that request it get `aud=kcp-mcp`).

TLS to the MCP virtual workspace is verified through the `BackendTLSPolicy` from Setup 1, which attaches to the backend Service and applies to every gateway routing to it.

The MCP endpoint is `https://agent-router.portal.localhost:8443/mcp`.

Current limitations:

- By default the router prefixes every tool name with the backend name, for example `mcp-vw-virtual-workspace__list_kcp_workspaces`. Since Agent Router v1.2.0, `prefixMode: Never` disables this, but it requires listing every exposed tool in an explicit `toolSelector.include`, which would couple the route to the enabled toolsets — the demo keeps the default.
- The `MCPRoute` backend must live in the same namespace as the route, which is why everything is deployed in `platform-mesh-system`.

## Connecting an MCP client

Point an MCP client at the endpoint of your setup with no credentials. The client discovers Keycloak through OAuth protected-resource metadata (RFC 9728), registers itself and opens a browser login. Sign in as the demo user (`alice@example.com` / `alice-password`). The TLS certificate is signed by the mkcert root, which is already trusted on the machine that ran local-setup.

For GitHub Copilot Chat, copy `examples/copilot/mcp.json` to `.vscode/mcp.json` and start the `kcp` MCP server. The tools then operate only on the workspaces the logged-in user can access.

For scripting or debugging without a browser, `hack/get-token.sh` prints a bearer token for the demo user. Pass it directly as an `Authorization` header.

## Migration plan

This repository is an incubation space. The virtual workspaces stay separate deployments. They are generic kcp infrastructure and are not merged into platform-mesh services. The target layout:

1. **[platform-mesh/helm-charts](https://github.com/platform-mesh/helm-charts)** owns installation and configuration. The `kcp-access-vw` and `kcp-mcp-vw` charts wrap the upstream [contrib-virtual-workspaces](https://github.com/kcp-dev/contrib-virtual-workspaces) images. They are optional add-ons installed on top of a platform-mesh installation, not part of the default profile.
2. **Cross-component glue moves to where each piece is authored.** The `/services/access` path mapping goes into the infra chart values (see `examples/platform-mesh/infra-values-mcp.yaml`). The MCP OAuth client goes into the declarative Keycloak realm configuration, so users authenticate with their existing platform-mesh accounts. The demo realm changes here are already declarative (`examples/platform-mesh/keycloak`), but the anonymous dynamic client registration does not migrate. Workspace seeding (APIBinding plus impersonator RBAC) becomes part of workspace initialization, for example a WorkspaceType initializer, instead of a loop over workspaces.
3. **[platform-mesh/platform-mesh](https://github.com/platform-mesh/platform-mesh)** gets dev-environment wiring only. The contrib/tilt environment deploys the same charts behind an opt-in toggle. No contrib code is imported into monorepo services.

Step 1 is done: the charts are published from platform-mesh/helm-charts and the setup scripts here install them from the OCI registry. This repository now holds client examples and the install scripts.

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/platform-mesh/mcp-integration/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/platform-mesh/mcp-integration/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.
## Code of Conduct

Please refer to our [Code of Conduct](https://github.com/platform-mesh/.github/blob/main/CODE_OF_CONDUCT.md) for information on the expected conduct for contributing to Platform Mesh.

<p align="center"><img alt="Bundesministerium für Wirtschaft und Energie (BMWE)-EU funding logo" src="https://apeirora.eu/assets/img/BMWK-EU.png" width="400"/></p>

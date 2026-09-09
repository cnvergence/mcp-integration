# mcp-integration

## About this project

Helm charts and platform-mesh integration for the kcp MCP stack:

- **charts/access-vw** — the [access virtual workspace](https://github.com/kcp-dev/contrib-virtual-workspaces): permission-aware workspace discovery (`SelfClusterAccessReview`) served through the kcp front proxy.
- **charts/mcp-vw** — the [MCP virtual workspace](https://github.com/kcp-dev/contrib-virtual-workspaces): an MCP server that scopes every session to the workspaces the caller can access and acts on resources via impersonation, so kcp authorizes each request as the caller.

Both charts render [kcp-operator](https://github.com/kcp-dev/kcp-operator) `VirtualWorkspace` and `Kubeconfig` resources (operator v0.9.0 or newer required).

## Demo on platform-mesh local-setup

Prerequisites: a running [platform-mesh local-setup](https://github.com/platform-mesh/helm-charts) kind cluster with kcp-operator >= v0.9.0, a kcp admin kubeconfig (`local-setup/scripts/createKcpAdminKubeconfig.sh`), `mkcert`, `helm`, `jq`.

```sh
KCP_ADMIN_KUBECONFIG=/path/to/helm-charts/.secret/kcp/admin.kubeconfig \
  hack/setup-platform-mesh.sh
```

The script installs both charts, adds `/services/access` and `/services/mcp` front-proxy path mappings, enables OIDC bearer-token authentication against the local-setup Keycloak, exposes the MCP server with OAuth discovery on `https://mcp.portal.localhost:8443/services/mcp`, binds the APIExport and impersonator RBAC in the demo workspaces, seeds a demo user (`alice@example.com`), and verifies the stack end to end.

Connect an MCP client: point it at `https://mcp.portal.localhost:8443/services/mcp` with no credentials. The client discovers Keycloak via OAuth protected-resource metadata (RFC 9728), registers itself, and opens a browser login — sign in as the demo user (`alice@example.com` / `alice-password`). The TLS certificate is the mkcert root, already trusted on the machine that ran local-setup.

For GitHub Copilot Chat, copy `examples/copilot/mcp.json` to `.vscode/mcp.json` and start the `kcp` MCP server. The tools then operate exclusively on the workspaces the logged-in user can access.

For scripting or debugging without a browser, `hack/get-token.sh` prints a bearer token for the demo user that can be passed as an `Authorization` header directly.

## Migration plan

This repository is an incubation space. The target shape upstreams the stack
into platform-mesh itself:

1. **[contrib-virtual-workspaces](https://github.com/kcp-dev/contrib-virtual-workspaces)**:
   expose the access and MCP virtual workspaces as embeddable library
   constructors (today the serve logic is `internal/`), so consumers can mount
   them into an existing `virtual-workspace-framework` root API server.
2. **[platform-mesh/platform-mesh](https://github.com/platform-mesh/platform-mesh)**:
   `services/virtual-workspaces` (built on the same framework) imports the
   contrib module and mounts both virtual workspaces alongside its own, with
   flags for the SCAR endpoint and OIDC/OAuth configuration. They then ship in
   the existing `virtual-workspaces` image — no separate images, charts, or
   OCM component.
3. **[platform-mesh/helm-charts](https://github.com/platform-mesh/helm-charts)**:
   the existing `virtual-workspaces` chart gains the new flags as values plus
   an HTTPRoute for the MCP hostname (OAuth discovery metadata must be served
   anonymously, which the front-proxy does not allow). Keycloak needs no
   changes: users authenticate with their existing platform-mesh accounts, and
   the AI gateway is registered as a single OAuth client through the existing
   realm configuration. The anonymous dynamic client registration relaxation
   used by the demo here does not migrate.

Once that lands, this repository reduces to client examples and demo scripts
for standalone (non-platform-mesh) kcp installations, which keep using the
charts published from `charts/`.

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/platform-mesh/<your-project>/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/platform-mesh/<your-project>/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

Please refer to our [Code of Conduct](https://github.com/platform-mesh/.github/blob/main/CODE_OF_CONDUCT.md) for information on the expected conduct for contributing to Platform Mesh.

<p align="center"><img alt="Bundesministerium für Wirtschaft und Energie (BMWE)-EU funding logo" src="https://apeirora.eu/assets/img/BMWK-EU.png" width="400"/></p>

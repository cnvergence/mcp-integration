# mcp-integration

## About this project

Helm charts and platform-mesh integration for the kcp MCP stack:

- **charts/access-vw** installs the [access virtual workspace](https://github.com/kcp-dev/contrib-virtual-workspaces). It answers `SelfClusterAccessReview` requests, so a client can list the workspaces its user can access.
- **charts/mcp-vw** installs the [MCP virtual workspace](https://github.com/kcp-dev/contrib-virtual-workspaces). It is an MCP server that limits every session to the workspaces the caller can access. It acts on resources via impersonation, so kcp authorizes each request as the caller.

Both charts render [kcp-operator](https://github.com/kcp-dev/kcp-operator) `VirtualWorkspace` and `Kubeconfig` resources. Operator v0.9.0 or newer is required.

## Demo on platform-mesh local-setup

Prerequisites:

- a running [platform-mesh local-setup](https://github.com/platform-mesh/helm-charts) kind cluster with kcp-operator v0.9.0 or newer
- a kcp admin kubeconfig, created with `local-setup/scripts/createKcpAdminKubeconfig.sh`
- `mkcert`, `helm` and `jq`

```sh
KCP_ADMIN_KUBECONFIG=/path/to/helm-charts/.secret/kcp/admin.kubeconfig \
  hack/setup-platform-mesh.sh
```

The script:

- installs both charts
- adds the `/services/access` and `/services/mcp` front-proxy path mappings
- enables OIDC bearer-token authentication against the local-setup Keycloak
- exposes the MCP server with OAuth discovery on `https://mcp.portal.localhost:8443/services/mcp`
- binds the APIExport and impersonator RBAC in the demo workspaces
- seeds a demo user and verifies the stack end to end

To connect an MCP client, point it at `https://mcp.portal.localhost:8443/services/mcp` with no credentials. The client discovers Keycloak through OAuth protected-resource metadata (RFC 9728), registers itself and opens a browser login. Sign in as the demo user (`alice@example.com` / `alice-password`). The TLS certificate is signed by the mkcert root, which is already trusted on the machine that ran local-setup.

For GitHub Copilot Chat, copy `examples/copilot/mcp.json` to `.vscode/mcp.json` and start the `kcp` MCP server. The tools then operate only on the workspaces the logged-in user can access.

For scripting or debugging without a browser, `hack/get-token.sh` prints a bearer token for the demo user. Pass it directly as an `Authorization` header.

## Migration plan

This repository is an incubation space. The virtual workspaces stay separate deployments. They are generic kcp infrastructure and are not merged into platform-mesh services. The target layout:

1. **[platform-mesh/helm-charts](https://github.com/platform-mesh/helm-charts)** owns installation and configuration. The `kcp-access-vw` and `kcp-mcp-vw` charts wrap the upstream [contrib-virtual-workspaces](https://github.com/kcp-dev/contrib-virtual-workspaces) images. They are optional add-ons installed on top of a platform-mesh installation, not part of the default profile.
2. **Cross-component glue moves to where each piece is authored.** The `/services/access` and `/services/mcp` path mappings go into the FrontProxy configuration. The MCP OAuth client goes into the declarative Keycloak realm configuration, so users authenticate with their existing platform-mesh accounts. The anonymous dynamic client registration used by the demo here does not migrate.
3. **[platform-mesh/platform-mesh](https://github.com/platform-mesh/platform-mesh)** gets dev-environment wiring only. The contrib/tilt environment deploys the same charts behind an opt-in toggle. No contrib code is imported into monorepo services.

Once the helm-charts PR lands and the charts are published, `charts/` here gets removed and `hack/setup-platform-mesh.sh` switches to the published charts (`CHART_SOURCE=oci`). This repository then reduces to client examples and the install script.

## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/platform-mesh/<your-project>/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/platform-mesh/<your-project>/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

Please refer to our [Code of Conduct](https://github.com/platform-mesh/.github/blob/main/CODE_OF_CONDUCT.md) for information on the expected conduct for contributing to Platform Mesh.

<p align="center"><img alt="Bundesministerium für Wirtschaft und Energie (BMWE)-EU funding logo" src="https://apeirora.eu/assets/img/BMWK-EU.png" width="400"/></p>

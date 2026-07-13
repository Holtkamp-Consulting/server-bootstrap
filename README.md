# server-bootstrap

One-liner setup script for Raspberry Pi and other Linux servers. Installs Docker and Portainer CE, configures Infisical and GitHub credentials, then deploys Portainer stacks from GitHub repositories.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main/install.sh -o install.sh && bash install.sh
```

During the first installation you will be prompted for Infisical Machine Identity credentials and a GitHub token. The GitHub token needs both the `repo` and `read:packages` scopes — `read:packages` lets Portainer pull private `ghcr.io/holtkamp-consulting/*` images. The Portainer admin password is generated automatically and displayed at the end.

## What it installs

| Component    | Version | Port                        |
|--------------|---------|-----------------------------|
| Docker CE    | latest  | —                           |
| Portainer CE | latest  | 9000 (HTTP), 9443 (HTTPS)   |
| Infisical CLI | latest | —                           |

## Requirements

- Debian-based Linux (Raspberry Pi OS, Ubuntu, Debian)
- `curl` and `sudo` available
- Internet access

## Configuration

Optional environment variables to override default ports:

```bash
PORTAINER_PORT_HTTP=9000 PORTAINER_PORT_HTTPS=9443 bash install.sh
```

Credentials are stored in `/etc/infisical-deploy.env`, owned by `root:docker` with mode `640` (the `docker` group can read it so the runner container can mount it read-only — see [Setting up the GitHub Actions runner](#setting-up-the-github-actions-runner)). Re-running the installer reuses this config. The single GitHub token (with `repo` + `read:packages` scopes) is reused to create a Custom `ghcr.io` registry in Portainer (type Custom, URL `ghcr.io`) — the installer derives the registry username from the token's GitHub login — so private `ghcr.io/holtkamp-consulting/*` images are pulled automatically during stack deploys. The registry persists in the `portainer_data` volume, so later redeploys reuse it.

No Infisical project ID is configured manually. The configured Infisical URL must expose the API endpoint `/api/v1/projects` for the Machine Identity token.

## Stack deployment

The installer deploys every GitHub repository whose repository name matches an Infisical project visible to the configured Machine Identity. Project matching is case-insensitive.

For each matching project/repository pair:

- secrets are loaded from the Infisical project with the same name
- the Portainer stack name is the Infisical project name
- the GitHub repository is deployed using `docker-compose.yml` from the `main` branch

Projects without a matching GitHub repository are skipped. Repositories without a matching Infisical project are not deployed.

## Continuous deployment

After the initial bootstrap, stacks can be redeployed automatically on every push via GitHub Actions.

### How it works

`install.sh` installs `/opt/deploy/redeploy-stacks.sh` on the server. A self-hosted GitHub Actions runner (see below) calls this script when a push triggers the workflow. The script refreshes Portainer credentials and Infisical secrets, then tells Portainer to pull the latest `docker-compose.yml` from the repository and redeploy the stack. If an existing stack was created through Portainer's API instead of as a git-based stack, the script falls back to updating the stack with the current repository `docker-compose.yml`.

Before redeploying, the script stops the stack, removes its containers, and deletes its images so the redeploy always pulls a fresh image for the branch moving-tag (`dev`/`main`) instead of reusing a locally cached one. The `github-runner` stack is exempt (it cannot stop itself mid-job), and the cleanup can be skipped with `--keep-images` — cleanup is best-effort and never changes the redeploy's outcome.

### Files

| File | Purpose |
|---|---|
| `redeploy-stacks.sh` | Runs on the server. Authenticates against Portainer and Infisical, then redeploys the named stack. Before redeploying it stops the stack and removes its containers and images (except for `github-runner`; skippable with `--keep-images`) so a fresh image is pulled. It uses Portainer's git redeploy endpoint for git-based stacks and falls back to a stack-file update for API-created stacks. Works both on the host (reads `/etc/infisical-deploy.env`) and inside a container (reads env vars injected by Portainer). |
| `.github/workflows/redeploy.yml` | Reusable GitHub Actions workflow. Maintained once here; called by all stack repos. Accepts `runner_label` (`dev` or `prod`) to select the right server. |
| `templates/stack-deploy.yml` | Copy this to `.github/workflows/deploy.yml` in each stack repo. Triggers `redeploy.yml` on push to `main` (prod) or `dev`. |
| `templates/github-runner-compose.yml` | `docker-compose.yml` for the self-hosted GitHub Actions runner. Create a `github-runner` repository in the org, add this file as `docker-compose.yml`, and create a matching Infisical project with the secrets listed in the file. The runner is then deployed automatically by `install.sh` alongside other stacks. |

### Setting up a stack repo for CD

1. Copy `templates/stack-deploy.yml` to `.github/workflows/deploy.yml` in the stack repo.
2. Done — pushes to `main` redeploy on prod, pushes to `dev` redeploy on dev.

### Setting up the GitHub Actions runner

The runner itself is deployed as a Portainer stack:

1. Create a `github-runner` repository in the org with `templates/github-runner-compose.yml` as `docker-compose.yml`.
2. Create an Infisical project named `github-runner` with the secrets `APP_ID`, `RUNNER_NAME`, and `RUNNER_LABELS` (e.g. `portainer,prod`). `APP_PRIVATE_KEY` is collected by `install.sh` and stored in `/etc/infisical-deploy.env` — it does not go into Infisical.
3. Re-run `install.sh` or wait for the next bootstrap — the runner stack is picked up automatically.

The runner container reads Portainer and Infisical credentials from `/etc/infisical-deploy.env` (mounted read-only). These bootstrap credentials cannot come from Infisical itself — only runner-specific secrets live there.

The runner uses `network_mode: host` so it can reach Portainer at `localhost:9000`.

## After installation

Open Portainer in your browser:

```
https://<device-ip>:9443
```

Log in with the credentials shown at the end of the installation output.

## Notes

- The generated password is only shown once — save it immediately.
- The current user is added to the `docker` group. A re-login may be required for the change to take effect.
- To view Portainer logs: `docker logs portainer`

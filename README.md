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

Optional environment variable to override the weekly maintenance schedule (default: every Saturday at 00:00 — see [Scheduled maintenance](#scheduled-maintenance)):

```bash
MAINTENANCE_SCHEDULE="Sat *-*-* 00:00:00" bash install.sh
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

The redeploy pins the compose `IMAGE_TAG` to the **immutable per-commit tag** `sha-<commit-sha>` that the app's `build-push` publishes (via `docker/metadata-action` `type=sha,format=long`). Because that tag never already exists on the server, Portainer's `pullImage:true` reliably fetches the freshly-built image. A branch moving-tag (`dev`/`main`) does exist locally after the first deploy, and Portainer reuses its cached digest instead of pulling — which silently serves a stale image. `redeploy.yml` supplies the tag through the `DEPLOY_IMAGE_TAG` env var; a manual host run can pass `--image-tag <tag>` (falling back to the branch moving-tag when neither is given). An explicit `IMAGE_TAG` in Infisical still wins.

> **Updating the installed script:** the runner mounts `/opt/deploy` read-only, so it cannot update `redeploy-stacks.sh` itself. After changing this script, re-run `install.sh` on each server (dev and prod) to refresh `/opt/deploy/redeploy-stacks.sh` from `main`. Until then, an older installed script simply keeps deploying the branch moving-tag — the `DEPLOY_IMAGE_TAG` env var is ignored, never an error.

### Files

| File | Purpose |
|---|---|
| `redeploy-stacks.sh` | Runs on the server. Authenticates against Portainer and Infisical, then redeploys the named stack. Pins the compose `IMAGE_TAG` to the immutable per-commit tag (`--image-tag` / `$DEPLOY_IMAGE_TAG`, falling back to the branch moving-tag) so a fresh image is always pulled. It uses Portainer's git redeploy endpoint for git-based stacks and falls back to a stack-file update for API-created stacks. Works both on the host (reads `/etc/infisical-deploy.env`) and inside a container (reads env vars injected by Portainer). |
| `.github/workflows/redeploy.yml` | Reusable GitHub Actions workflow. Maintained once here; called by all stack repos. Accepts `runner_label` (`dev` or `prod`) to select the right server. |
| `templates/stack-deploy.yml` | Copy this to `.github/workflows/deploy.yml` in each stack repo. Triggers `redeploy.yml` on push to `main` (prod) or `dev`. |
| `templates/github-runner-compose.yml` | `docker-compose.yml` for the self-hosted GitHub Actions runner. Create a `github-runner` repository in the org, add this file as `docker-compose.yml`, and create a matching Infisical project with the secrets listed in the file. The runner is then deployed automatically by `install.sh` alongside other stacks. |
| `maintenance-update.sh` / `maintenance-redeploy.sh` | Run on the server by systemd (see [Scheduled maintenance](#scheduled-maintenance)). `maintenance-update.sh` runs the weekly `apt` update sequence and reboots; `maintenance-redeploy.sh` stops every Portainer stack, removes all containers/images (except Portainer's own), and redeploys every stack via `redeploy-stacks.sh` on the branch's moving tag — safe only because the preceding full image prune forces a fresh pull. |
| `systemd/maintenance-update.timer`, `systemd/maintenance-update.service`, `systemd/maintenance-redeploy.service` | systemd unit files installed to `/etc/systemd/system/` by `install.sh`. The timer triggers `maintenance-update.service` weekly; `maintenance-redeploy.service` is boot-activated but self-gating (`ConditionPathExists=`) so it only runs after a maintenance-triggered reboot, never on an ordinary boot. |

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

## Scheduled maintenance

`install.sh` provisions a systemd timer that runs every Saturday at 00:00 (configurable per host via `MAINTENANCE_SCHEDULE`, see [Configuration](#configuration)) on both dev and prod. Because a self-triggered `reboot` returns immediately and cannot be followed by more work in the same systemd unit, the job is split into two chained services around the reboot:

1. **`maintenance-update.service`** (triggered by `maintenance-update.timer`): `apt update && apt full-upgrade -y && apt autoremove --purge -y && apt clean`, then writes a stamp file at `/var/lib/server-bootstrap/maintenance-reboot-pending` and reboots. If any `apt` step fails, the script aborts and the box is *not* rebooted.
2. **`maintenance-redeploy.service`** (boot-activated, gated by `ConditionPathExists=` on that stamp file — a no-op on every ordinary boot): stops every Portainer stack, removes all containers except Portainer's own, prunes all images (`docker system prune -a -f`, data volumes are preserved), then loops `/opt/deploy/redeploy-stacks.sh --stack <name> --ref refs/heads/<branch>` over every previously-deployed stack. This call omits `--image-tag`, so `redeploy-stacks.sh` resolves `IMAGE_TAG` to the branch's moving tag (e.g. `dev`/`main`) rather than an immutable per-commit `sha-<sha>` tag — safe here only because the preceding `docker system prune -a -f` has already removed every local image, forcing a fresh registry pull. If that prune step is ever weakened or reordered, this redeploy path can silently reuse a stale cached image again. It removes the stamp file when done.

Inspect the schedule and history:

```bash
systemctl list-timers maintenance-update.timer
journalctl -u maintenance-update.service -u maintenance-redeploy.service
```

Trigger a run on demand (does not wait for Saturday):

```bash
sudo systemctl start maintenance-update.service
```

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

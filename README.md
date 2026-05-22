# server-bootstrap

One-liner setup script for Raspberry Pi and other Linux servers. Installs Docker and Portainer CE, configures Infisical and GitHub credentials, then deploys Portainer stacks from GitHub repositories.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main/install.sh -o install.sh && bash install.sh
```

During the first installation you will be prompted for Infisical Machine Identity credentials and a GitHub token. The Portainer admin password is generated automatically and displayed at the end.

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

Credentials are stored in `/etc/infisical-deploy.env` with mode `600`. Re-running the installer reuses this config.

No Infisical project ID is configured manually. The configured Infisical URL must expose the API endpoint `/api/v1/projects` for the Machine Identity token.

## Stack deployment

The installer deploys every GitHub repository whose repository name matches an Infisical project visible to the configured Machine Identity. Project matching is case-insensitive.

For each matching project/repository pair:

- secrets are loaded from the Infisical project with the same name
- the Portainer stack name is the Infisical project name
- the GitHub repository is deployed using `docker-compose.yaml` from the `main` branch

Projects without a matching GitHub repository are skipped. Repositories without a matching Infisical project are not deployed.

## After installation

Open Portainer in your browser:

```
http://<device-ip>:9000
```

Log in with the credentials shown at the end of the installation output.

## Notes

- The generated password is only shown once — save it immediately.
- The current user is added to the `docker` group. A re-login may be required for the change to take effect.
- To view Portainer logs: `docker logs portainer`

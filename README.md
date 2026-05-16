# server-bootstrap

One-liner setup script for Raspberry Pi and other Linux servers. Installs Docker and Portainer CE, prompts for an admin username, and generates a random password.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/Holtkamp-Consulting/server-bootstrap/main/install.sh | bash
```

During installation you will be prompted to enter an admin username. The password is generated automatically and displayed at the end.

## What it installs

| Component    | Version | Port                        |
|--------------|---------|-----------------------------|
| Docker CE    | latest  | —                           |
| Portainer CE | latest  | 9000 (HTTP), 9443 (HTTPS)   |

## Requirements

- Debian-based Linux (Raspberry Pi OS, Ubuntu, Debian)
- `curl` and `sudo` available
- Internet access

## Configuration

Optional environment variables to override default ports:

```bash
PORTAINER_PORT_HTTP=9000 PORTAINER_PORT_HTTPS=9443 bash install.sh
```

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

# BusyDocker

A Docker-based development environment with SSH access for software developers.

## Features

- Ubuntu 22.04 base image
- SSH login with password or passwordless (SSH key)
- Automatic sudoers configuration
- VSCode server support
- X11 forwarding support

## Related files

- `include.pkg` - Debian packages to install
- `include.pip3.pkg` - Python pip packages to install

## Quick Start

```bash
./build.sh --build
./build.sh --run
ssh busydocker
```

## Usage

### Build

```bash
./build.sh --build
```

Interactive prompts will ask:
1. Configure container login user? (username/password)
2. Generate SSH key for passwordless login?
3. Configure `~/.ssh/config` for easy access?

Options:
- `--verbose` - Show detailed build output
- `--port N` - Set SSH port (default: 22)

### Run

```bash
./build.sh --run
```

Options:
- `--port N` - SSH port (must match build port)

### Prune

Stop container and remove image:

```bash
./build.sh --prune
```

## Default Credentials

If you skip user configuration:
- Username: `root`
- Password: `2026ncue`

## SSH Config

When configured, connect simply with:

```bash
ssh busydocker
```

## Customization

Edit these files before build:
- `include.pkg` - Add/remove Debian packages
- `include.pip3.pkg` - Add/remove Python packages

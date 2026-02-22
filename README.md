<div align="center">
  <br>
  <a href="#quick-start">
    <img src="https://img.shields.io/badge/MAC_MEDIA_STACK_PERMISSIONS-00C853?style=for-the-badge&logo=apple&logoColor=white" alt="Mac Media Stack Permissions" height="40" />
  </a>
  <br><br>
  <strong>Audit and fix file permissions across your *arr Docker stack on macOS</strong>
  <br>
  <sub>Permissions are the #1 headache with Docker media stacks on macOS.<br>This tool finds and fixes permission issues before they break your setup.</sub>
  <br><br>
  <img src="https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white" />
  <img src="https://img.shields.io/badge/OrbStack-000000?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIxMCIgZmlsbD0id2hpdGUiLz48L3N2Zz4=&logoColor=white" />
  <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white" />
  <br><br>
  <img src="https://img.shields.io/github/stars/liamvibecodes/mac-media-stack-permissions?style=flat-square&color=yellow" />
  <img src="https://img.shields.io/github/license/liamvibecodes/mac-media-stack-permissions?style=flat-square" />
  <br><br>
</div>

## The Problem

File permissions are the most common issue with Docker media stacks on macOS. Every other post on r/selfhosted and r/radarr is someone debugging why Sonarr can't write to their download folder or Radarr can't move files after import.

The usual causes:
- PUID/PGID set differently across containers
- Volume mounts owned by root instead of your user
- macOS privacy controls blocking Docker's disk access
- .env file missing or has stale user IDs

This script audits everything in one pass and tells you exactly what's wrong.

## What It Checks

| Check | What It Looks For |
|-------|------------------|
| **Runtime detection** | OrbStack or Docker Desktop installed and running |
| **PUID/PGID consistency** | All containers using the same user/group IDs |
| **.env validation** | PUID/PGID set and matching your current user |
| **Volume permissions** | Host directories owned by the expected user |
| **Full Disk Access** | Docker/OrbStack has macOS disk access permissions |
| **Compose config** | docker-compose.yml exists and is parseable |

## Quick Start

```bash
git clone https://github.com/liamvibecodes/mac-media-stack-permissions.git
cd mac-media-stack-permissions
bash fix-permissions.sh
```

Or run directly:

```bash
curl -fsSL https://raw.githubusercontent.com/liamvibecodes/mac-media-stack-permissions/main/fix-permissions.sh | bash
```

## Usage

```bash
# Audit only (default, no changes made)
bash fix-permissions.sh

# Audit a custom media directory
bash fix-permissions.sh --path /Volumes/Media

# Fix all permission issues
bash fix-permissions.sh --fix

# Fix with custom path
bash fix-permissions.sh --fix --path /Volumes/Media

# Allow fixes for compose mounts outside --path
bash fix-permissions.sh --fix --allow-outside-media-dir
```

## Example Output

```
==============================
  Permission Audit
==============================

OK    Runtime: OrbStack detected
OK    docker-compose.yml found at /Users/you/Media/docker-compose.yml
OK    .env PUID (501) matches current user
OK    .env PGID (20) matches current group
WARN  PUID mismatch: sonarr uses 1000, expected 501
OK    config/ owned by you (501:20)
FAIL  downloads/ owned by root (0:0), expected 501:20
WARN  Full Disk Access not confirmed for OrbStack

==============================
  Summary: 4 passed, 2 warnings, 1 failed
==============================
```

## Fix Mode

Run with `--fix` to automatically resolve permission issues:

- Runs `chown -R` on directories with wrong ownership
- Reports what was changed
- Protects paths outside `--path` by default (use `--allow-outside-media-dir` to override)

The script never modifies docker-compose.yml or .env. It only fixes file ownership on disk.

## Works With

- [mac-media-stack](https://github.com/liamvibecodes/mac-media-stack) — One-command Plex + Sonarr + Radarr setup
- [mac-media-stack-advanced](https://github.com/liamvibecodes/mac-media-stack-advanced) — Power-user setup with transcoding, quality profiles, and automation

## Author

Built by [@liamvibecodes](https://github.com/liamvibecodes)

## License

[MIT](LICENSE)

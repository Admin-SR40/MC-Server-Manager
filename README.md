<h1 align="center">MC-Server-Manager</h1>

<p align="center">All-in-one Purpur Minecraft server management tool — version control, backup & recovery, plugin management, world management, crash analysis, and system maintenance from a modular launcher.</p>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Python-3.8+-blue" alt="Python"></a>
  <a href="#"><img src="https://img.shields.io/badge/Java-8+-red" alt="Java"></a>
  <a href="#"><img src="https://img.shields.io/badge/Server-Purpur-8A2BE2" alt="Purpur"></a>
  <a href="#"><img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey" alt="Platform"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="License"></a>
  <a href="https://github.com/Admin-SR40/MC-Server-Manager/releases/latest"><img src="https://img.shields.io/badge/Version-9.0-orange" alt="Version"></a>
</p>

---

## How It Works

`start.sh` is a small core launcher. All management features are **modules** that are downloaded from GitHub on demand:

1. Download `start.sh` and place it in your server directory.
2. Run `./start.sh` — on first run it detects that no modules are installed and enters the module setup flow.
3. Choose which modules to install (or run `./start.sh --install all`).
4. Installed modules are saved to a module folder with a `modules.json` registry, so later updates only touch modules you actually installed.

The core script always supports: starting the server, `--install`, `--info`, `--version`, `--license` and `--help`.

## Installation

1. Install **Python 3.8+** and **Java 8+**
2. Download `start.sh` and place it in your server directory
3. Make it executable (Unix): `chmod +x start.sh`
4. Run: `./start.sh` (first run opens the module installer)
5. Configure the server: `./start.sh --init auto`
6. Start the server: `./start.sh`

> Windows: run `python start.sh [options]` instead. PyYAML is only required by the `plugins` module (`pip install PyYAML`).

## Modules

### Module Location

During the first install you can choose where modules are stored:

| Option | Location | Use case |
|--------|----------|----------|
| 1 | `~/.cache/MC-Server-Manager` | Shared by all servers on this machine |
| 2 | `<server>/bundles/modules` | Stored inside this server directory |
| 3 | Custom path | Any other location |

The choice is saved in `config/modules.cfg` and can be changed at any time by editing:

```ini
[MODULES]
dir = /path/to/modules
```

`modules.json` inside the module folder records every installed module's version and MD5 hash, which is used to compare against `update.json` when checking for updates.

### Available Modules

| Module | Commands | Description | Requires |
|--------|----------|-------------|----------|
| `init` | `--init`, `--init auto`, `--standardize` | Server initialization and structure standardization | — |
| `version` | `--get`, `--list`, `--new`, `--change`, `--upgrade`, `--delete` | Purpur version download, switch and upgrade | `backup`, `init` |
| `backup` | `--save`, `--backup`, `--rollback` | Version snapshots, backups and rollback | — |
| `plugins` | `--plugins`, `--plugins analyze` | Plugin management with dependency awareness | — |
| `worlds` | `--worlds` | World delete/backup/import and seed configuration | — |
| `crash` | *(automatic)* | Crash detection and structured crash reports | — |
| `players` | `--players` | Banned players, IP bans and whitelist | — |
| `settings` | `--settings` | Interactive server.properties editor | — |
| `maintenance` | `--cleanup`, `--dump` | File cleanup and log dump utilities | — |

Install a single module, several modules, or everything:

```bash
./start.sh --install plugins
./start.sh --install plugins worlds players
./start.sh --install all
```

If a module depends on other modules (e.g. `version` requires `backup` and `init`), the installer asks whether to install the dependencies first.

## Commands

<details>
<summary>Core</summary>

| Command | Description |
|---------|-------------|
| `(no command)` | Start the server |
| `--install [module\|all]` | Install or update modules |
| `--info` | Show server configuration and environment info |
| `--version [force]` | Check for script and module updates |
| `--license` | Show the open source license |
| `--help` | Show installed commands and available modules |

</details>

<details>
<summary>Version & Backup</summary>

| Command | Module | Description |
|---------|--------|-------------|
| `--get` | version | List available Purpur server versions |
| `--get <version>` | version | Download a specific version (e.g. `--get 1.21.5`) |
| `--list` | version | List installed version bundles |
| `--new` | version | Save current server and create a new one |
| `--change <version>` | version | Switch to a different installed version |
| `--upgrade` | version | Upgrade to a compatible newer version |
| `--upgrade force` | version | Show all versions including incompatible ones |
| `--delete <version>` | version | Delete a version or backup |
| `--save <version>` | backup | Save current server as a named version |
| `--backup` | backup | Create a timestamped backup |
| `--rollback` | backup | Interactive rollback to a previous backup |

</details>

<details>
<summary>Plugins & Worlds</summary>

| Command | Module | Description |
|---------|--------|-------------|
| `--plugins` | plugins | Manage plugins with dependency awareness |
| `--plugins analyze` | plugins | Analyze and display plugin dependency tree |
| `--worlds` | worlds | Manage worlds (delete, backup, import, seed) |

</details>

<details>
<summary>Configuration & Maintenance</summary>

| Command | Module | Description |
|---------|--------|-------------|
| `--init` | init | Manual server configuration |
| `--init auto` | init | Automatic configuration with intelligent defaults |
| `--standardize` | init | Migrate an existing server into the managed structure |
| `--settings` | settings | Interactive server properties editor |
| `--players` | players | Manage banned players, IP bans and whitelist |
| `--cleanup` | maintenance | Clean up temporary files and free disk space |
| `--dump [keywords]` | maintenance | Create compressed dump / search log files |

</details>

## Updates

`update.json` contains the core script and **all** modules with their version, URL, MD5 and dependencies.

```bash
./start.sh --version        # update core + installed modules only
./start.sh --version force  # force-download core + update installed modules
```

By default, uninstalled modules are never downloaded or touched. Updates are MD5-verified before installation, and the current core script is backed up as `start.sh.bak` before being replaced.

## Features

<details>
<summary>Server Management</summary>

- **One-click start** with automatic Java detection and memory allocation
- **PTY terminal (Linux)** — full JLine features: tab completion, command history, colored output
- **Windows support** — pipe fallback with console command forwarding
- **Smart memory allocation** — detects system/container RAM, calculates optimal heap size
- **Automatic EULA** acceptance and environment validation
- **Task locking** — prevents duplicate instances, handles interrupted operations
- **Environment fingerprinting** — detects device changes to prevent data loss
- **Structured logging** — persistent logs in `logs/manager.log` with auto-rotation at 128 KB

</details>

<details>
<summary>Version Management</summary>

- Download Purpur server versions from the official API
- Switch between installed versions with one command
- Smart upgrades within compatible major versions (force mode available)
- MD5 integrity verification on all downloads

</details>

<details>
<summary>Backup & Recovery</summary>

- Version snapshots — save current server state as a named version
- Timestamped backups — automatic backups with version and timestamp
- One-click rollback — interactive rollback to any previous backup point
- World backups — selective world backup and restore

</details>

<details>
<summary>Plugin Management</summary>

- View, enable and disable all plugins
- Dependency-aware — automatic dependency detection prevents conflicts
- Cascading disable — automatically disables dependent plugins
- Dependency tree analyzer — visualize plugin relationships

</details>

<details>
<summary>Crash Analysis</summary>

- Automatically detects server crashes and abnormal exits
- Scans logs for common error patterns (OOM, deadlock, stack overflow, etc.)
- Checks plugin dependency chains for missing required plugins
- Generates structured crash reports with environment info and error contexts
- Filters out false positives (mistyped commands, harmless JVM warnings)

</details>

<details>
<summary>System Maintenance</summary>

- File cleanup — removes temporary files, old logs, and stale backups
- Log dumping — compressed log archives with keyword search
- Self-update — check for and download the latest core/modules
- Container support — Docker and Kubernetes environment detection with cgroup memory limits

</details>

## Configuration

<details>
<summary>config/version.cfg</summary>

| Key | Description |
|-----|-------------|
| `version` | Minecraft server version |
| `max_ram` | Maximum memory allocation (MB) |
| `java_path` | Java executable path |
| `additional_list` | Extra files/directories excluded from backups |
| `additional_parameters` | Additional JVM startup parameters |
| `device` | Generated device fingerprint for environment safety checks |

</details>

<details>
<summary>config/modules.cfg</summary>

| Key | Description |
|-----|-------------|
| `dir` | Directory where installed modules and `modules.json` are stored |

</details>

## Directory Structure

```
./
├── start.sh                                         # Core launcher
├── modules/                                         # (repo) Module source files
├── core.jar                                         # Server core
├── config/
│   ├── version.cfg                                  # Tool configuration
│   ├── modules.cfg                                  # Module directory setting
│   └── server.properties                            # Server properties
├── bundles/                                         # Version & backup storage
│   └── [version]/
│       ├── core.zip                                 # Server core package
│       ├── server.zip                               # Full server snapshot
│       ├── *.zip                                    # Timestamped backups
│       └── worlds/
│           └── worlds_*.zip                         # World backups
├── plugins/                                         # Plugin directory
├── worlds/                                          # World data
├── logs/
│   ├── manager.log                                  # Tool log
│   └── latest.log                                   # Server log
├── eula.txt                                         # EULA agreement
└── task.lock                                        # Task lock file
```

## Migrating Existing Servers

If you already have a Minecraft server created outside this tool, install the `init` module and use:

```bash
./start.sh --install init
./start.sh --standardize
```

This moves config files into `config/`, world folders into `worlds/`, and renames the server JAR to `core.jar`. **Always back up your server files first.** After standardization, run `--init auto` to complete the setup.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| First run opens the installer every time | Ensure the module folder contains module files or `modules.json` |
| Module download fails | Check your internet connection and that `update.json` is reachable |
| `--plugins` reports PyYAML missing | `pip install PyYAML` (only needed for the plugins module) |
| Java path issues | Run `--init` to reconfigure |
| Port conflicts | Modify `server-port` in `config/server.properties` |
| Permission errors | Ensure execute permissions and read/write access |
| Log inspection | Check `./logs/manager.log` for detailed diagnostics |

For additional help, [open an issue](https://github.com/Admin-SR40/MC-Server-Manager/issues/new) or visit the [Wiki](https://deepwiki.com/Admin-SR40/MC-Server-Manager).

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

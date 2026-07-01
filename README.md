<h1 align="center">MC-Server-Manager</h1>

<p align="center">All-in-one Purpur Minecraft server management tool — version control, backup & recovery, plugin management, world management, crash analysis, and system maintenance from a single script.</p>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Python-3.8+-blue" alt="Python"></a>
  <a href="#"><img src="https://img.shields.io/badge/Java-8+-red" alt="Java"></a>
  <a href="#"><img src="https://img.shields.io/badge/Server-Purpur-8A2BE2" alt="Purpur"></a>
  <a href="#"><img src="https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey" alt="Platform"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="License"></a>
  <a href="https://github.com/Admin-SR40/MC-Server-Manager/releases/latest"><img src="https://img.shields.io/badge/Version-8.0-orange" alt="Version"></a>
</p>

---

## Installation

1. Install **Python 3.8+** and **Java 8+**
2. Install PyYAML: `pip install PyYAML`
3. Download `start.sh` and place it in your server directory
4. Make it executable (Unix): `chmod +x start.sh`
5. Run: `./start.sh --get <version>` → `./start.sh --new` → `./start.sh --init auto`
6. Start the server: `./start.sh`

---

## Features

<details>
<summary>Server Management</summary>

- **One-click start** with automatic Java detection and memory allocation
- **PTY terminal (Linux)** — full JLine features: tab completion, command history, colored output
- **Smart memory allocation** — detects system/container RAM, calculates optimal heap size with formula `(29 × MAX + 8192) / 60`
- **Automatic EULA** acceptance and environment validation
- **Interactive settings editor** — graphical-style text UI for `server.properties`
- **Player management** — ban lists, IP bans, whitelist, operators
- **Task locking** — prevents duplicate instances, handles interrupted operations
- **Environment fingerprinting** — detects device changes to prevent data loss
- **Structured logging** — persistent logs in `logs/manager.log` with auto-rotation at 128 KB

</details>

<details>
<summary>Version Management</summary>

- Download Purpur server versions from the official API
- Switch between installed versions with one command
- Smart upgrades within compatible major versions (force mode available for cross-version)
- List, save, and delete version bundles
- MD5 integrity verification on all downloads

</details>

<details>
<summary>Backup & Recovery</summary>

- **Version snapshots** — save current server state as a named version
- **Timestamped backups** — automatic backups with version and timestamp
- **One-click rollback** — interactive rollback to any previous backup point
- **World backups** — selective world backup and restore

</details>

<details>
<summary>Plugin Management</summary>

- View, enable, and disable all plugins
- **Dependency-aware** — automatic dependency detection prevents conflicts
- **Cascading disable** — automatically disables dependent plugins
- **Dependency tree analyzer** — CLI command to visualize plugin relationships
- Batch operations and safe mode during upgrades

</details>

<details>
<summary>World Management</summary>

- Reset, backup, restore, and import worlds
- Configure world generation seeds
- Display world size and corruption status
- Selective single or multi-world operations

</details>

<details>
<summary>Crash Analysis</summary>

- Automatically detects server crashes and abnormal exits
- Scans logs for 14 error patterns (OOM, deadlock, stack overflow, etc.)
- Checks plugin dependency chains for missing required plugins
- Generates structured crash reports with environment info, error contexts, and timelines
- Filters out false positives (mistyped commands, harmless JVM warnings)
- Interactive prompts for suspicious log patterns even on clean exits

</details>

<details>
<summary>System Maintenance</summary>

- **File cleanup** — removes temporary files, old logs, and stale backups
- **Log dumping** — compressed log archives with keyword search
- **Self-update** — check for and download latest script version
- **Container support** — Docker and Kubernetes environment detection with cgroup memory limits
- **Console filtering** — suppresses harmless startup warnings (JOML Unsafe, incubator modules, JLine terminal fallback)

</details>

---

## Commands

<details>
<summary>Basic</summary>

| Command | Description |
|---------|-------------|
| `(no command)` | Start the server |
| `--init` | Manual server configuration |
| `--init auto` | Automatic configuration with intelligent defaults |
| `--info` | Show server configuration and environment info |
| `--help` | Show help information |
| `--version` | Show script version and check for updates |
| `--version force` | Force download latest script version |
| `--license` | Show the open source license |

</details>

<details>
<summary>Version & Backup</summary>

| Command | Description |
|---------|-------------|
| `--get` | List available Purpur server versions |
| `--get <version>` | Download a specific version (e.g. `--get 1.21.5`) |
| `--list` | List installed version bundles |
| `--new` | Create a new server from an installed version |
| `--change <version>` | Switch to a different installed version |
| `--upgrade` | Upgrade to a compatible newer version |
| `--upgrade force` | Show all versions including incompatible ones |
| `--delete <version>` | Delete a version or backup |
| `--save <version>` | Save current server as a named version |
| `--backup` | Create a timestamped backup |
| `--rollback` | Interactive rollback to a previous backup |

</details>

<details>
<summary>Plugins & Worlds</summary>

| Command | Description |
|---------|-------------|
| `--plugins` | Manage plugins with dependency awareness |
| `--plugins analyze` | Analyze and display plugin dependency tree |
| `--worlds` | Manage worlds (reset, backup, restore, import) |

</details>

<details>
<summary>Configuration & Maintenance</summary>

| Command | Description |
|---------|-------------|
| `--settings` | Interactive server properties editor |
| `--players` | Manage banned players, IP bans, whitelist, operators |
| `--cleanup` | Clean up temporary files and free disk space |
| `--dump` | Create compressed dump of all log files |
| `--dump <keywords>` | Search and dump specific log content |
| `--standardize` | Migrate an existing server into the managed structure |

</details>

---

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

---

## Directory Structure

```
./
├── start.sh                                         # Main script
├── core.jar                                         # Server core
├── config/
│   ├── version.cfg                                  # Tool configuration
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

---

## Migrating Existing Servers

If you already have a Minecraft server created outside this tool, use `--standardize` to convert its structure:

```bash
./start.sh --standardize
```

This will move config files into `config/`, world folders into `worlds/`, and rename the server JAR to `core.jar`. **Always back up your server files first.** After standardization, run `--init auto` to complete the setup.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| PyYAML not found | `pip install PyYAML` |
| Java path issues | Run `--init` to reconfigure |
| Port conflicts | Modify `server-port` in `config/server.properties` |
| Permission errors | Ensure execute permissions and read/write access |
| Log inspection | Check `./logs/manager.log` for detailed diagnostics |

For additional help, [open an issue](https://github.com/Admin-SR40/MC-Server-Manager/issues/new) or visit the [Wiki](https://deepwiki.com/Admin-SR40/MC-Server-Manager).

---

## License

This project is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

# Minecraft Server Manager

## Introduction
A powerful Minecraft server management tool written in Python (distributed as `start.sh`), currently targeting Purpur servers. This tool provides a comprehensive server management solution including version management, backup and recovery, plugin management, world management, logging, and task-safety mechanisms, making server administration simpler and more reliable.

## Key Features

### Server Management
- **One-Click Start**: Automatically configure and start Minecraft server
- **Version Management**: Download, switch, and manage multiple server versions
- **Auto Configuration**: Intelligent Java environment detection and configuration
- **Server Crash Analysis**: Generate crash report when crash detected
- **Automatic EULA**: Automatically handle Mojang EULA agreement
- **Server Settings**: Interactive server configuration editor
- **Player Management**: Manage banned players, IPs, and whitelist
- **Task Locking**: Prevent duplicate instances and handle interrupted tasks
- **Structured Logging**: Persistent logs written to `logs/manager.log` with automatic rotation

### Backup & Recovery
- **Version Backup**: Save current server state as specific versions
- **Timestamped Backups**: Create automatic backups with timestamps
- **Quick Rollback**: One-click rollback to any previous backup point
- **Incremental Management**: Smart backup file management to save space

### Plugin System
- **Plugin Management**: View, enable, disable all plugins
- **Dependency Checking**: Automatic plugin dependency detection to prevent conflicts
- **Batch Operations**: Support batch enable/disable plugins
- **Safe Mode**: Automatically disable plugins during upgrades for data safety
- **Dependency Chain**: Automatic dependency chain management

### World Management
- **World Reset**: Safely delete and regenerate worlds
- **Seed Configuration**: Flexible world generation seed settings
- **Selective Management**: Support single or multiple world management
- **World Status**: Display world size and corruption status
- **Easy Import/Export**: Make backup/rollback much easier 

### System Maintenance
- **File Cleanup**: Automatically clean logs and temporary files to free disk space
- **Log Dumping**: Compress and archive server logs with search functionality
- **Integrity Verification**: Automatic MD5 checksum verification for downloads
- **Self-Update**: Automatic script updates to latest version
- **Memory Optimization**: Smart RAM allocation based on system resources
- **Container Support**: Docker and container environment detection

### Security & Monitoring
- **Duplicate Prevention**: Task lock mechanism prevents multiple instances
- **Process Monitoring**: Check if previous tasks are still running
- **Interruption Recovery**: Resume interrupted operations safely
- **Time Tracking**: Display task duration and interruption times
- **Device Fingerprint**: Detect environment changes to prevent data loss

## System Requirements
- Python 3.8 or higher is recommended
- Java 8 or higher (for running Minecraft server)
- Dependencies: PyYAML
- Operating Systems: Windows, Linux, macOS
- Container Environments: Docker, Kubernetes (supported)

## Installation
1. Download the `start.sh` script to your server directory.
2. Ensure Python 3.8+ is available in your environment.
3. Install required Python dependency:
   `pip install PyYAML`
4. Make the script executable if using Unix-like systems:
   `chmod +x start.sh`
5. Run the script:
   - Windows: `python start.sh [options]`
   - Linux / macOS: `./start.sh [options]`

## Migrating Existing Servers
If you already have a Minecraft server created **outside** this script,
you cannot manage it directly without converting its structure.

To solve this, use:
- `./start.sh --standardize`

This command may:
- Move configuration files into the `config/` directory
- Move world folders into the `worlds/` directory
- Rename the server core jar to `core.jar`
- Create required management directories

Although the script is designed to be safe, it **may not** cover all custom setups.
You should always backup your server files first!

After standardization, you should initialize the server:
- Use `--init` for manual configuration
- Use `--init auto` for automatic setup (recommended for beginners)

## Command Reference

### Basic Commands
- `(no command)` - Start the server
- `--init` - Initialize server configuration manually
- `--init auto` - Automatic server configuration with intelligent defaults
- `--info` - Show current server configuration and environment info
- `--help` - Show help information
- `--version` - Show script version and check for updates
- `--version force` - Force download latest script version
- `--license` - Show the open source license

### Version Management
- `--get` - Show available Purpur server versions
- `--get <version>` - Download specific Purpur server version
- `--list` - List all available bundled versions
- `--new` - Create a new server instance
- `--change <version>` - Switch to specified version
- `--upgrade` - Upgrade server core to a compatible version
- `--upgrade force` - Force upgrade and show all versions
- `--delete <version>` - Delete specified version or backup

### Backup Management
- `--save <version>` - Save current version to bundles
- `--backup` - Create timestamped backup of current version
- `--rollback` - Rollback to previous backup

### Plugin Management
- `--plugins` - Manage plugins with dependency awareness
- `--plugins analyze` - Analyze plugin dependency tree

### World Management
- `--worlds` - Manage worlds (reset, backup, restore)

### Server Configuration
- `--settings` - Edit server properties interactively
- `--players` - Manage banned players, IPs, and whitelist

### System Maintenance
- `--cleanup` - Clean up server files to free space
- `--dump` - Create compressed dump of log files
- `--dump <keywords>` - Search and dump specific log content

## Configuration
Configuration file is located at `config/version.cfg` and includes:

- `version`: Minecraft server version
- `max_ram`: Maximum memory allocation (MB)
- `java_path`: Java executable path
- `additional_list`: Additional files/directories excluded from backups
- `additional_parameters`: Extra server startup parameters
- `device`: Generated device ID used for environment safety checks

## Directory Structure
This script uses following structure to make it easier to manage:
```
./
├── start.sh                                        # Main script
├── core.jar                                        # Server core
├── config/                                         # Configuration directory
│       ├── version.cfg                             # Version configuration
│       └── server.properties                       # Server properties
├── bundles/                                        # Version and backup storage
│       └── [version]/
│               ├── core.zip                        # Server core package
│               ├── server.zip                      # Full server backup
│               ├── *.zip                           # Timestamped backups
│               └── worlds
│                       └── worlds_*.zip            # Timestamped world backups
├── plugins/                                        # Plugin directory
├── worlds/                                         # World data
├── logs/                                           # Server logs
├── eula.txt                                        # EULA agreement
└── task.lock                                       # Task lock file
```

## Advanced Features

### Smart Memory Allocation
- Automatic detection of system memory (including container limits)
- Allocate base memory by using formula: (29 * MAX + 8192) / 60, capped at 4GB
- Plugin-based memory calculation
- Player capacity estimation
- Container environment optimization

### Dependency-Aware Plugin Management
Automatically detects plugin dependencies, warns about potential impacts when disabling plugins, and supports automatic dependency chain disabling.

### Intelligent Java Detection
- Automatic discovery of Java installations
- Version compatibility checking
- Vendor identification (OpenJDK, Oracle, GraalVM, etc.)
- Custom Java path validation

### Task Safety System
- **Lock Mechanism**: Prevents multiple script instances
- **Interruption Recovery**: Resumes interrupted operations
- **Time Tracking**: Shows task duration and creation time
- **Process Validation**: Checks if locked processes are still running

### Smart Version Upgrades
Supports safe upgrades within major versions and cross-version upgrades in force mode (with warnings).

### Integrity Protection
All downloaded files are verified with MD5 checksums to ensure file integrity and security.

### Interactive Configuration
- Graphical-style text interface for server settings
- Real-time configuration preview
- Validation for all input parameters
- Batch editing support
- Smart auto selections

### Force Mode Operations
- `--version force` - Bypass version check and download latest script
- `--upgrade force` - Show all versions including incompatible ones

### Automatic Crash Analysis
- Automatically detect server crashes and abnormal exits
- Differentiate between intentional shutdowns and potential failure scenarios
- Scan logs to identify common issues such as memory exhaustion, plugin conflicts, and startup errors
- Generate readable crash analysis reports with server uptime and timestamps
- Prompt users for interactive analysis when suspicious log patterns are detected

## Troubleshooting

1. Python dependency errors
    - Ensure PyYAML is installed: pip install PyYAML

2. Java path issues
    - Use --init to reconfigure Java path
    - Ensure Java is properly installed

3. Port conflicts
    - Tool automatically detects port usage
    - Modify server-port in config/server.properties

4. Permission issues
    - Ensure script has execute permissions
    - Ensure read/write permissions for server directory

5. For more
    - Check the manager log at: ./logs/manager.log
    - You can also create a Issue at [here](https://github.com/Admin-SR40/MC-Server-Manager/issues/new)

## Wiki & Documentation
For detailed documentation, tutorials, and best practices, visit the [AI-Generated Wiki](https://deepwiki.com/Admin-SR40/MC-Server-Manager)

## License
This project is licensed under the **MIT** License. See [LICENSE file](https://github.com/Admin-SR40/MC-Server-Manager/blob/main/LICENSE) for details.

## Contributing
Issues and Pull Requests are welcome to improve this project.
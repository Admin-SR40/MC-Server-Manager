# Minecraft Server Manager

## Introduction
A powerful Minecraft server management tool written in Python, supporting Purpur server. This tool provides a comprehensive server management solution including version management, backup and recovery, plugin management, world reset, and more, making server administration simpler and more efficient.

## Key Features

### Server Management
- **One-Click Start**: Automatically configure and start Minecraft server
- **Version Management**: Download, switch, and manage multiple server versions
- **Auto Configuration**: Intelligent Java environment detection and configuration
- **Automatic EULA**: Automatically handle Mojang EULA agreement
- **Server Settings**: Interactive server configuration editor
- **Player Management**: Manage banned players, IPs, and whitelist
- **Task Locking**: Prevent duplicate instances and handle interrupted tasks

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
- **Selective Deletion**: Support single or multiple world deletion
- **World Status**: Display world size and corruption status

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

## System Requirements
- Python 3.8 or higher is recommended
- Java 8 or higher (for running Minecraft server)
- Dependencies: PyYAML
- Operating Systems: Windows, Linux, macOS
- Container Environments: Docker, Kubernetes (supported)

## Installation

1. Download the start.sh script to your server directory
2. Install required Python dependency:
    `pip install PyYAML`
3. Make the script executable if using Linux:
    `chmod +x start.sh`

## Command Reference

### Basic Commands
- `(no command)` - Start the server
- `--init` - Initialize server configuration manually
- `--init auto` - Automatic server configuration with intelligent defaults
- `--info` - Show current server configuration
- `--help` - Show help information
- `--version` - Check for script updates
- `--version force` - Force download latest script version
- `--license` - Show the open source license

### Version Management
- `--get` - Show available Purpur server versions
- `--get <version>` - Download specific Purpur server version
- `--list` - List all available versions in bundles
- `--new` - Create new server instance
- `--change <version>` - Switch to specified version
- `--upgrade` - Upgrade server core to compatible version
- `--upgrade force` - Force upgrade showing all versions
- `--delete <version>` - Delete specified version from bundles

### Backup Management
- `--save <version>` - Save current version to bundles
- `--backup` - Create timestamped backup of current version
- `--rollback` - Rollback to previous backup
- `--delete <version>` - Delete specified version

### Plugin Management
- `--plugins` - Manage plugins with dependency checking

### World Management
- `--reset` - Reset worlds and configure seeds

### Server Configuration
- `--settings` - Edit server properties and settings interactively
- `--players` - Manage banned players, banned IPs, and whitelist

### System Maintenance
- `--cleanup` - Clean up server files to free up space
- `--dump` - Create compressed dump of log files
- `--dump <search terms>` - Search and dump specific log content

## Configuration

Configuration file is located at `config/version.cfg` and includes:

- `version`: Minecraft server version
- `max_ram`: Maximum memory allocation (MB)
- `java_path`: Java executable path
- `additional_list`: Additional files/directories to exclude from backups
- `additional_parameters`: Additional server startup parameters

## Directory Structure

This script uses following structure to make it easier to manage:
```
./
├── start.sh # Main script
├── core.jar # Server core
├── config/ # Configuration directory
│       ├── version.cfg # Version configuration
│       └── server.properties # Server properties
├── bundles/ # Version and backup storage
│       └── [version]/
│               ├── core.zip # Server core package
│               ├── server.zip # Full server backup
│               └── *.zip # Timestamped backups
├── plugins/ # Plugin directory
├── worlds/ # World data
├── logs/ # Server logs
├── eula.txt # EULA agreement
└── task.lock # Task lock file
```

## Advanced Features

### Smart Memory Allocation
- Automatic detection of system memory (including container limits)
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

### Force Mode Operations
- `--version force` - Bypass version check and download latest script
- `--upgrade force` - Show all versions including incompatible ones

## Troubleshooting

### Common Issues

1. Python Dependency Errors
    - Ensure PyYAML is installed: pip install PyYAML

2. Java Path Issues

    - Use --init to reconfigure Java path
    - Ensure Java is properly installed

3. Port Conflicts
    - Tool automatically detects port usage
    - Modify server-port in config/server.properties

4. Permission Issues
    - Ensure script has execute permissions
    - Ensure read/write permissions for server directory

## Wiki & Documentation

For detailed documentation, tutorials, and best practices, visit the AI-Generated Wiki:
- [DeepWiki](https://deepwiki.com/Admin-SR40/MC-Server-Manager)

## License

This project is licensed under the **MIT** License. See LICENSE file for details.

## Contributing

Issues and Pull Requests are welcome to improve this project.
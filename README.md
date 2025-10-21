# Minecraft Server Manager

## Introduction
A powerful Minecraft server management tool written in Python, supporting Purpur server. This tool provides a comprehensive server management solution including version management, backup and recovery, plugin management, world reset, and more, making server administration simpler and more efficient.

## Key Features

### Server Management
- **One-Click Start**: Automatically configure and start Minecraft server
- **Version Management**: Download, switch, and manage multiple server versions
- **Auto Configuration**: Intelligent Java environment detection and configuration
- **Automatic EULA**: Automatically handle Mojang EULA agreement

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

### World Management
- **World Reset**: Safely delete and regenerate worlds
- **Seed Configuration**: Flexible world generation seed settings
- **Selective Deletion**: Support single or multiple world deletion

### Maintenance Tools
- **File Cleanup**: Automatically clean logs and temporary files to free disk space
- **Log Dumping**: Compress and archive server logs
- **Integrity Verification**: Automatic MD5 checksum verification for downloads
- **Self-Update**: Automatic script updates to latest version

### System Requirements
- Python 3.8 or higher is recommended
- Java 8 or higher (for running Minecraft server)
- Dependencies: PyYAML

## Installation

1. Download the start.sh script to your server directory
2. Install required Python dependency:
    `pip install PyYAML`
3. Make the script executable if using Linux:
    `chmod +x start.sh`

## Command Reference

### Basic Commands

- `--init` - Initialize server configuration
- `--info` - Show current server configuration
- `--help` - Show help information

### Version Management

- `--get` - Download Purpur server version
- `--list` - List all available versions
- `--new` - Create new server instance
- `--change` - Switch to specified version
- `--upgrade` - Upgrade server core

### Backup Management

- `--save` - Save current version
- `--backup` - Create timestamped backup
- `--rollback` - Rollback to previous backup
- `--delete` - Delete specified version

### Plugin Management

- `--plugins` - Manage plugins

### World Management

- `--reset` - Reset worlds and configure seeds

### System Maintenance

- `--cleanup` - Clean up server files

- `--dump` - Create log dump

- `--version` - Check and update script

## Configuration

Configuration file is located at `config/version.cfg` and includes:

- `version`: Minecraft server version
- `max_ram`: Maximum memory allocation (GB)
- `java_path`: Java executable path
- `additional_list`: Additional files/directories to exclude from backups
- `additional_parameters`: Additional server startup parameters

## Directory Structure

This scirpt uses following structure to make it easier to manage:
```
./
├── start.sh                 # Main script
├── core.jar                 # Server core
├── config/                  # Configuration directory
│   ├── version.cfg          # Version configuration
│   └── server.properties    # Server properties
├── bundles/                 # Version and backup storage
│   └── [version]/
│       ├── core.zip         # Server core package
│       └── *.zip            # Backup files
├── plugins/                 # Plugin directory
├── worlds/                  # World data
└── logs/                    # Server logs
```

## Advanced Features

### Dependency-Aware Plugin Management

Automatically detects plugin dependencies, warns about potential impacts when disabling plugins, and supports automatic dependency chain disabling.

### Smart Version Upgrades

Supports safe upgrades within major versions and cross-version upgrades in force mode (with warnings).

### Integrity Protection

All downloaded files are verified with MD5 checksums to ensure file integrity and security.

### Force Mode

Command `--version` and `--upgrade` supports force mode to bypass limitations.
Use `--version force` or `--upgrade force` to enable force mode.

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
#!/usr/bin/env python3

# Welcome!
#
# The script is open-source and available at:
#   https://github.com/Admin-SR40/MC-Server-Manager
#
# You can visit the wiki page to learn more about the script:
#   https://deepwiki.com/Admin-SR40/MC-Server-Manager
#
# The manager logging system is still in development.
# You can check the log file at:
#   ./logs/manager.log

import os
import sys
import shutil
import zipfile
import configparser
import subprocess
import glob
import re
import platform
import gzip
import datetime
import json
import urllib.request
import fnmatch
import hashlib
import socket
import time
import logging
from pathlib import Path

try:
    import yaml
except ImportError:
    print("\nError: PyYAML is not installed.\nPlease install it with: pip install PyYAML\n")
    sys.exit(1)

SCRIPT_VERSION = "6.3"
SERVER_START_TIME = None
SERVER_END_TIME = None
BASE_DIR = Path(os.getcwd())
CONFIG_FILE = BASE_DIR / "config" / "version.cfg"
BUNDLES_DIR = BASE_DIR / "bundles"
SCRIPT_NAME = Path(__file__).name
SERVER_JAR = BASE_DIR / "core.jar"
PLUGINS_DIR = BASE_DIR / "plugins"
WORLDS_DIR = BASE_DIR / "worlds"
SERVER_PROPERTIES = BASE_DIR / "config" / "server.properties"
EULA_FILE = BASE_DIR / "eula.txt"
LOCK_FILE = BASE_DIR / "task.lock"
LOG_DIR = BASE_DIR / "logs"
LOG_FILE = LOG_DIR / "manager.log"
BASE_EXCLUDE_LIST = [
    BUNDLES_DIR.name,
    SCRIPT_NAME,
    ".git",
    ".vscode",
    "__pycache__",
    "*.tmp",
    "*.log",
    "*.bak",
    "temp_rollback",
    "temp_save",
    "temp_backup",
    "temp_jar",
    "info.txt",
    "crash_*.txt",
    "crash-reports",
    "logs",
    ".DS_Store",
    "thumbs.db",
    "worlds/*/session.lock"
]

def setup_logger():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    if LOG_FILE.exists() and LOG_FILE.stat().st_size > 128 * 1024:
        try:
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H-%M-%S")
            archive_filename = f"{timestamp}.manager.log.gz"
            archive_path = LOG_DIR / archive_filename
            with open(LOG_FILE, 'rb') as f_in:
                with gzip.open(archive_path, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            with open(LOG_FILE, 'w') as f:
                f.truncate(0)
            logger.info(f"Log file rotated: {archive_filename} (original size: {LOG_FILE.stat().st_size} bytes)")
        except Exception as e:
            logger.warning(f"Warning: Failed to rotate log file: {e}")
    logger = logging.getLogger("mc-manager")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    logging.addLevelName(logging.INFO, "INFO ")
    logging.addLevelName(logging.WARNING, "WARN ")
    logging.addLevelName(logging.ERROR, "ERROR")
    formatter = logging.Formatter(
        fmt="%(asctime)s %(levelname)s > %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S"
    )
    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    return logger

def format_uptime_duration(seconds):
    if seconds < 0:
        return "Unknown"
    days = int(seconds // (24 * 3600))
    hours = int((seconds % (24 * 3600)) // 3600)
    minutes = int((seconds % 3600) // 60)
    seconds = int(seconds % 60)
    parts = []
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0:
        parts.append(f"{minutes}min")
    if seconds > 0 or not parts:
        parts.append(f"{seconds}s")
    return " ".join(parts)

def get_uptime():
    global SERVER_START_TIME, SERVER_END_TIME
    if not SERVER_START_TIME:
        return None, None, "Not started"
    end_time = SERVER_END_TIME if SERVER_END_TIME else time.time()
    uptime_seconds = end_time - SERVER_START_TIME
    uptime_str = format_uptime_duration(uptime_seconds)
    crash_time_str = time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(end_time))
    return uptime_seconds, uptime_str, crash_time_str

def get_device_id():
    try:
        hostname = socket.gethostname()
        logger.info(f"Generating device ID. Hostname: {hostname}")
        android_id = None
        try:
            result = subprocess.run(
                ['getprop', 'ro.serialno'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                android_id = result.stdout.strip()
                logger.info(f"Found Android serial number: {android_id}")
        except (subprocess.SubprocessError, FileNotFoundError) as e:
            logger.info(f"Could not get Android serial number: {e}")
            pass
        if not android_id:
            try:
                result = subprocess.run(
                    ['getprop', 'ro.product.model'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0 and result.stdout.strip():
                    model = result.stdout.strip()
                    logger.info(f"Found device model: {model}")
                    result2 = subprocess.run(
                        ['getprop', 'ro.product.manufacturer'],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=5
                    )
                    manufacturer = result2.stdout.strip() if result2.returncode == 0 else "unknown"
                    logger.info(f"Found device manufacturer: {manufacturer}")
                    android_id = f"{manufacturer}:{model}"
                    logger.info(f"Created device ID from model and manufacturer: {android_id}")
            except (subprocess.SubprocessError, FileNotFoundError) as e:
                logger.info(f"Could not get device model/manufacturer: {e}")
                pass
        if not android_id:
            android_id = hostname
            logger.info(f"Using hostname as device identifier: {android_id}")
        device_str = f"{hostname}:{android_id}"
        device_hash = hashlib.md5(device_str.encode()).hexdigest()
        logger.info(f"Generated device hash: {device_hash} from string: {device_str}")
        return device_hash
    except Exception as e:
        logger.error(f"Could not generate stable device ID: {e}")
        print(f"Warning: Could not generate stable device ID: {e}")
        print(" - Using 'unknown' as device identifier")
        return "unknown"

def check_environment_change():
    read_only_commands = ["--help", "--license", "--info", "--list"]
    is_read_only_command = len(sys.argv) > 1 and sys.argv[1] in read_only_commands
    is_init_command = len(sys.argv) > 1 and sys.argv[1] == "--init"
    if is_read_only_command or is_init_command:
        logger.info(f"Skipping environment check for read-only or init command: {sys.argv[1] if len(sys.argv) > 1 else 'none'}")
        return True
    if not CONFIG_FILE.exists():
        logger.info("Configuration file not found, skipping environment check")
        return True
    try:
        config = configparser.ConfigParser()
        config.read(CONFIG_FILE)
        if "SERVER" not in config or "device" not in config["SERVER"]:
            logger.warning("No device identification data found in configuration")
            print("\n" + "=" * 62)
            print("              ENVIRONMENT CHECK - NO DEVICE DATA")
            print("=" * 62)
            print("\nWarning: No device identification data found in configuration.")
            print("This might be the first run or the configuration was created")
            print("with an older version of the script.")
            print("\nIt is recommended to run --init or --init auto to ensure")
            print("proper environment detection in the future.")
            choice = input("\nContinue anyway? (Y/N): ").strip().upper()
            if choice != 'Y':
                logger.info("User chose to exit due to missing device data")
                print("Exiting script...\n")
                sys.exit(0)
            logger.info("User chose to continue despite missing device data")
            return True
        stored_device_id = config["SERVER"]["device"]
        current_device_id = get_device_id()
        logger.info(f"Stored device ID: {stored_device_id}, Current device ID: {current_device_id}")
        if stored_device_id == "unknown" or current_device_id == "unknown":
            logger.warning("Limited device identification detected")
            print("\n" + "=" * 61)
            print("                LIMITED ENVIRONMENT DETECTION")
            print("=" * 61)
            print("\nNote: Running on a system with limited device identification.")
            print("Environment change detection is disabled for this session.")
            print("\nIf you're experiencing issues, consider running --init again")
            print("to refresh the configuration.")
            print("\nContinuing with normal operation...\n")
            return True
        if stored_device_id == current_device_id:
            logger.info("Device ID matches, environment unchanged")
            return True
        logger.warning(f"Environment change detected! Stored: {stored_device_id}, Current: {current_device_id}")
        print("\n" + "=" * 61)
        print("                 ENVIRONMENT CHANGE DETECTED")
        print("=" * 61)
        print("\nWarning: The running environment has changed!")
        print("This script was previously run on a different machine or")
        print("the system configuration has been modified.")
        print("\nThis could indicate:")
        print(" - Running on a different computer")
        print(" - Virtual machine migration")
        print(" - Network/hardware changes")
        print(" - System reinstallation")
        print("\nIt is strongly recommended to reconfigure the server")
        print("for the new environment to avoid potential issues.")
        while True:
            print("\nAvailable options:")
            print(" 1. Backup current configuration and run --init")
            print(" 2. Backup current configuration and run --init auto") 
            print(" 3. Ignore the warning and continue")
            print(" 4. Exit without making any changes")
            choice = input("\nEnter your choice (1-4): ").strip()
            if choice == "1":
                logger.info("User chose to backup config and run --init")
                return handle_environment_change("manual")
            elif choice == "2":
                logger.info("User chose to backup config and run --init auto")
                return handle_environment_change("auto")
            elif choice == "3":
                logger.info("User chose to ignore warning and continue")
                return update_device_id_and_continue()
            elif choice == "4":
                logger.info("User chose to exit without changes")
                print("Exiting script...\n")
                sys.exit(0)
            else:
                logger.warning(f"Invalid user choice in environment change menu: {choice}")
                print("Invalid choice. Please enter 1, 2, 3, or 4.")
    except Exception as e:
        logger.error(f"Error during environment check: {e}")
        print(f"Error during environment check: {e}")
        print("Continuing with normal operation...")
        return True

def handle_environment_change(init_type):
    try:
        logger.info(f"Handling environment change with init type: {init_type}")
        if CONFIG_FILE.exists():
            backup_file = CONFIG_FILE.with_suffix('.cfg.bak')
            logger.info(f"Attempting to backup configuration file to: {backup_file}")
            try:
                shutil.copy2(CONFIG_FILE, backup_file)
                logger.info(f"Configuration backed up successfully to: {backup_file}")
                print(f"\nConfiguration backed up to: {backup_file}")
            except Exception as backup_error:
                logger.error(f"Failed to backup configuration file: {backup_error}")
                print(f"Warning: Could not backup configuration: {backup_error}")
        if init_type == "manual":
            logger.info("Starting manual initialization...")
            print("Running manual initialization...")
            init_config()
        else:
            logger.info("Starting auto initialization...")
            print("Running auto initialization...")
            init_config_auto()
        logger.info("Environment configuration completed successfully")
        print("Environment configuration completed successfully!")
        print("Please run the script again to start the server.\n")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Error during environment change handling: {e}", exc_info=True)
        print(f"Error during environment change handling: {e}")
        print("Falling back to normal operation...")
        return True

def update_device_id_and_continue():
    try:
        if CONFIG_FILE.exists():
            config = configparser.ConfigParser()
            config.read(CONFIG_FILE)
            if "SERVER" not in config:
                config["SERVER"] = {}
            current_device_id = get_device_id()
            config["SERVER"]["device"] = current_device_id
            with open(CONFIG_FILE, "w") as f:
                config.write(f)
            print("\nDevice ID updated to current environment.")
            print("Continuing with normal operation...\n")
        return True
    except Exception as e:
        print(f"Error updating device ID: {e}")
        print("Continuing with normal operation...")
        return True

def is_process_running(pid):
    try:
        if platform.system() == "Windows":
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5
            )
            return str(pid) in result.stdout
        else:
            os.kill(pid, 0)
            return True
    except (OSError, subprocess.TimeoutExpired, subprocess.SubprocessError):
        return False

def edit_server_settings():
    if not SERVER_PROPERTIES.exists():
        logger.error("Server properties file not found")
        print("\n" + "=" * 50)
        print("          Server Configuration Editor")
        print("=" * 50)
        print("\nError: server.properties file not found!")
        print("Please start the server at least once to generate the file.")
        print("")
        return
    logger.info("Starting server configuration editor")
    print("\n" + "=" * 50)
    print("          Server Configuration Editor")
    print("=" * 50)
    properties = {}
    try:
        logger.info(f"Reading server properties from: {SERVER_PROPERTIES}")
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    if '=' in line:
                        key, value = line.split('=', 1)
                        properties[key.strip()] = value.strip()
        logger.info(f"Successfully read {len(properties)} properties from server.properties")
    except Exception as e:
        logger.error(f"Error reading server.properties: {e}")
        print(f"Error reading server.properties: {e}")
        return
    settings_config = [
        {
            'key': 'online-mode',
            'name': 'Online Mode',
            'type': 'boolean',
            'default': 'true',
            'description': 'Verify player authentication with Mojang'
        },
        {
            'key': 'white-list',
            'name': 'Whitelist',
            'type': 'boolean', 
            'default': 'false',
            'description': 'Enable whitelist to restrict server access'
        },
        {
            'key': 'enable-command-block',
            'name': 'Command Blocks',
            'type': 'boolean',
            'default': 'false',
            'description': 'Enable command blocks in the world'
        },
        {
            'key': 'allow-flight',
            'name': 'Allow Flight',
            'type': 'boolean',
            'default': 'false',
            'description': 'Allow players to fly in survival mode'
        },
        {
            'key': 'hardcore',
            'name': 'Hardcore Mode',
            'type': 'boolean', 
            'default': 'false',
            'description': 'Enable hardcore mode (permanent death)'
        },
        {
            'key': 'pvp',
            'name': 'PVP',
            'type': 'boolean',
            'default': 'true',
            'description': 'Allow player vs player combat'
        },
        {
            'key': 'server-port',
            'name': 'Server Port',
            'type': 'int',
            'range': (0, 65535),
            'default': '25565',
            'description': 'The port the server will listen on'
        },
        {
            'key': 'op-permission-level',
            'name': 'OP Permission Level',
            'type': 'int',
            'range': (0, 4),
            'default': '4',
            'description': 'Permission level for server operators'
        },
        {
            'key': 'function-permission-level',
            'name': 'Function Permission Level', 
            'type': 'int',
            'range': (0, 4),
            'default': '2',
            'description': 'Permission level for functions'
        },
        {
            'key': 'max-players',
            'name': 'Max Players',
            'type': 'int',
            'range': (1, 9999),
            'default': '20',
            'description': 'Maximum number of players allowed'
        },
        {
            'key': 'view-distance',
            'name': 'View Distance',
            'type': 'int',
            'range': (2, 32),
            'default': '10',
            'description': 'Maximum view distance in chunks'
        },
        {
            'key': 'difficulty',
            'name': 'Difficulty',
            'type': 'enum',
            'options': ['peaceful', 'easy', 'normal', 'hard'],
            'default': 'easy',
            'description': 'Game difficulty level'
        },
        {
            'key': 'level-seed',
            'name': 'World Seed',
            'type': 'string',
            'default': '',
            'description': 'Seed for world generation'
        },
        {
            'key': 'motd',
            'name': 'MOTD',
            'type': 'string',
            'default': 'A Minecraft Server',
            'description': 'Server description shown in server list'
        }
    ]
    logger.info("Entering server configuration editor loop")
    edited_settings = []
    while True:
        print("\n                    - Server Configuration -")
        print("╔" + "═" * 35 + "╦" + "═" * 26 + "╗")
        print("║ Settings".ljust(35) + " ║ Value".ljust(25) + "   ║")
        print("╠" + "═" * 35 + "╬" + "═" * 26 + "╣")
        for i, setting in enumerate(settings_config, 1):
            key = setting['key']
            current_value = properties.get(key, setting['default'])
            if not current_value and setting['type'] == 'string':
                current_value = "(empty)"
            name_display = f"{i}. {setting['name']}"
            value_display = str(current_value)
            if len(name_display) > 34:
                name_display = name_display[:31] + "..."
            if len(value_display) > 24:
                value_display = value_display[:21] + "..."
            print(f"║ {name_display.ljust(34)}║ {value_display.ljust(24)} ║")
        print("╚" + "═" * 35 + "╩" + "═" * 26 + "╝")
        print("\nEnter a number to edit settings (or press Enter to exit)")
        try:
            choice = input("\nYour choice: ").strip()
            if not choice:
                logger.info("User exited configuration editor")
                print("Exiting configuration editor.\n")
                break
            index = int(choice) - 1
            if index < 0 or index >= len(settings_config):
                logger.warning(f"Invalid selection: {choice}")
                print("Invalid selection. Please choose a valid number.")
                continue
            setting = settings_config[index]
            key = setting['key']
            current_value = properties.get(key, setting['default'])
            logger.info(f"User editing setting: {setting['name']} ({key}), current value: {current_value}")
            print(f"\nEditing: {setting['name']}")
            print(f"\nDescription: {setting['description']}")
            print(f"Current value: {current_value if current_value else '(empty)'}")
            old_value = current_value
            new_value = None
            if setting['type'] == 'boolean':
                print("\nOptions:")
                print("1. Enable (true)")
                print("2. Disable (false)")
                while True:
                    bool_choice = input("\nSelect option (1/2): ").strip()
                    if not bool_choice:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print("Cancelled editing.\n")
                        break
                    if bool_choice == '1':
                        new_value = 'true'
                        break
                    elif bool_choice == '2':
                        new_value = 'false'
                        break
                    else:
                        logger.warning(f"Invalid boolean choice: {bool_choice}")
                        print("Invalid choice. Please enter 1 or 2.")
                if bool_choice:
                    properties[key] = new_value
                    logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                    edited_settings.append(f"{setting['name']}: {old_value} -> {new_value}")
                    print(f" - {setting['name']} set to: {new_value}")
            elif setting['type'] == 'int':
                min_val, max_val = setting['range']
                print(f"\nValid range: {min_val} - {max_val}")
                while True:
                    int_input = input("\nEnter new value: ").strip()
                    if not int_input:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print("Cancelled editing.\n")
                        break
                    try:
                        int_value = int(int_input)
                        if min_val <= int_value <= max_val:
                            new_value = str(int_value)
                            properties[key] = new_value
                            if key == 'view-distance':
                                properties['simulation-distance'] = new_value
                                logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}, simulation-distance also set to {new_value}")
                                edited_settings.append(f"{setting['name']}: {old_value} -> {new_value} (simulation-distance also updated)")
                                print(f" - {setting['name']} set to: {int_value}")
                                print(f" - simulation-distance also set to: {int_value}")
                            else:
                                logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                                edited_settings.append(f"{setting['name']}: {old_value} -> {new_value}")
                                print(f" - {setting['name']} set to: {int_value}")
                            break
                        else:
                            logger.warning(f"Value out of range: {int_value}, allowed: {min_val}-{max_val}")
                            print(f"Value must be between {min_val} and {max_val}.")
                    except ValueError:
                        logger.warning(f"Invalid integer input: {int_input}")
                        print("Please enter a valid number.")
            elif setting['type'] == 'enum':
                print("\nAvailable options:")
                for j, option in enumerate(setting['options'], 1):
                    print(f"{j}. {option}")
                while True:
                    enum_choice = input("\nSelect option: ").strip()
                    if not enum_choice:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print("Cancelled editing.\n")
                        break
                    try:
                        option_index = int(enum_choice) - 1
                        if 0 <= option_index < len(setting['options']):
                            new_value = setting['options'][option_index]
                            properties[key] = new_value
                            logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                            edited_settings.append(f"{setting['name']}: {old_value} -> {new_value}")
                            print(f" - {setting['name']} set to: {new_value}")
                            break
                        else:
                            logger.warning(f"Invalid enum index: {option_index}, allowed: 0-{len(setting['options'])-1}")
                            print(f"Please enter a number between 1 and {len(setting['options'])}")
                    except ValueError:
                        logger.warning(f"Invalid enum input: {enum_choice}")
                        print("Please enter a valid number.")
            elif setting['type'] == 'string':
                string_input = input("\nEnter new value: ").strip()
                if not string_input:
                    logger.info(f"User cancelled editing {setting['name']}")
                    print("Cancelled editing.\n")
                else:
                    new_value = string_input
                    properties[key] = new_value
                    logger.info(f"Setting changed: {setting['name']} from '{old_value}' to '{new_value}'")
                    edited_settings.append(f"{setting['name']}: '{old_value}' -> '{new_value}'")
                    print(f" - {setting['name']} set to: {string_input}")
            try:
                logger.info("Saving updated server properties")
                with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                updated_lines = []
                found_keys = set()
                for line in lines:
                    stripped_line = line.strip()
                    if stripped_line and not stripped_line.startswith('#'):
                        if '=' in stripped_line:
                            line_key = stripped_line.split('=', 1)[0].strip()
                            if line_key in properties:
                                updated_lines.append(f"{line_key}={properties[line_key]}\n")
                                found_keys.add(line_key)
                                continue
                    updated_lines.append(line)
                for prop_key, prop_value in properties.items():
                    if prop_key not in found_keys:
                        updated_lines.append(f"{prop_key}={prop_value}\n")
                with open(SERVER_PROPERTIES, 'w', encoding='utf-8') as f:
                    f.writelines(updated_lines)
                logger.info("Configuration saved successfully")
                print("\nConfiguration saved successfully!")
            except Exception as e:
                logger.error(f"Error saving configuration: {e}")
                print(f"\nError saving configuration: {e}\n")
        except ValueError:
            logger.warning(f"Invalid input (not a number): {choice}")
            print("Please enter a valid number.")
        except KeyboardInterrupt:
            logger.warning("Configuration editor interrupted by user")
            print("\n\nOperation cancelled by user.\n")
            break
        except Exception as e:
            logger.error(f"Unexpected error in configuration editor: {e}")
            print(f"\nUnexpected error: {e}\n")
    if edited_settings:
        logger.info(f"Configuration editor completed. Changes made: {len(edited_settings)}")
        logger.info("Changes list: " + ", ".join(edited_settings))
    else:
        logger.info("Configuration editor completed with no changes")

def show_license():
    print("\n" + "=" * 51)
    print("                License Information")
    print("=" * 51)
    logger.info("Starting license information retrieval")
    print("\nFetching license...")
    license_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/LICENSE"
    logger.info(f"Attempting to fetch license from: {license_url}")
    try:
        logger.info(f"Opening URL connection to: {license_url}")
        with urllib.request.urlopen(license_url, timeout=10) as response:
            logger.info(f"HTTP response received - Status: {response.status}")
            license_content = response.read().decode('utf-8')
            license_length = len(license_content)
            logger.info(f"Successfully retrieved license content ({license_length} bytes)")
            print("\nCurrent license:")
            print("=" * 51)
            print(license_content)
            print("=" * 51)
            print("")
            logger.info("License displayed successfully")
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching license - HTTP {e.code}: {e.reason}")
        print(f"\nError: Could not fetch license - HTTP {e.code}")
        print("The license file may not be available at the moment.\n")
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching license - {e.reason}")
        print(f"\nError: Could not connect to server - {e.reason}")
        print("Please check your internet connection and try again.\n")
    except socket.timeout as e:
        logger.error(f"Timeout error fetching license - Connection timed out after 10 seconds")
        print(f"\nError: Connection timeout while fetching license")
        print("The request took too long. Please check your internet connection and try again.\n")
    except Exception as e:
        logger.error(f"Unexpected error fetching license - {type(e).__name__}: {e}")
        print(f"\nError: Failed to retrieve license - {e}")
        print("")

def format_uuid(uuid_str):
    if len(uuid_str) == 32 and '-' not in uuid_str:
        return f"{uuid_str[:8]}-{uuid_str[8:12]}-{uuid_str[12:16]}-{uuid_str[16:20]}-{uuid_str[20:32]}"
    return uuid_str

def get_mojang_uuid(username):
    logger.info(f"Fetching Mojang UUID for username: {username}")
    try:
        url = f"https://api.mojang.com/users/profiles/minecraft/{username}"
        logger.info(f"Making API request to: {url}")
        with urllib.request.urlopen(url, timeout=10) as response:
            logger.info(f"API response received - Status: {response.status}")
            data = json.loads(response.read().decode())
            uuid = data.get("id")
            actual_name = data.get("name", username)
            if uuid:
                formatted_uuid = format_uuid(uuid)
                logger.info(f"Successfully fetched UUID for '{username}': {formatted_uuid}, name: {actual_name}")
                return formatted_uuid, actual_name
            else:
                logger.warning(f"No UUID found in API response for username: {username}")
                return None, username                
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching UUID for '{username}' - HTTP {e.code}: {e.reason}")
        return None, username
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching UUID for '{username}' - {e.reason}")
        return None, username
    except socket.timeout as e:
        logger.error(f"Timeout error fetching UUID for '{username}' - Connection timed out")
        return None, username
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error fetching UUID for '{username}' - {e}")
        return None, username
    except Exception as e:
        logger.error(f"Unexpected error fetching UUID for '{username}' - {type(e).__name__}: {e}")
        return None, username

def is_online_mode():
    if not SERVER_PROPERTIES.exists():
        logger.warning("server.properties file not found, using default online-mode=true")
        return True
    try:
        logger.info("Checking online-mode in server.properties")
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip().startswith('online-mode='):
                    value = line.split('=', 1)[1].strip().lower()
                    is_online = value == 'true'
                    logger.info(f"Online mode setting found: {value} -> is_online={is_online}")
                    return is_online
        logger.info("Online mode setting not found in server.properties, using default (true)")
        return True
    except Exception as e:
        logger.error(f"Error reading online-mode from server.properties: {e}")
        print(f"Error reading server.properties: {e}")
        return True

def format_list_table(items, list_type):
    if not items:
        if list_type == "banned-ips":
            return "                          - Banned IPs -\n╔═════════════════════════════════════════════════════════════╗\n║                                                             ║\n║                      No banned IPs found.                   ║\n║                                                             ║\n╚═════════════════════════════════════════════════════════════╝"
        elif list_type == "banned-players":
            return "                        - Banned Players -\n╔════════════════════════════════════════════════════════════════╗\n║                                                                ║\n║                    No banned players found.                    ║\n║                                                                ║\n╚════════════════════════════════════════════════════════════════╝"
        else:
            return "                          - Whitelist -    \n╔════════════════════════════════════════════════════════════════╗\n║                                                                ║\n║                 No whitelisted players found.                  ║\n║                                                                ║\n╚════════════════════════════════════════════════════════════════╝"
    if list_type == "banned-ips":
        name_width = 20
        reason_width = 40
        table = []
        table.append("                          - Banned IPs -")
        table.append("╔" + "═" * name_width + "╦" + "═" * reason_width + "╗")
        table.append("║" + " IP Address".ljust(name_width-1) + " ║" + " Reason".ljust(reason_width-1) + " ║")
        table.append("╠" + "═" * name_width + "╬" + "═" * reason_width + "╣")
        for i, item in enumerate(items, 1):
            ip = item.get("ip", "Unknown")
            reason = item.get("reason", "No reason")
            ip_display = truncate_text(f"{i}. {ip}", name_width-1)
            reason_display = truncate_text(reason, reason_width-1)
            row = (f"║ {ip_display.ljust(name_width-1)}"
                   f"║ {reason_display.ljust(reason_width-1)}║")
            table.append(row)
        table.append("╚" + "═" * name_width + "╩" + "═" * reason_width + "╝")
    else:
        name_width = 25
        uuid_width = 38
        table = []
        if list_type == "banned-players":
            table.append("                        - Banned Players -")
        else:
            table.append("                          - Whitelist -")
        table.append("╔" + "═" * name_width + "╦" + "═" * uuid_width + "╗")
        table.append("║" + " Player Name".ljust(name_width-1) + " ║" + " UUID".ljust(uuid_width-1) + " ║")
        table.append("╠" + "═" * name_width + "╬" + "═" * uuid_width + "╣")
        for i, item in enumerate(items, 1):
            name = item.get("name", "Unknown")
            uuid = item.get("uuid", "Unknown")
            name_display = truncate_text(f"{i}. {name}", name_width-1)
            uuid_display = truncate_text(uuid, uuid_width-1)
            row = (f"║ {name_display.ljust(name_width-1)}"
                   f"║ {uuid_display.ljust(uuid_width-1)}║")
            table.append(row)
        table.append("╚" + "═" * name_width + "╩" + "═" * uuid_width + "╝")
    return "\n".join(table)

def manage_player_lists():
    logger.info("Starting player list management")
    print("\n" + "=" * 50)
    print("              Player List Management")
    print("=" * 50)
    print("\nSelect list to manage:")
    print(" 1. Banned Players (banned-players.json)")
    print(" 2. Banned IPs (banned-ips.json)")
    print(" 3. Whitelist (whitelist.json)")
    print("")
    try:
        choice = input("Enter your choice (1-3) or press Enter to exit: ").strip()
        if not choice:
            logger.info("User exited player list management without selection")
            print("")
            return
        list_choice = int(choice)
        if list_choice not in [1, 2, 3]:
            logger.warning(f"Invalid list choice: {choice}")
            print("Invalid choice.\n")
            return
        list_files = {
            1: "banned-players.json",
            2: "banned-ips.json", 
            3: "whitelist.json"
        }
        list_names = {
            1: "banned-players",
            2: "banned-ips",
            3: "whitelist"
        }
        selected_file = list_files[list_choice]
        selected_type = list_names[list_choice]
        file_path = BASE_DIR / selected_file
        logger.info(f"User selected list: {selected_type} ({selected_file})")
        items = []
        if file_path.exists():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    items = json.load(f)
                if not isinstance(items, list):
                    items = []
                logger.info(f"Loaded {len(items)} items from {selected_file}")
            except Exception as e:
                logger.error(f"Error reading {selected_file}: {e}")
                items = []
        else:
            logger.info(f"File {selected_file} does not exist, starting with empty list")
        print("\n" + format_list_table(items, selected_type))
        print("\nAvailable operations:")
        print(" A - Add new entry")
        if items:
            print(" D - Delete existing entry")
        print("")
        op_choice = input("Enter operation (A/D) or press Enter to exit: ").strip().upper()
        if not op_choice:
            logger.info("User exited without selecting operation")
            print("")
            return
        if op_choice == 'A':
            logger.info(f"User chose to add entry to {selected_type}")
            add_to_list(items, selected_type, file_path)
        elif op_choice == 'D':
            if items:
                logger.info(f"User chose to delete entry from {selected_type}")
                delete_from_list(items, selected_type, file_path)
            else:
                logger.info(f"Attempted to delete from empty {selected_type} list")
                print("No entries to delete.\n")
        else:
            logger.warning(f"Invalid operation choice: {op_choice}")
            print("Invalid operation.\n")
    except ValueError:
        logger.error("Invalid input in player list management - expected number")
        print("Invalid input. Please enter a number.\n")
    except Exception as e:
        logger.error(f"Error in player list management: {e}")
        print(f"Error: {e}\n")

def delete_from_list(items, list_type, file_path):
    logger.info(f"Starting delete operation on {list_type}")
    if not items:
        logger.warning(f"Attempted to delete from empty {list_type} list")
        print(f"\n{list_type} is empty. Nothing to delete.\n")
        return
    print(f"\nDeleting from {list_type}...")
    try:
        selection = input("Enter the number(s) to delete (space-separated): ").strip()
        if not selection:
            logger.info("User cancelled delete operation")
            print("Operation cancelled.\n")
            return
        indices = [int(i.strip()) for i in selection.split()]
        indices.sort(reverse=True)
        valid_indices = [i for i in indices if 1 <= i <= len(items)]
        if not valid_indices:
            logger.warning(f"No valid indices in delete selection: {selection}")
            print("No valid numbers selected.\n")
            return
        logger.info(f"User selected indices for deletion: {valid_indices}")
        print("\nThe following entries will be deleted:")
        entries_to_delete = []
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                entry_info = f"IP: {item.get('ip', 'Unknown')}"
            else:
                entry_info = f"{item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})"
            entries_to_delete.append(entry_info)
            print(f" - {entry_info}")
        logger.info(f"Entries to delete: {', '.join(entries_to_delete)}")
        confirm = input("\nAre you sure? (Y/N): ").strip().upper()
        if confirm != 'Y':
            logger.info("User cancelled deletion after confirmation")
            print("Deletion cancelled.\n")
            return
        logger.info("User confirmed deletion")
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                entry_info = item.get('ip', 'Unknown')
            else:
                entry_info = f"{item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})"
            logger.info(f"Deleting entry: {entry_info}")
            del items[idx-1]
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        logger.info(f"Successfully deleted {len(valid_indices)} entries from {list_type}")
        print(f"\nSuccessfully deleted {len(valid_indices)} entries from {list_type}!\n")        
    except ValueError:
        logger.error("Invalid input in delete operation - expected numbers separated by spaces")
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
        logger.error(f"Error deleting from {list_type}: {e}")
        print(f"Error deleting from {list_type}: {e}\n")

def add_to_list(items, list_type, file_path):
    logger.info(f"Starting add operation to {list_type}")
    print(f"\nAdding to {list_type}...")
    if list_type == "banned-ips":
        while True:
            ip = input("Enter IP address to ban: ").strip()
            if not ip:
                logger.info("User cancelled IP ban addition")
                print("Operation cancelled.\n")
                return
            if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip):
                logger.info(f"Valid IP address entered: {ip}")
                break
            else:
                logger.warning(f"Invalid IP address format: {ip}")
                print("Invalid IP address format. Please try again.")
        reason = input("Enter ban reason (optional): ").strip() or "Banned by an operator."
        logger.info(f"Ban reason: {reason}")
        new_entry = {
            "ip": ip,
            "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
            "source": "Server",
            "expires": "forever",
            "reason": reason
        }
        items.append(new_entry)
        logger.info(f"Added IP ban entry: {ip} with reason: {reason}")
    else:
        online_mode = is_online_mode()
        if not online_mode and list_type in ["banned-players", "whitelist"]:
            logger.warning(f"Server in offline mode, cannot add to {list_type}")
            print("\nWARNING: Server is in offline mode (online-mode=false).")
            print("Cannot add players to this list because UUID generation")
            print("differs between online and offline modes.")
            print("You can only remove existing entries in offline mode.")
            print("You can use in-game commands to add players instead.\n")
            return
        while True:
            username = input("Enter player username: ").strip()
            if not username:
                logger.info("User cancelled player addition")
                print("Operation cancelled.\n")
                return
            if len(username) > 20:
                logger.warning(f"Username too long: {username}")
                print("Username too long (max 20 characters). Please try again.")
                continue
            logger.info(f"Fetching UUID for username: {username}")
            print(f"Fetching UUID for {username}...")
            uuid, actual_name = get_mojang_uuid(username)
            if not uuid:
                logger.error(f"Could not fetch UUID for username: {username}")
                print(f"Error: Could not fetch UUID for '{username}'.")
                print("Please check the username and try again.")
                continue
            logger.info(f"Successfully fetched UUID for {username}: {uuid}")
            print(f"Found: {actual_name} -> {uuid}")
            break
        if list_type == "banned-players":
            reason = input("Enter ban reason (optional): ").strip() or "Banned by an operator."
            logger.info(f"Ban reason: {reason}")
            new_entry = {
                "uuid": uuid,
                "name": actual_name,
                "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
                "source": "Server",
                "expires": "forever",
                "reason": reason
            }
            items.append(new_entry)
            logger.info(f"Added player ban entry: {actual_name} ({uuid}) with reason: {reason}")
        else:
            new_entry = {
                "uuid": uuid,
                "name": actual_name
            }
            items.append(new_entry)
            logger.info(f"Added whitelist entry: {actual_name} ({uuid})")
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        logger.info(f"Successfully saved {list_type} to {file_path}")
        print(f"\nSuccessfully added to {list_type}!\n")
    except Exception as e:
        logger.error(f"Error saving {list_type}: {e}")
        print(f"Error saving {list_type}: {e}\n")

def create_lock(command):
    logger.info(f"Attempting to create lock for command: {' '.join(command)}")
    try:
        with open(LOCK_FILE, 'w', encoding='utf-8') as f:
            f.write(f"Command: {' '.join(command)}\n")
            f.write(f"Timestamp: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"PID: {os.getpid()}\n")
        logger.info(f"Lock created successfully at {LOCK_FILE}")
        logger.info(f"Lock details - Command: {' '.join(command)}, PID: {os.getpid()}")
        return True        
    except Exception as e:
        logger.error(f"Error creating lock file: {e}")
        print(f"\nError creating lock file: {e}\n")
        return False

def remove_lock():
    try:
        if LOCK_FILE.exists():
            logger.info(f"Attempting to remove lock file: {LOCK_FILE}")
            LOCK_FILE.unlink()
        else:
            logger.info("Lock file does not exist, nothing to remove")
        return True
    except Exception as e:
        logger.error(f"Error removing lock file: {e}")
        print(f"\nError removing lock file: {e}\n")
        return False

def check_lock():
    if not LOCK_FILE.exists():
        logger.info("No lock file found")
        return None
    try:
        logger.info(f"Checking lock file: {LOCK_FILE}")
        with open(LOCK_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
        command_match = re.search(r'Command:\s*(.+)', content)
        pid_match = re.search(r'PID:\s*(\d+)', content)
        timestamp_match = re.search(r'Timestamp:\s*(.+)', content)
        if not command_match:
            logger.warning("Lock file exists but no command found, assuming invalid lock")
            return None
        command_line = command_match.group(1).strip()
        pid = int(pid_match.group(1)) if pid_match else None
        lock_time = None
        if timestamp_match:
            try:
                time_str = timestamp_match.group(1).strip()
                lock_time = datetime.datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S')
                logger.info(f"Parsed lock timestamp: {time_str}")
            except ValueError:
                try:
                    lock_time = datetime.datetime.fromtimestamp(os.path.getctime(LOCK_FILE))
                    logger.info(f"Using file creation time as lock timestamp: {lock_time}")
                except:
                    lock_time = None
                    logger.warning("Could not determine lock timestamp")
        if lock_time is None:
            try:
                lock_time = datetime.datetime.fromtimestamp(os.path.getctime(LOCK_FILE))
                logger.info(f"Using file creation time as fallback timestamp: {lock_time}")
            except:
                lock_time = datetime.datetime.now()
                logger.warning("Using current time as fallback lock timestamp")
        is_running = pid and is_process_running(pid)
        lock_info = {
            'command': command_line.split(),
            'pid': pid,
            'is_running': is_running,
            'timestamp': lock_time
        }
        logger.info(f"Lock info - Command: {command_line}, PID: {pid}, "
                   f"Is running: {is_running}, Timestamp: {lock_time}")
        if is_running:
            logger.warning(f"Process {pid} is still running, duplicate instance detected")
        else:
            logger.warning(f"Process {pid} is not running, pending task detected")
        return lock_info
    except Exception as e:
        logger.error(f"Error reading lock file: {e}")
        print(f"\nError reading lock file: {e}\n")
        return None

def format_time_duration(start_time):
    now = datetime.datetime.now()
    duration = now - start_time
    total_seconds = int(duration.total_seconds())
    days = total_seconds // (24 * 3600)
    hours = (total_seconds % (24 * 3600)) // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    if days > 0:
        return f"{days}d {hours}h {minutes}m {seconds}s"
    elif hours > 0:
        return f"{hours}h {minutes}m {seconds}s"
    elif minutes > 0:
        return f"{minutes}m {seconds}s"
    else:
        return f"{seconds}s"

def handle_pending_task():
    logger.info("Checking for pending tasks...")
    lock_info = check_lock()
    if not lock_info:
        return False
    print("\n" + "=" * 51)
    lock_time = lock_info['timestamp']
    time_duration = format_time_duration(lock_time)
    time_str = lock_time.strftime("%Y-%m-%d %H:%M:%S")
    if lock_info['is_running']:
        logger.warning(f"Duplicate instance detected - PID: {lock_info['pid']}, Command: {' '.join(lock_info['command'])}, "
                      f"Lock created at: {time_str}, Running for: {time_duration}")
        print("            DUPLICATE INSTANCE DETECTED")
        print("=" * 51)
        print(f"\nAnother instance of the script is already running:")
        print(f" - PID: {lock_info['pid']}")
        print(f" - Command: {lock_info['command']}")
        print(f" - Lock created at: {time_str}")
        print(f" - Task running for: {time_duration}")
        print("\nYou cannot run multiple instances simultaneously.")
        print("Please wait for the current operation to complete.")
        while True:
            print("\nYou have the following options:")
            print(" Q - Quit this instance")
            print(" F - Force clear the lock and continue")
            print("\nForcing may cause data corruption if the other")
            print("instance is actively modifying server files!")
            choice = input("\nEnter your choice (Q/F): ").strip().upper()
            if choice == 'Q':
                logger.info("User chose to quit due to duplicate instance")
                print("\nExiting script...\n")
                sys.exit(0)
            elif choice == 'F':
                logger.warning("User chose to force clear lock - requesting confirmation")
                confirm = input("\nAre you sure? This may cause DATA CORRUPTION! (Y/N): ").strip().upper()
                if confirm == 'Y':
                    logger.warning("User confirmed force clearing lock - proceeding")
                    print("\nForce clearing lock and continuing...\n")
                    remove_lock()
                    return False
                else:
                    logger.info("User cancelled force clear after confirmation")
                    continue
            else:
                logger.warning(f"Invalid choice in duplicate instance menu: {choice}")
                print("Please enter Q or F.")
    else:
        logger.warning(f"Pending task detected - PID: {lock_info['pid']}, Command: {' '.join(lock_info['command'])}, "
                      f"Task started at: {time_str}, Interrupted {time_duration} ago")
        print("               PENDING TASK DETECTED")
        print("=" * 51)
        print(f"\nPrevious command was interrupted:")
        print(f" - {lock_info['command']}")
        print(f" - PID: {lock_info['pid']}")
        print(f" - Task started at: {time_str}")
        print(f" - Interrupted {time_duration} ago")
        print("\nThe script was terminated unexpectedly during this operation.")
        while True:
            print("\nYou have the following options:")
            print(" Y - Continue with the pending task")
            print(" N - Clear the pending task")
            print(" Q - Quit the script without making any changes")
            print("\nYou should NEVER choose 'Y' if you left the workspace unchecked!\n")
            choice = input("Enter your choice (Y/N/Q): ").strip().upper()
            if choice == 'Y':
                logger.warning("User chose to resume pending task - proceeding with caution")
                print("\nResuming pending task...\n")
                return lock_info['command']
            elif choice == 'N':
                logger.info("User chose to clear pending task")
                print("\nClearing pending task...\n")
                remove_lock()
                return False
            elif choice == 'Q':
                logger.info("User chose to quit without making changes")
                print("\nExiting script without any changes...\n")
                sys.exit(0)
            else:
                logger.warning(f"Invalid choice in pending task menu: {choice}")
                print("Please enter Y, N, or Q.\n")

def check_server_requirements():
    print("Checking server requirements...")
    port_available = check_port_availability()
    java_valid = check_java_installation()
    permissions_ok = check_file_permissions()
    return port_available, java_valid, permissions_ok

def check_port_availability():
    port = 25565
    if SERVER_PROPERTIES.exists():
        try:
            with open(SERVER_PROPERTIES, 'r') as f:
                for line in f:
                    if line.strip().startswith('server-port='):
                        port_str = line.split('=')[1].strip()
                        if port_str.isdigit():
                            port = int(port_str)
                        break
        except Exception as e:
            print(f" - Error reading server.properties: {e}")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            result = s.connect_ex(('localhost', port))
            if result == 0:
                print(f" - Port {port} is already in use")
                return False
            else:
                print(f" - Port {port} is available")
                return True
    except Exception as e:
        print(f" - Error checking port {port}: {e}")
        return False

def check_java_installation():
    try:
        config = load_config()
        java_path = config["java_path"]
        if not Path(java_path).exists():
            print(f" - Java path not found: {java_path}")
            return False
        result = subprocess.run(
            [java_path, "-version"],
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            timeout=5
        )
        output = result.stderr or result.stdout
        if "version" in output.lower():
            print(" - Java installation is valid")
            return True
        else:
            print(" - Java installation appears invalid")
            return False   
    except subprocess.TimeoutExpired:
        print(" - Java version check timed out")
        return False
    except Exception as e:
        print(f" - Error checking Java installation: {e}")
        return False

def check_file_permissions():
    required_dirs = [
        BASE_DIR / "logs",
        BASE_DIR / "worlds", 
        BASE_DIR / "plugins",
        BASE_DIR / "config"
    ]
    for dir_path in required_dirs:
        try:
            dir_path.mkdir(parents=True, exist_ok=True)
            test_file = dir_path / ".write_test"
            try:
                with open(test_file, 'w') as f:
                    f.write("test")
                test_file.unlink()
            except Exception as e:
                print(f" - No write permission in {dir_path.name} directory")
                return False
        except Exception as e:
            print(f" - Error accessing {dir_path.name} directory: {e}")
            return False
    if not SERVER_JAR.exists():
        print(f" - Server core file not found: {SERVER_JAR}")
        return False
    print(" - File permissions are valid")
    return True

def truncate_text(text, max_length):
    if len(text) > max_length:
        return text[:max_length-3] + "..."
    return text

def format_plugins_table(plugins):
    name_width = 25
    version_width = 15
    status_width = 10
    table = []
    table.append("                - Plugins Management -")
    table.append("╔" + "═" * name_width + "╦" + "═" * version_width + "╦" + "═" * status_width + "╗")
    table.append("║" + " Plugins".ljust(name_width-1) + " ║" + " Version".ljust(version_width-1) + " ║" + " Status".ljust(status_width-1) + " ║")
    table.append("╠" + "═" * name_width + "╬" + "═" * version_width + "╬" + "═" * status_width + "╣")
    for i, plugin in enumerate(plugins, 1):
        name = f"{i}. {plugin['name']}"
        version = plugin['version']
        status = "Enabled" if plugin['enabled'] else "Disabled"
        name_display = truncate_text(name, name_width-1)
        version_display = truncate_text(version, version_width-1)
        status_display = truncate_text(status, status_width-1)
        row = (f"║ {name_display.ljust(name_width-1)}"
               f"║ {version_display.ljust(version_width-1)}"
               f"║ {status_display.ljust(status_width-1)}║")
        table.append(row)
    table.append("╚" + "═" * name_width + "╩" + "═" * version_width + "╩" + "═" * status_width + "╝")
    return "\n".join(table)

def format_java_table(java_installations):
    path_width = 34
    version_width = 9
    vendor_width = 11
    table = []
    table.append("                   - Java Selection -")
    table.append("╔" + "═" * path_width + "╦" + "═" * version_width + "╦" + "═" * vendor_width + "╗")
    table.append("║" + " Path".ljust(path_width-1) + " ║" + " Version".ljust(version_width-1) + " ║" + " Vendor".ljust(vendor_width-1) + " ║")
    table.append("╠" + "═" * path_width + "╬" + "═" * version_width + "╬" + "═" * vendor_width + "╣")
    for i, install in enumerate(java_installations, 1):
        path = f"{i}. {install['path']}"
        version = f"Java {install['version']}"
        vendor = install['vendor']
        path_display = truncate_text(path, path_width-1)
        version_display = truncate_text(version, version_width-1)
        vendor_display = truncate_text(vendor, vendor_width-1)
        row = (f"║ {path_display.ljust(path_width-1)}"
               f"║ {version_display.ljust(version_width-1)}"
               f"║ {vendor_display.ljust(vendor_width-1)}║")
        table.append(row)
    custom_path = "0. Custom Java"
    custom_path_display = truncate_text(custom_path, path_width-1)
    table.append(f"║ {custom_path_display.ljust(path_width-1)}║ {'Java ?'.ljust(version_width-1)}║ {'Unknown'.ljust(vendor_width-1)}║")
    table.append("╚" + "═" * path_width + "╩" + "═" * version_width + "╩" + "═" * vendor_width + "╝")
    return "\n".join(table)

def check_and_accept_eula():
    if not EULA_FILE.exists():
        with open(EULA_FILE, 'w') as f:
            f.write("#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).\n")
            f.write(f"#{datetime.datetime.now().strftime('%a %b %d %H:%M:%S %Z %Y')}\n")
            f.write("eula=true\n")
        print("EULA file not found. Created and accepted EULA automatically.")
        print("By using this server, you agree to Mojang's EULA (https://aka.ms/MinecraftEULA)\n")
        return True
    eula_accepted = False
    try:
        with open(EULA_FILE, 'r') as f:
            for line in f:
                if line.strip().startswith('eula='):
                    if 'true' in line.lower():
                        eula_accepted = True
                    break
    except Exception as e:
        print(f"\nError reading EULA file: {e}\n")
        return False
    if not eula_accepted:
        try:
            with open(EULA_FILE, 'r') as f:
                content = f.read()
            content = re.sub(r'eula\s*=\s*false', 'eula=true', content, flags=re.IGNORECASE)
            if 'eula=' not in content.lower():
                content += "\neula=true\n"
            with open(EULA_FILE, 'w') as f:
                f.write(content)
            print("EULA not accepted. Automatically accepted EULA.")
            print("By using this server, you agree to Mojang's EULA (https://aka.ms/MinecraftEULA)\n")
            return True
        except Exception as e:
            print(f"Error updating EULA file: {e}")
            return False
    return True

def format_file_size(bytes_size):
    if bytes_size == 0:
        return "0 B"
    units = ['B', 'KB', 'MB', 'GB']
    size = float(bytes_size)
    unit_index = 0
    while size >= 1024 and unit_index < len(units) - 1:
        size /= 1024
        unit_index += 1
    return f"{size:.1f} {units[unit_index]}"

def manage_worlds():
    if not create_lock(["--worlds"]):
        logger.error("Failed to create lock for world management")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Starting world management utility")
        print("\n" + "=" * 52)
        print("                World Management Utility")
        print("=" * 52)
        WORLDS_DIR.mkdir(parents=True, exist_ok=True)
        world_folders = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        if not world_folders:
            logger.info("No world folders found")
            print("\nNo world folders found.")
            print("\nAvailable operations:")
            print(" 1. Import worlds")
            print(" 2. Configure world seed")
            while True:
                try:
                    choice = input("\nYour choice (1/2): ").strip()
                    if choice == "1":
                        logger.info("User chose to import world")
                        import_world()
                        break
                    elif choice == "2":
                        logger.info("User chose to configure world seed")
                        configure_world_seed()
                        break
                    else:
                        logger.warning(f"Invalid option selected in world management: {choice}")
                        print("Invalid option. Please choose 1 or 2.\n")
                except KeyboardInterrupt:
                    logger.info("World management operation cancelled by user")
                    print("\nOperation canceled.\n")
                    break
            return
        logger.info(f"Found {len(world_folders)} world folder(s)")
        print("\n                - Existing Worlds -")
        world_info = []
        total_size = 0
        for world_folder in world_folders:
            try:
                world_size = sum(f.stat().st_size for f in world_folder.rglob('*') if f.is_file())
                status = "OK" if (world_folder / "level.dat").exists() else "CORRUPTED"
                world_info.append((world_folder, world_size, status))
                total_size += world_size
                logger.info(f"World found: {world_folder.name}, size: {world_size} bytes, status: {status}")
            except Exception as e:
                world_info.append((world_folder, 0, "ERROR"))
                logger.error(f"Error reading world folder {world_folder.name}: {e}")
                print(f"Error reading {world_folder.name}: {e}")
        world_info.sort(key=lambda x: x[1], reverse=True)
        name_width = 25
        size_width = 11
        status_width = 12
        print("╔" + "═" * name_width + "╦" + "═" * size_width + "╦" + "═" * status_width + "╗")
        print("║" + " Worlds".ljust(name_width - 1) +
              " ║" + " Size".ljust(size_width - 1) +
              " ║" + " Status".ljust(status_width - 1) + " ║")
        print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
        for i, (world_folder, size, status) in enumerate(world_info, 1):
            name_display = f"{i}. {world_folder.name}"
            print(f"║ {name_display:<{name_width - 1}}"
                  f"║ {format_file_size(size):<{size_width - 1}}"
                  f"║ {status:<{status_width - 1}}║")
        print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
        print(f"║ {'0. All':<{name_width - 1}}║ {format_file_size(total_size):<{size_width - 1}}║ {'All Worlds':<{status_width - 1}}║")
        print("╚" + "═" * name_width + "╩" + "═" * size_width + "╩" + "═" * status_width + "╝")
        logger.info(f"Total world size: {format_file_size(total_size)} across {len(world_info)} worlds")
        print("\nAvailable operations:")
        print(" 1. Delete worlds")
        print(" 2. Backup worlds")
        print(" 3. Import worlds")
        print(" 4. Configure world seed")
        try:
            operation_choice = input("\nSelect operation (1-4): ").strip()
            if not operation_choice:
                logger.info("User cancelled operation selection")
                print("No operation selected. Operation canceled.\n")
                return
            logger.info(f"User selected operation: {operation_choice}")
            if operation_choice == "1":
                delete_worlds(world_info)
            elif operation_choice == "2":
                backup_worlds(world_info)
            elif operation_choice == "3":
                import_world()
            elif operation_choice == "4":
                configure_world_seed()
            else:
                logger.warning(f"Invalid operation selection: {operation_choice}")
                print("Invalid operation selection.\n")
                return
        except KeyboardInterrupt:
            logger.info("World management operation interrupted by user")
            print("\nOperation canceled by user.\n")
        except Exception as e:
            logger.error(f"Error during world operation: {e}")
            print(f"Error during world operation: {e}\n")
    finally:
        if remove_lock():
            logger.info("World management lock released")
        else:
            logger.error("Failed to remove world management lock")

def delete_worlds(world_info):
    try:
        logger.info("Starting world deletion process")
        selection = input("\nSelect world folders to delete (space-separated numbers, 0 for all): ").strip()
        if not selection:
            logger.info("User cancelled world deletion")
            print("No selection made. Operation canceled.\n")
            return
        logger.info(f"User selection for deletion: {selection}")
        selected_indices = []
        for num_str in selection.split():
            try:
                num = int(num_str)
                if 0 <= num <= len(world_info):
                    selected_indices.append(num)
                else:
                    logger.warning(f"Invalid number in selection: {num}")
                    print(f"Invalid number: {num}")
                    return
            except ValueError:
                logger.error(f"Invalid input in selection: {num_str}")
                print(f"Invalid input: {num_str}")
                return
        logger.info(f"Parsed indices for deletion: {selected_indices}")
        if 0 in selected_indices:
            logger.warning("User selected to delete ALL worlds")
            confirm = input("\nAre you sure you want to delete ALL world folders?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                logger.info("User cancelled deletion of all worlds")
                print("Operation canceled.\n")
                return
            logger.info("User confirmed deletion of all worlds")
            deleted_count = 0
            total_freed = 0
            for world_folder, size, _ in world_info:
                try:
                    shutil.rmtree(world_folder)
                    deleted_count += 1
                    total_freed += size
                    logger.info(f"Deleted world: {world_folder.name} ({format_file_size(size)})")
                    print(f"Deleted: {world_folder.name}")
                except Exception as e:
                    logger.error(f"Error deleting world {world_folder.name}: {e}")
                    print(f"Error deleting {world_folder.name}: {e}")
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(total_freed)}")
            print(f"\nAll world folders deleted successfully.")
            print(f"Deleted {deleted_count} worlds, freed {format_file_size(total_freed)}")
        else:
            worlds_to_delete = [world_info[i - 1][0] for i in selected_indices]
            delete_sizes = [world_info[i - 1][1] for i in selected_indices]
            total_delete_size = sum(delete_sizes)
            logger.info(f"User selected {len(worlds_to_delete)} worlds for deletion")
            print("\nYou have selected the following world(s) to delete:")
            for i, w in enumerate(worlds_to_delete):
                size = delete_sizes[i]
                print(f" - {w.name} ({format_file_size(size)})")
            logger.info(f"Total size to delete: {format_file_size(total_delete_size)}")
            confirm = input("\nAre you sure you want to delete these world(s)?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                logger.info("User cancelled deletion of selected worlds")
                print("Operation canceled.\n")
                return
            logger.info("User confirmed deletion of selected worlds")
            deleted_count = 0
            freed_space = 0
            for i, w in enumerate(worlds_to_delete):
                try:
                    size = delete_sizes[i]
                    shutil.rmtree(w)
                    deleted_count += 1
                    freed_space += size
                    logger.info(f"Deleted world: {w.name} ({format_file_size(size)})")
                    print(f"Deleted: {w.name}")
                except Exception as e:
                    logger.error(f"Error deleting world {w.name}: {e}")
                    print(f"Error deleting {w.name}: {e}")
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(freed_space)}")
            print(f"\nSelected world(s) deleted successfully.")
            print(f"Deleted {deleted_count} worlds, freed {format_file_size(freed_space)}")
        remaining = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        logger.info(f"Remaining worlds after deletion: {len(remaining)}")
        if not remaining:
            logger.info("All world folders have been removed")
            choice = input("\nAll world folders have been removed.\nDo you want to configure a new world seed now? (Y/N): ").strip().upper()
            if choice == "Y":
                logger.info("User chose to configure new world seed")
                configure_world_seed()
            else:
                logger.info("User skipped seed configuration")
                print("Skipped seed configuration.\n")
        else:
            logger.info(f"{len(remaining)} world folders remain")
            print("Some world folders remain. Skipping seed configuration.\n")
    except KeyboardInterrupt:
        logger.info("World deletion operation interrupted by user")
        print("\nOperation canceled by user.\n")
    except Exception as e:
        logger.error(f"Error in delete_worlds(): {e}")
        print(f"Error: {e}\n")

def backup_worlds(world_info):
    try:
        logger.info("Starting world backup process")
        config = load_config()
        current_version = config.get("version", "unknown")
        logger.info(f"Current server version for backup: {current_version}")
    except Exception as e:
        logger.error(f"Error loading config for backup: {e}")
        print("Error: Could not determine current server version for backup.\n")
        return
    selection = input("\nSelect world folders to backup (space-separated numbers, 0 for all): ").strip()
    if not selection:
        logger.info("User cancelled backup selection")
        print("No selection made. Operation canceled.\n")
        return
    logger.info(f"User backup selection: {selection}")
    selected_indices = []
    for num_str in selection.split():
        try:
            num = int(num_str)
            if 0 <= num <= len(world_info):
                selected_indices.append(num)
            else:
                logger.warning(f"Invalid number in backup selection: {num}")
                print(f"Invalid number: {num}")
                return
        except ValueError:
            logger.error(f"Invalid input in backup selection: {num_str}")
            print(f"Invalid input: {num_str}")
            return
    logger.info(f"Parsed backup indices: {selected_indices}")
    if 0 in selected_indices:
        worlds_to_backup = [world_info[i][0] for i in range(len(world_info))]
        print("\nYou have selected ALL worlds to backup:")
    else:
        worlds_to_backup = [world_info[i - 1][0] for i in selected_indices]
        print("\nYou have selected the following world(s) to backup:")
    backup_sizes = []
    for w in worlds_to_backup:
        size = sum(f.stat().st_size for f in w.rglob('*') if f.is_file())
        backup_sizes.append(size)
        print(f" - {w.name} ({format_file_size(size)})")
    total_backup_size = sum(backup_sizes)
    logger.info(f"Total size to backup: {format_file_size(total_backup_size)} for {len(worlds_to_backup)} worlds")
    confirm = input("\nProceed with backup? (Y/N): ").strip().upper()
    if confirm != "Y":
        logger.info("User cancelled backup")
        print("Operation canceled.\n")
        return
    logger.info("User confirmed backup")
    backup_dir = BUNDLES_DIR / current_version / "worlds"
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"worlds_{timestamp}.zip"
    backup_path = backup_dir / backup_filename
    logger.info(f"Creating backup at: {backup_path}")
    print(f"\nCreating backup: {backup_path}")
    try:
        with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for world_folder in worlds_to_backup:
                if not world_folder.exists():
                    logger.warning(f"World folder {world_folder.name} does not exist, skipping")
                    print(f"Warning: World folder {world_folder.name} does not exist, skipping.")
                    continue
                logger.info(f"Adding world to backup: {world_folder.name}")
                print(f"Adding: {world_folder.name}")
                for root, _, files in os.walk(world_folder):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.join(world_folder.name, os.path.relpath(file_path, world_folder))
                        zipf.write(file_path, arcname)
        file_size = os.path.getsize(backup_path)
        logger.info(f"Backup created successfully: {backup_path}, size: {format_file_size(file_size)}")
        print(f"\nBackup created successfully: {backup_path}")
        print(f"File size: {format_file_size(file_size)}")
        print(f"Worlds backed up: {len(worlds_to_backup)}")
        print("")
    except Exception as e:
        logger.error(f"Error creating backup: {e}")
        print(f"Error creating backup: {e}\n")
        if backup_path.exists():
            try:
                backup_path.unlink()
                logger.info("Removed incomplete backup file")
            except:
                logger.warning("Could not remove incomplete backup file")

def import_world():
    logger.info("Starting world import utility")
    print("\n" + "=" * 50)
    print("               World Import Utility")
    print("=" * 50)
    while True:
        zip_path_input = input("\nEnter the path to the world backup ZIP file: ").strip()
        if not zip_path_input:
            logger.info("User cancelled world import")
            print("Operation canceled.\n")
            return
        zip_path = Path(zip_path_input)
        logger.info(f"User provided zip path: {zip_path}")
        if not zip_path.exists():
            logger.error(f"File not found: {zip_path}")
            print(f"Error: File not found: {zip_path}")
            continue
        if zip_path.suffix.lower() != '.zip':
            logger.error(f"File is not a ZIP archive: {zip_path}")
            print("Error: File must be a ZIP archive.")
            continue
        logger.info(f"Valid zip file found: {zip_path}")
        break
    logger.info(f"Reading archive: {zip_path}")
    print(f"\nReading archive: {zip_path.name}")
    try:
        with zipfile.ZipFile(zip_path, 'r') as zipf:
            world_candidates = set()
            for name in zipf.namelist():
                if name.endswith('/'):
                    continue
                parts = name.split('/')
                if len(parts) >= 2 and parts[-1] == 'level.dat':
                    world_candidates.add(parts[0])
            logger.info(f"Found {len(world_candidates)} world candidates in archive")
            if not world_candidates:
                logger.error("No valid worlds found in archive")
                print("Error: No valid worlds found in the archive.")
                print("A valid world must contain a level.dat file.")
                print("")
                return
            print(f"Found {len(world_candidates)} world(s) in archive:")
            for i, world_name in enumerate(world_candidates, 1):
                print(f" {i}. {world_name}")
            existing_worlds = [d.name for d in WORLDS_DIR.iterdir() if d.is_dir()]
            conflicting_worlds = [w for w in world_candidates if w in existing_worlds]
            logger.info(f"Conflicting worlds: {conflicting_worlds}")
            if conflicting_worlds:
                print(f"\nWarning: The following worlds already exist:")
                for world in conflicting_worlds:
                    print(f" - {world}")
                replace_choice = input("\nReplace existing worlds? (Y/N): ").strip().upper()
                if replace_choice != "Y":
                    logger.info("User chose not to replace existing worlds")
                    print("Import canceled.\n")
                    return
                logger.info("User confirmed replacement of existing worlds")
                for world_name in conflicting_worlds:
                    world_path = WORLDS_DIR / world_name
                    try:
                        shutil.rmtree(world_path)
                        logger.info(f"Removed existing world: {world_name}")
                        print(f"Removed existing world: {world_name}")
                    except Exception as e:
                        logger.error(f"Error removing {world_name}: {e}")
                        print(f"Error removing {world_name}: {e}")
            logger.info(f"Extracting {len(world_candidates)} worlds...")
            print(f"\nExtracting worlds...")
            extracted_count = 0
            for world_name in world_candidates:
                world_path = WORLDS_DIR / world_name
                world_path.mkdir(parents=True, exist_ok=True)
                for name in zipf.namelist():
                    if name.startswith(world_name + '/'):
                        relative_path = name[len(world_name)+1:]
                        if not relative_path:
                            continue
                        target_path = world_path / relative_path
                        target_path.parent.mkdir(parents=True, exist_ok=True)
                        if not name.endswith('/'):
                            with zipf.open(name) as source, open(target_path, 'wb') as target:
                                shutil.copyfileobj(source, target)
                if (world_path / "level.dat").exists():
                    world_size = sum(f.stat().st_size for f in world_path.rglob('*') if f.is_file())
                    logger.info(f"Imported world: {world_name}, size: {format_file_size(world_size)}")
                    print(f" - Imported: {world_name} ({format_file_size(world_size)})")
                    extracted_count += 1
                else:
                    logger.warning(f"Invalid world (missing level.dat): {world_name}")
                    print(f" - Invalid world (missing level.dat): {world_name}")
                    shutil.rmtree(world_path)
            logger.info(f"Successfully imported {extracted_count} world(s)")
            print(f"\nSuccessfully imported {extracted_count} world(s).\n")
            print("")            
    except zipfile.BadZipFile:
        logger.error(f"Invalid ZIP archive: {zip_path}")
        print("Error: The file is not a valid ZIP archive.\n")
    except Exception as e:
        logger.error(f"Error importing worlds: {e}")
        print(f"Error importing worlds: {e}\n")

def configure_world_seed():
    logger.info("Starting world seed configuration")
    if not SERVER_PROPERTIES.exists():
        logger.info("Server properties file not found, creating default")
        print("Server properties file not found. Creating default...\n")
        SERVER_PROPERTIES.parent.mkdir(parents=True, exist_ok=True)
        with open(SERVER_PROPERTIES, 'w') as f:
            f.write("# Minecraft server properties\n")
            f.write("level-seed=\n")
    current_seed = ""
    properties_content = []
    if SERVER_PROPERTIES.exists():
        with open(SERVER_PROPERTIES, 'r') as f:
            properties_content = f.readlines()
        for line in properties_content:
            if line.strip().startswith('level-seed='):
                current_seed = line.strip().split('=', 1)[1]
                logger.info(f"Current seed found: '{current_seed}'")
                break
    logger.info("Presenting seed configuration options to user")
    print("\nTo generate new worlds, there are 3 options for the seed:")
    print("1. Keep the current seed")
    print("2. Use a random seed")
    print("3. Set a custom seed")
    while True:
        try:
            option = input("\nYour option (1-3): ").strip()
            logger.info(f"User selected seed option: {option}")
            
            if option == "1":
                logger.info(f"Keeping current seed: '{current_seed}'")
                print("Keeping current seed...")
                break
            elif option == "2":
                logger.info("Using random seed")
                print("Using random seed...")
                current_seed = ""
                break
            elif option == "3":
                new_seed = input("Enter your seed: ").strip()
                if new_seed:
                    logger.info(f"User set custom seed: '{new_seed}'")
                    current_seed = new_seed
                    print(f"Seed set to: {current_seed}")
                    break
                else:
                    logger.warning("User entered empty seed")
                    print("Seed cannot be empty. Please try again.\n")
            else:
                logger.warning(f"Invalid seed option: {option}")
                print("Invalid option. Please choose 1, 2, or 3.\n")
        except KeyboardInterrupt:
            logger.info("Seed configuration cancelled by user")
            print("\nOperation canceled.\n")
            return
    seed_updated = False
    new_properties_content = []
    for line in properties_content:
        if line.strip().startswith('level-seed='):
            new_properties_content.append(f"level-seed={current_seed}\n")
            seed_updated = True
        else:
            new_properties_content.append(line)
    if not seed_updated:
        new_properties_content.append(f"level-seed={current_seed}\n")
    try:
        with open(SERVER_PROPERTIES, 'w') as f:
            f.writelines(new_properties_content)
        logger.info(f"World seed configured successfully: '{current_seed}'")
        print("\nSuccessfully configured world seed.")
        print("New worlds will be generated with the specified seed when server starts.")
        print("")
    except Exception as e:
        logger.error(f"Error saving world seed configuration: {e}")
        print(f"Error saving world seed configuration: {e}\n")

def create_new_server():
    logger.info("Starting new server creation process")
    if not create_lock(["--new"]):
        logger.error("Failed to create lock for new server creation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Initializing new server creation interface")
        print("\n" + "=" * 50)
        print("               New Server Creation")
        print("=" * 50)
        try:
            config = load_config()
            current_version = config.get("version", "unknown")
            logger.info(f"Current server version: {current_version}")
        except Exception as e:
            logger.error(f"Error loading configuration: {e}")
            current_version = "unknown"
            print("Warning: Could not load config, using default version 'unknown'")
        available_versions = []
        if BUNDLES_DIR.exists():
            logger.info("Scanning bundles directory for available versions")
            for version_dir in BUNDLES_DIR.iterdir():
                if version_dir.is_dir():
                    core_zip = version_dir / "core.zip"
                    if core_zip.exists():
                        available_versions.append(version_dir.name)
        if not available_versions:
            logger.error("No server versions found in bundles directory")
            print("\nNo server versions found in bundles directory.")
            print("Please download a version first using: --get <version>\n")
            return
        logger.info(f"Found {len(available_versions)} available versions")
        print("\nAvailable Versions:")
        print("=" * 30)
        sorted_versions = sorted(available_versions, key=lambda v: [int(n) for n in v.split('.')], reverse=True)
        for i, version in enumerate(sorted_versions, 1):
            print(f"{i}. {version}")
            logger.info(f"Available version {i}: {version}")
        print("=" * 30)
        try:
            selection = input("\nSelect a version to create (number): ").strip()
            if not selection:
                logger.info("User cancelled version selection")
                print("No selection made.")
                return
            logger.info(f"User selected version index: {selection}")
            index = int(selection) - 1
            if not (0 <= index < len(sorted_versions)):
                logger.error(f"Invalid version selection: {selection}")
                print("Invalid selection.")
                return
            selected_version = sorted_versions[index]
            logger.info(f"Selected version: {selected_version}")
            print(f"Selected version: {selected_version}")
        except ValueError as e:
            logger.error(f"Invalid input for version selection: {e}")
            print("Invalid input. Please enter a number.")
            return
        if check_for_updates(selected_version):
            logger.info(f"Update available for version {selected_version}")
            confirm = input("\nUpdate to latest build before creating? (Y/N): ").strip().upper()
            if confirm == "Y":
                logger.info("User chose to update to latest build")
                print("Updating to latest build...")
                download_version(selected_version)
            else:
                logger.info("User skipped update")
        logger.info(f"Showing version info for {selected_version}")
        show_version_info(selected_version)
        core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
        if not core_zip_path.exists():
            logger.error(f"core.zip missing for version {selected_version}")
            print(f"Error: core.zip missing for {selected_version}")
            return
        logger.info("Cleaning current directory for new server")
        print("\nCreating new server...")
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns")
        items_removed = 0
        items_skipped = 0
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                items_skipped += 1
                logger.info(f"Skipped item: {item.name}")
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item, ignore_errors=True)
                    logger.info(f"Removed directory: {item.name}")
                else:
                    item.unlink()
                    logger.info(f"Removed file: {item.name}")
                items_removed += 1
            except Exception as e:
                logger.warning(f"Failed to remove {item.name}: {e}")
        logger.info(f"Cleaned directory: {items_removed} items removed, {items_skipped} items skipped")
        try:
            logger.info(f"Extracting core.zip from {core_zip_path}")
            with zipfile.ZipFile(core_zip_path, 'r') as zipf:
                zipf.extractall(BASE_DIR)
            logger.info(f"Successfully extracted core for version {selected_version}")
            print(f"Extracted core for version {selected_version}")
        except Exception as e:
            logger.error(f"Error extracting core: {e}")
            print(f"Error extracting core: {e}\n")
            return
        logger.info("Presenting initialization options to user")
        print("\nInitialization options:")
        print("1. Enter --init")
        print("2. Enter --init auto")
        print("3. Exit without initialization")
        while True:
            choice = input("\nYour choice (1-3): ").strip()
            logger.info(f"User initialization choice: {choice}")
            if choice == "1":
                logger.info("User chose manual initialization")
                print("Running manual initialization...")
                init_config(prefill_version=selected_version)
                break
            elif choice == "2":
                logger.info("User chose auto initialization")
                print("Running auto initialization...")
                init_config_auto(prefill_version=selected_version)
                break
            elif choice == "3":
                logger.info("User chose to exit without initialization")
                print("Server created but not initialized.")
                print("Please run --init or --init auto to configure the server.")
                break
            else:
                logger.warning(f"Invalid initialization choice: {choice}")
                print("Invalid input. Choose 1, 2, or 3.")
        logger.info("New server creation process completed")
    except KeyboardInterrupt:
        logger.info("New server creation interrupted by user")
        print("\nOperation cancelled by user.\n")
    except Exception as e:
        logger.error(f"Error in create_new_server(): {e}")
        print(f"Error during new server creation: {e}\n")
    finally:
        if remove_lock():
            logger.info("New server creation lock released")
        else:
            logger.error("Failed to remove new server creation lock")

def check_for_updates(version):
    logger.info(f"Starting update check for version: {version}")
    print(f"\nChecking for updates for version {version}...")
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    if not core_zip_path.exists():
        logger.warning(f"No local version found to check for updates: {core_zip_path}")
        print("No local version found to check for updates.")
        return False
    local_build = None
    try:
        logger.info(f"Reading local build info from: {core_zip_path}")
        with zipfile.ZipFile(core_zip_path, 'r') as zipf:
            if 'info.txt' in zipf.namelist():
                with zipf.open('info.txt') as info_file:
                    info_content = info_file.read().decode('utf-8')
                    build_match = re.search(r'Build\s+(\d+)', info_content)
                    if build_match:
                        local_build = int(build_match.group(1))
                        logger.info(f"Found local build number: {local_build}")
                    else:
                        logger.warning("Could not find build number in info.txt")
            else:
                logger.warning("info.txt not found in core.zip")
    except zipfile.BadZipFile as e:
        logger.error(f"Invalid ZIP file: {core_zip_path} - {e}")
        print(f"Error reading local version info: {e}")
        return False
    except Exception as e:
        logger.error(f"Error reading local version info: {e}")
        print(f"Error reading local version info: {e}")
        return False
    if local_build is None:
        logger.warning("Could not determine local build number")
        print("Could not determine local build number.")
        return False
    logger.info(f"Querying PurpurMC API for version {version}")
    api_url = f"https://api.purpurmc.org/v2/purpur/{version}"
    try:
        logger.info(f"Making API request to: {api_url}")
        start_time = time.time()
        with urllib.request.urlopen(api_url, timeout=10) as response:
            elapsed_time = time.time() - start_time
            logger.info(f"API response received in {elapsed_time:.2f}s, status: {response.status}")
            version_data = json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching version data - HTTP {e.code}: {e.reason}")
        print(f"HTTP Error: {e.code} - {e.reason}")
        print("Could not check for updates.\n")
        return False
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching version data - {e.reason}")
        print(f"Network Error: {e.reason}")
        print("Please check your internet connection.\n")
        return False
    except socket.timeout:
        logger.error("Connection timeout while fetching version data")
        print("Connection timeout while checking for updates.")
        print("The request took too long. Please check your internet connection.\n")
        return False
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        print("Error parsing server response.")
        print("The API may have returned invalid data.\n")
        return False
    except Exception as e:
        logger.error(f"Unexpected error fetching version data: {type(e).__name__}: {e}")
        print(f"Unexpected error: {e}")
        print("Continuing with local version...")
        return False
    builds = version_data.get("builds", {})
    all_builds = builds.get("all", [])
    if not all_builds:
        logger.warning(f"No builds found for version {version} in API response")
        print("No builds found for this version.")
        return False
    logger.info(f"Found {len(all_builds)} builds in API response")
    latest_build = None
    successful_builds_checked = 0
    for build in sorted(all_builds, key=int, reverse=True):
        try:
            logger.info(f"Checking build {build} for successful status...")
            build_url = f"https://api.purpurmc.org/v2/purpur/{version}/{build}"
            
            start_time = time.time()
            with urllib.request.urlopen(build_url, timeout=5) as build_response:
                elapsed_time = time.time() - start_time
                logger.info(f"Build {build} API response in {elapsed_time:.2f}s")
                build_data = json.loads(build_response.read().decode())
            
            if build_data.get("result") == "SUCCESS":
                latest_build = int(build)
                logger.info(f"Found successful build: {latest_build}")
                successful_builds_checked += 1
                break
            else:
                logger.info(f"Build {build} result: {build_data.get('result', 'UNKNOWN')}")
                successful_builds_checked += 1
        except urllib.error.HTTPError as e:
            logger.warning(f"HTTP error checking build {build}: {e.code} {e.reason}")
            continue
        except urllib.error.URLError as e:
            logger.warning(f"URL error checking build {build}: {e.reason}")
            continue
        except socket.timeout:
            logger.warning(f"Timeout checking build {build}")
            continue
        except Exception as e:
            logger.warning(f"Error checking build {build}: {type(e).__name__}: {e}")
            continue
    if latest_build is None:
        logger.warning(f"No successful builds found for version {version} after checking {successful_builds_checked} builds")
        print("No successful builds found for this version.")
        return False
    
    logger.info(f"Local build: {local_build}, Latest successful build: {latest_build}")
    print(f"Local build: {local_build}, Latest build: {latest_build}")
    
    if latest_build > local_build:
        logger.info(f"Update available! Build {local_build} -> {latest_build}")
        print("Update available!")
        return True
    else:
        logger.info(f"No updates found. Local build {local_build} is up-to-date or newer")
        print("No updates found.")
        return False

def show_version_info(version):
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    if not core_zip_path.exists():
        print(f"No core.zip found for version {version}")
        return
    try:
        with zipfile.ZipFile(core_zip_path, 'r') as zipf:
            if 'info.txt' in zipf.namelist():
                with zipf.open('info.txt') as info_file:
                    info_content = info_file.read().decode('utf-8')
                    print("\nVersion Information:")
                    print(info_content)
            else:
                print(f"No info.txt found for version {version}")
    except Exception as e:
        print(f"Error reading version info: {e}")

def download_version(version=None):
    logger.info(f"Starting download_version function, version parameter: {version}")
    command = ["--get"]
    if version:
        command.append(version)
        logger.info(f"Full command: {' '.join(command)}")
    if not create_lock(command):
        logger.error("Failed to create lock for download operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        if version is None:
            logger.info("No version specified, fetching available versions list")
            try:
                logger.info("Making API request to get available versions")
                start_time = time.time()
                with urllib.request.urlopen("https://api.purpurmc.org/v2/purpur", timeout=10) as response:
                    elapsed_time = time.time() - start_time
                    logger.info(f"API response received in {elapsed_time:.2f}s, status: {response.status}")
                    data = json.loads(response.read().decode())
                    versions = data.get("versions", [])
                    logger.info(f"Found {len(versions)} total versions")
                    version_groups = {}
                    for v in versions:
                        major_version = ".".join(v.split(".")[:2])
                        if major_version not in version_groups:
                            version_groups[major_version] = []
                        version_groups[major_version].append(v)
                    logger.info(f"Grouped into {len(version_groups)} major version groups")
                    print("\nAvailable Versions:")
                    print("=" * 50)
                    for major, minors in sorted(version_groups.items(), key=lambda x: tuple(map(int, x[0].split('.'))), reverse=True):
                        sorted_minors = sorted(minors, key=lambda v: tuple(map(int, v.split('.'))), reverse=True)
                        print(f"[{major}]: {', '.join(sorted_minors)}")
                        logger.info(f"Major version {major}: {sorted_minors}")
                    print("=" * 50)
                    print("")
            except urllib.error.HTTPError as e:
                logger.error(f"HTTP error fetching available versions: {e.code} - {e.reason}")
                print(f"Error fetching available versions: {e.code} - {e.reason}\n")
                return
            except urllib.error.URLError as e:
                logger.error(f"URL error fetching available versions: {e.reason}")
                print(f"Error: Could not connect to server - {e.reason}\n")
                return
            except socket.timeout:
                logger.error("Timeout fetching available versions")
                print("Error: Connection timeout while fetching version list\n")
                return
            except Exception as e:
                logger.error(f"Unexpected error fetching versions: {type(e).__name__}: {e}")
                print(f"Error fetching available versions: {e}\n")
                return
        else:
            logger.info(f"Processing specific version: {version}")
            if not re.match(r"^\d+\.\d+(\.\d+)?$", version):
                logger.error(f"Invalid version format: {version}")
                print(f"Invalid version format: {version}")
                print("Use format like 1.21.5 or 1.21")
                return
            target_dir = BUNDLES_DIR / version
            zip_path = target_dir / "core.zip"
            logger.info(f"Target directory: {target_dir}")
            logger.info(f"Zip path: {zip_path}")
            print(f"\nFetching version information for {version}...")
            try:
                logger.info(f"Querying version info from PurpurMC API: {version}")
                api_url = f"https://api.purpurmc.org/v2/purpur/{version}"
                start_time = time.time()
                with urllib.request.urlopen(api_url, timeout=10) as response:
                    elapsed_time = time.time() - start_time
                    logger.info(f"Version API response received in {elapsed_time:.2f}s, status: {response.status}")
                    version_data = json.loads(response.read().decode())
                    logger.info(f"Version data received: {json.dumps(version_data, indent=2)[:500]}...")
                builds = version_data.get("builds", {})
                latest_build = builds.get("latest")
                all_builds = builds.get("all", [])
                logger.info(f"Found {len(all_builds)} builds for version {version}")
                if not all_builds:
                    logger.warning(f"No builds found for version {version}")
                    print(f"No builds found for version {version}\n")
                    return
                all_builds.sort(key=int, reverse=True)
                logger.info(f"Sorted builds (newest first): {all_builds[:5]}...")
                successful_build = None
                build_data = None
                for build in all_builds:
                    logger.info(f"Checking build {build} for successful status...")
                    try:
                        build_url = f"https://api.purpurmc.org/v2/purpur/{version}/{build}"
                        logger.info(f"Querying build info: {build_url}")
                        start_time = time.time()
                        with urllib.request.urlopen(build_url, timeout=10) as build_response:
                            elapsed_time = time.time() - start_time
                            logger.info(f"Build {build} API response received in {elapsed_time:.2f}s")
                            build_data = json.loads(build_response.read().decode())
                        if build_data.get("result") == "SUCCESS":
                            successful_build = build
                            logger.info(f"Found successful build: {successful_build}")
                            timestamp = build_data.get("timestamp")
                            build_date = ""
                            if timestamp:
                                build_date = datetime.datetime.fromtimestamp(timestamp / 1000).strftime("%Y-%m-%d %H:%M:%S")
                            commits = build_data.get("commits", [])
                            description = "No description available"
                            author = "Unknown"
                            if commits:
                                for commit in commits:
                                    author = commit.get("author", "Unknown")
                                    description = commit.get("description", "No description")
                                    description = description.strip()
                                    description = re.sub(r'\n\s*\n', '\n\n', description)
                            md5_hash = build_data.get("md5", "Not available")
                            logger.info(f"Build {successful_build} info - Author: {author}, Date: {build_date}, MD5: {md5_hash}")
                            print("\nBuild Information:")
                            print("=" * 50)
                            print(f"Author: {author}")
                            print(f"Date: {build_date}")
                            print(f"MD5: {md5_hash}")
                            print("")
                            print("Description:")
                            print(f"{description}")
                            print("=" * 50)
                            print("")
                            info_content = f"""====================
Build {successful_build}
Version {version}

Author: {author}
Date: {build_date}
MD5: {md5_hash}

Description:
{description}
===================="""
                            break
                        else:
                            logger.info(f"Build {build} result: {build_data.get('result', 'UNKNOWN')}, continuing...")
                    except urllib.error.HTTPError as e:
                        logger.warning(f"HTTP error checking build {build}: {e.code} {e.reason}")
                        continue
                    except urllib.error.URLError as e:
                        logger.warning(f"URL error checking build {build}: {e.reason}")
                        continue
                    except socket.timeout:
                        logger.warning(f"Timeout checking build {build}")
                        continue
                    except Exception as e:
                        logger.warning(f"Error checking build {build}: {type(e).__name__}: {e}")
                        continue
                if not successful_build:
                    logger.error(f"No successful builds found for version {version} after checking {len(all_builds)} builds")
                    print(f"No successful builds found for version {version}\n")
                    return
                confirm = input("Do you want to download this version? (Y/N): ").strip().upper()
                if confirm != "Y":
                    logger.info("User cancelled download")
                    print("Download canceled.\n")
                    return
                if zip_path.exists():
                    logger.warning(f"Version {version} already exists at {zip_path}")
                    confirm = input(f"Version {version} already exists. Overwrite? (Y/N): ").strip().upper()
                    if confirm != "Y":
                        logger.info("User chose not to overwrite existing version")
                        print("Download canceled.\n")
                        return
                    else:
                        logger.info("User confirmed overwrite of existing version")
                download_url = f"https://api.purpurmc.org/v2/purpur/{version}/{successful_build}/download"
                logger.info(f"Starting download from: {download_url}")
                print(f"\nDownloading from {download_url}...")
                print("This may take a while depending on your network speed.")
                print("Press CTRL+C to cancel the download.\n")
                start_time = time.time()
                target_dir.mkdir(parents=True, exist_ok=True)
                temp_jar = target_dir / "temp_core.jar"
                logger.info(f"Temporary JAR file: {temp_jar}")
                try:
                    logger.info("Opening download connection...")
                    with urllib.request.urlopen(download_url) as download_response:
                        content_length = download_response.headers.get('Content-Length')
                        if content_length:
                            total_size = int(content_length)
                            logger.info(f"Download size: {total_size} bytes ({total_size/1024/1024:.2f} MB)")
                        downloaded_size = 0
                        chunk_size = 8192
                        last_log_time = time.time()
                        with open(temp_jar, 'wb') as f:
                            while True:
                                chunk = download_response.read(chunk_size)
                                if not chunk:
                                    break
                                f.write(chunk)
                                downloaded_size += len(chunk)
                                current_time = time.time()
                                if current_time - last_log_time >= 5:
                                    if content_length:
                                        progress = (downloaded_size / total_size) * 100
                                        logger.info(f"Download progress: {downloaded_size}/{total_size} bytes ({progress:.1f}%)")
                                    else:
                                        logger.info(f"Downloaded: {downloaded_size} bytes")
                                    last_log_time = current_time
                    elapsed_time = time.time() - start_time
                    file_size = os.path.getsize(temp_jar)
                    download_speed = file_size / elapsed_time / 1024
                    logger.info(f"Download completed in {elapsed_time:.2f} seconds, size: {file_size} bytes, speed: {download_speed:.2f} KB/s")
                    print(f"Download completed in {elapsed_time:.2f} seconds.")
                    print(f"Download speed: {download_speed:.2f} KB/s")
                    expected_md5 = build_data.get("md5")
                    if expected_md5:
                        logger.info("Verifying file integrity with MD5...")
                        print("Verifying file integrity...")
                        with open(temp_jar, 'rb') as f:
                            file_hash = hashlib.md5()
                            while chunk := f.read(8192):
                                file_hash.update(chunk)
                            actual_md5 = file_hash.hexdigest()
                        if actual_md5 != expected_md5:
                            logger.error(f"MD5 verification failed! Expected: {expected_md5}, Got: {actual_md5}")
                            print(f"MD5 verification failed!")
                            print(f"Expected: {expected_md5}")
                            print(f"Got: {actual_md5}")
                            print("")
                            print("The downloaded file may be corrupted.")
                            print("The file will be deleted due to security reasons.\n")
                            temp_jar.unlink()
                            if zip_path.exists():
                                zip_path.unlink()
                            return
                        else:
                            logger.info("MD5 verification successful")
                            print("MD5 verified successfully!\n")
                    else:
                        logger.warning("No MD5 hash provided for verification")
                        print("Warning: No MD5 hash provided for verification.\n")
                    logger.info("Creating ZIP archive with JAR and info file")
                    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                        zipf.write(temp_jar, "core.jar")
                        info_file = target_dir / "info.txt"
                        with open(info_file, 'w', encoding='utf-8') as f:
                            f.write(info_content)
                        zipf.write(info_file, "info.txt")
                        info_file.unlink()
                        logger.info("info.txt added to ZIP")
                    temp_jar.unlink()
                    logger.info(f"Successfully downloaded {version} (build {successful_build}) to {zip_path}")
                    print(f"Successfully downloaded {version} (build {successful_build}) to {zip_path}\n")
                except KeyboardInterrupt:
                    elapsed_time = time.time() - start_time
                    logger.warning(f"Download interrupted by user after {elapsed_time:.2f} seconds")
                    print(f"\nDownload canceled after {elapsed_time:.2f} seconds.\n")
                    if temp_jar.exists():
                        temp_jar.unlink()
                        logger.info("Removed temporary JAR file")
                    if zip_path.exists():
                        zip_path.unlink()
                        logger.info("Removed incomplete ZIP file")
                    return
                except Exception as e:
                    logger.error(f"Error during download: {type(e).__name__}: {e}")
                    print(f"Error during download: {e}\n")
                    if temp_jar.exists():
                        temp_jar.unlink()
                    if zip_path.exists():
                        zip_path.unlink()
                    return
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    logger.error(f"Version {version} not found (404)")
                    print(f"Version {version} not found on PurpurMC\n")
                else:
                    logger.error(f"HTTP error for version {version}: {e.code} - {e.reason}")
                    print(f"HTTP Error: {e.code} - {e.reason}\n")
            except urllib.error.URLError as e:
                logger.error(f"URL error for version {version}: {e.reason}")
                print(f"URL Error: {e.reason}\n")
            except socket.timeout:
                logger.error(f"Timeout fetching version {version}")
                print(f"Timeout while fetching version {version}\n")
            except Exception as e:
                logger.error(f"Unexpected error downloading version {version}: {type(e).__name__}: {e}")
                print(f"Error downloading version {version}: {e}\n")
    finally:
        if remove_lock():
            logger.info("Download lock released successfully")
        else:
            logger.error("Failed to remove download lock")

def get_exclude_list():
    exclude_list = BASE_EXCLUDE_LIST.copy()
    if CONFIG_FILE.exists():
        config = configparser.ConfigParser()
        try:
            config.read(CONFIG_FILE)
            if "SERVER" in config and "additional_list" in config["SERVER"]:
                additional_items = config["SERVER"]["additional_list"].split(',')
                for item in additional_items:
                    cleaned_item = item.strip()
                    if cleaned_item and cleaned_item not in exclude_list:
                        exclude_list.append(cleaned_item)
        except Exception:
            pass
    return exclude_list

def get_plugin_info(plugin_path):
    try:
        with zipfile.ZipFile(plugin_path, 'r') as jar:
            try:
                with jar.open('plugin.yml') as f:
                    plugin_data = yaml.safe_load(f)
                    name = plugin_data.get('name', 'Unknown')
                    version = plugin_data.get('version', 'Unknown')
                    main_class = plugin_data.get('main', 'Unknown')
                    return name, version, main_class
            except KeyError:
                try:
                    with jar.open('META-INF/plugin.yml') as f:
                        plugin_data = yaml.safe_load(f)
                        name = plugin_data.get('name', 'Unknown')
                        version = plugin_data.get('version', 'Unknown')
                        main_class = plugin_data.get('main', 'Unknown')
                        return name, version, main_class
                except KeyError:
                    name = plugin_path.stem
                    if name.endswith('.disabled'):
                        name = name[:-9]
                    return name, 'Unknown', 'Unknown'
    except Exception as e:
        name = plugin_path.stem
        if name.endswith('.disabled'):
            name = name[:-9]
        return name, 'Unknown', 'Unknown'

def get_plugin_dependencies(plugin_path):
    try:
        with zipfile.ZipFile(plugin_path, 'r') as jar:
            plugin_yml_locations = ['plugin.yml', 'META-INF/plugin.yml']
            plugin_data = {}
            for location in plugin_yml_locations:
                try:
                    with jar.open(location) as f:
                        plugin_data = yaml.safe_load(f)
                        break
                except KeyError:
                    continue
            if not plugin_data:
                return {'depend': [], 'softdepend': []}
            depend = plugin_data.get('depend', [])
            softdepend = plugin_data.get('softdepend', [])
            if isinstance(depend, str):
                depend = [depend] if depend else []
            if isinstance(softdepend, str):
                softdepend = [softdepend] if softdepend else []
            return {
                'depend': depend,
                'softdepend': softdepend
            }
    except Exception as e:
        return {'depend': [], 'softdepend': []}

def check_plugin_dependencies(plugins, plugin_to_disable):
    plugin_name = plugin_to_disable['name']
    hard_dependents = []
    soft_dependents = []
    for plugin in plugins:
        if plugin['enabled'] and plugin['name'] != plugin_name:
            dependencies = get_plugin_dependencies(plugin['path'])
            if plugin_name in dependencies['depend']:
                hard_dependents.append(plugin)
            if plugin_name in dependencies['softdepend']:
                soft_dependents.append(plugin)
    return {
        'hard_dependents': hard_dependents,
        'soft_dependents': soft_dependents
    }

def format_dependency_warning(plugin, hard_dependents, soft_dependents):
    message = []
    if hard_dependents:
        message.append(f"\nCRITICAL WARNING: {plugin['name']} is REQUIRED by:")
        for dependent in hard_dependents:
            message.append(f" - {dependent['name']} (version {dependent['version']})")
        message.append("\nThese plugins WILL STOP WORKING if you disable this plugin!")
        message.append("This may cause SERVER CRASHES or errors!")
    if soft_dependents:
        message.append(f"\nWARNING: {plugin['name']} is optionally used by:")
        for dependent in soft_dependents:
            message.append(f" - {dependent['name']} (version {dependent['version']})")
        message.append("\nThese plugins may lose functionality or not work perfectly!")
    return "\n".join(message)

def manage_plugins_with_dependencies():
    logger.info("Starting plugin management with dependency analysis")
    if not PLUGINS_DIR.exists():
        logger.error("Plugins directory not found")
        print("\nPlugins directory not found!")
        print("")
        return
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    logger.info(f"Found {len(plugin_files)} plugin files (including disabled)")
    if not plugin_files:
        logger.info("No plugins found in directory")
        print("\nNo plugins found!")
        print("")
        return
    plugins = []
    for plugin_path in plugin_files:
        name, version, main_class = get_plugin_info(plugin_path)
        enabled = not plugin_path.name.endswith('.disabled')
        plugins.append({
            'path': plugin_path,
            'name': name,
            'version': version,
            'main_class': main_class,
            'enabled': enabled
        })
        logger.info(f"Plugin loaded: {name} (version: {version}, enabled: {enabled})")
    enabled_count = len([p for p in plugins if p['enabled']])
    disabled_count = len([p for p in plugins if not p['enabled']])
    logger.info(f"Plugin statistics: {enabled_count} enabled, {disabled_count} disabled")
    print("\n" + format_plugins_table(plugins))
    choice = input("\nDo you want to toggle these plugins? (Y/N): ").strip().upper()
    logger.info(f"User choice for plugin toggle: {choice}")
    if choice != 'Y':
        logger.info("User cancelled plugin management")
        print("")
        return
    try:
        selected = input("Enter the numbers of the plugin you want to toggle (e.g., '1 2 3'): ").strip()
        if not selected:
            logger.info("No plugins selected for toggling")
            print("No plugins selected.\n")
            return
        logger.info(f"User selected plugins: {selected}")
        indices = [int(i) for i in selected.split()]
        indices = [i for i in indices if 1 <= i <= len(plugins)]
        logger.info(f"Valid plugin indices after filtering: {indices}")
        if not indices:
            logger.warning("No valid plugin numbers selected")
            print("No valid plugin numbers selected.\n")
            return
        plugins_to_disable = []
        plugins_to_enable = []
        for idx in indices:
            plugin = plugins[idx-1]
            if plugin['enabled']:
                plugins_to_disable.append(plugin)
                logger.info(f"Plugin to disable: {plugin['name']} (index: {idx})")
            else:
                plugins_to_enable.append(plugin)
                logger.info(f"Plugin to enable: {plugin['name']} (index: {idx})")
        logger.info(f"Operation summary: {len(plugins_to_enable)} to enable, {len(plugins_to_disable)} to disable")
        for plugin in plugins_to_enable:
            old_path = plugin['path']
            new_name = old_path.name.replace(".disabled", "")
            new_path = old_path.parent / new_name
            try:
                old_path.rename(new_path)
                plugin['path'] = new_path
                plugin['enabled'] = True
                logger.info(f"Enabled plugin: {plugin['name']}")
                print(f"Enabled: {plugin['name']}")
            except Exception as e:
                logger.error(f"Failed to enable plugin {plugin['name']}: {e}")
                print(f"Error enabling {plugin['name']}: {e}")
        for plugin in plugins_to_disable:
            dependencies = check_plugin_dependencies(plugins, plugin)
            hard_dependents = dependencies['hard_dependents']
            soft_dependents = dependencies['soft_dependents']
            logger.info(f"Checking dependencies for {plugin['name']}: "
                       f"{len(hard_dependents)} hard dependents, {len(soft_dependents)} soft dependents")
            if hard_dependents or soft_dependents:
                warning_message = format_dependency_warning(plugin, hard_dependents, soft_dependents)
                if hard_dependents:
                    hard_dep_names = [dep['name'] for dep in hard_dependents]
                    logger.warning(f"Hard dependencies found for {plugin['name']}: {hard_dep_names}")
                if soft_dependents:
                    soft_dep_names = [dep['name'] for dep in soft_dependents]
                    logger.info(f"Soft dependencies found for {plugin['name']}: {soft_dep_names}")
                print(warning_message)
                if hard_dependents:
                    logger.info("Presenting options for hard dependencies")
                    print(f"\nYou have multiple options:")
                    print("1. Disable the dependent plugins first, then disable this one")
                    print("2. Force disable this plugin anyway (RISKY)")
                    print("3. Disable the whole plugin chain for me (AUTOMATIC)")
                    while True:
                        choice = input("\nChoose option (1/2/3) or 'C' to cancel: ").strip().upper()
                        logger.info(f"User dependency resolution choice: {choice}")
                        if choice == '1':
                            logger.info(f"User chose to manually disable dependent plugins first")
                            print("Please disable the dependent plugins first:")
                            for dependent in hard_dependents:
                                print(f" - {dependent['name']}")
                            print("Then try disabling this plugin again.\n")
                            continue
                        elif choice == '2':
                            logger.warning(f"User chose to force disable {plugin['name']}")
                            confirm = input("Are you sure?\nThis may break other plugins or crash the server! (Y/N): ").strip().upper()
                            if confirm == 'Y':
                                logger.warning(f"User confirmed force disable for {plugin['name']}")
                                try:
                                    old_path = plugin['path']
                                    new_path = old_path.parent / (old_path.name + ".disabled")
                                    old_path.rename(new_path)
                                    plugin['path'] = new_path
                                    plugin['enabled'] = False
                                    logger.info(f"Force disabled: {plugin['name']}")
                                    print(f"Force disabled: {plugin['name']}\n")
                                    break
                                except Exception as e:
                                    logger.error(f"Failed to force disable {plugin['name']}: {e}")
                                    print(f"Error force disabling {plugin['name']}: {e}\n")
                                    break
                            else:
                                logger.info(f"User cancelled force disable for {plugin['name']}")
                                continue
                        elif choice == '3':
                            logger.info(f"User chose automatic dependency chain disable for {plugin['name']}")
                            disabled_plugins = disable_dependency_chain(plugins, plugin)
                            if disabled_plugins:
                                disabled_names = [p['name'] for p in disabled_plugins]
                                logger.info(f"Automatically disabled {len(disabled_plugins)} plugins: {disabled_names}")
                                print(f"\nAutomatically disabled the following plugins:")
                                for disabled_plugin in disabled_plugins:
                                    print(f" - {disabled_plugin['name']}")           
                                if soft_dependents:
                                    soft_names = [dep['name'] for dep in soft_dependents]
                                    logger.info(f"Soft dependents not auto-disabled: {soft_names}")
                                    print(f"\nNote: The following plugins have soft dependencies and were NOT automatically disabled:")
                                    for soft_dep in soft_dependents:
                                        print(f"  - {soft_dep['name']}")
                                    print("These plugins may lose some functionality but should still work.\n")
                            break
                        elif choice == 'C':
                            logger.info(f"User cancelled disabling of {plugin['name']}")
                            print(f"Cancelled disabling: {plugin['name']}\n")
                            break
                        else:
                            logger.warning(f"Invalid dependency resolution choice: {choice}")
                            print("Invalid choice. Please enter 1, 2, 3, or C.\n")
                else:
                    logger.info(f"Only soft dependencies found for {plugin['name']}")
                    confirm = input(f"\nDo you still want to disable {plugin['name']}? (Y/N): ").strip().upper()
                    logger.info(f"User confirmation for soft dependency disable: {confirm}")   
                    if confirm == 'Y':
                        try:
                            old_path = plugin['path']
                            new_path = old_path.parent / (old_path.name + ".disabled")
                            old_path.rename(new_path)
                            plugin['path'] = new_path
                            plugin['enabled'] = False
                            logger.info(f"Disabled plugin with soft dependencies: {plugin['name']}")
                            print(f"Disabled: {plugin['name']}")
                        except Exception as e:
                            logger.error(f"Failed to disable {plugin['name']}: {e}")
                            print(f"Error disabling {plugin['name']}: {e}")
                    else:
                        logger.info(f"User skipped disabling {plugin['name']}")
                        print(f"Skipped: {plugin['name']}")
            else:
                logger.info(f"No dependencies found for {plugin['name']}, disabling directly")
                try:
                    old_path = plugin['path']
                    new_path = old_path.parent / (old_path.name + ".disabled")
                    old_path.rename(new_path)
                    plugin['path'] = new_path
                    plugin['enabled'] = False
                    logger.info(f"Disabled plugin without dependencies: {plugin['name']}")
                    print(f"Disabled: {plugin['name']}")
                except Exception as e:
                    logger.error(f"Failed to disable {plugin['name']}: {e}")
                    print(f"Error disabling {plugin['name']}: {e}")
        enabled_after = len([p for p in plugins if p['enabled']])
        disabled_after = len([p for p in plugins if not p['enabled']])
        logger.info(f"Final plugin statistics: {enabled_after} enabled, {disabled_after} disabled")
        logger.info("Plugin state changes completed successfully")
        print("\nPlugin states changed successfully!")
        print("")
    except ValueError:
        logger.error("Invalid input - expected numbers separated by spaces")
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
        logger.error(f"Error toggling plugins: {e}")
        print(f"Error toggling plugins: {e}\n")

def disable_dependency_chain(plugins, target_plugin):
    disabled_plugins = []
    plugins_to_disable = [target_plugin]
    while plugins_to_disable:
        current_plugin = plugins_to_disable.pop(0)
        if not current_plugin['enabled'] or current_plugin in disabled_plugins:
            continue
        try:
            old_path = current_plugin['path']
            new_path = old_path.parent / (old_path.name + ".disabled")
            old_path.rename(new_path)
            current_plugin['path'] = new_path
            current_plugin['enabled'] = False
            disabled_plugins.append(current_plugin)
            print(f"  Disabled: {current_plugin['name']}")
        except Exception as e:
            print(f"  Error disabling {current_plugin['name']}: {e}")
            continue
        for plugin in plugins:
            if plugin['enabled'] and plugin not in disabled_plugins and plugin not in plugins_to_disable:
                dependencies = get_plugin_dependencies(plugin['path'])
                if current_plugin['name'] in dependencies['depend']:
                    plugins_to_disable.append(plugin)
                    print(f"  Queued for disabling (hard dependency): {plugin['name']}")
    return disabled_plugins

def clear_screen():
    if platform.system() == "Windows":
        os.system("cls")
    else:
        os.system("clear")

def get_total_memory():
    try:
        if is_running_in_container():
            container_mem = get_container_memory_limit()
            if container_mem:
                container_mem_gb = container_mem / (1024**3)
                print(f" - Using container memory limit: {container_mem_gb:.1f} GB")
                return container_mem
        if platform.system() == "Windows":
            import ctypes
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            memoryStatus = MEMORYSTATUSEX()
            memoryStatus.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memoryStatus)):
                return memoryStatus.ullTotalPhys
            else:
                return 4 * 1024 * 1024 * 1024
        else:
            try:
                if os.path.exists("/proc/meminfo"):
                    with open("/proc/meminfo", 'r') as f:
                        for line in f:
                            if line.startswith("MemTotal:"):
                                parts = line.split()
                                if len(parts) >= 3:
                                    mem_kb = int(parts[1])
                                    return mem_kb * 1024
                return os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
            except (OSError, ValueError):
                return 4 * 1024 * 1024 * 1024
    except Exception as e:
        print(f" - Warning: Could not determine total memory: {e}")
        return 4 * 1024 * 1024 * 1024

def is_running_in_container():
    if os.path.exists('/.dockerenv'):
        return True
    try:
        if os.path.exists('/proc/1/cgroup'):
            with open('/proc/1/cgroup', 'r') as f:
                content = f.read()
                if 'docker' in content or 'kubepods' in content:
                    return True
    except:
        pass
    container_env_vars = ['KUBERNETES_SERVICE_HOST', 'CONTAINER_ID', 'DOCKER_CONTAINER']
    return any(var in os.environ for var in container_env_vars)

def get_container_memory_limit():
    cgroup_v2_path = "/sys/fs/cgroup/memory.max"
    if os.path.exists(cgroup_v2_path):
        try:
            with open(cgroup_v2_path, 'r') as f:
                limit = f.read().strip()
                if limit.isdigit():
                    limit = int(limit)
                    if limit > 0 and limit < 2**63:
                        return limit
        except:
            pass
    cgroup_v1_path = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
    if os.path.exists(cgroup_v1_path):
        try:
            with open(cgroup_v1_path, 'r') as f:
                limit = int(f.read().strip())
                if limit > 0 and limit < 2**63:
                    return limit
        except:
            pass
    env_vars = ['DOCKER_MEMORY_LIMIT', 'CONTAINER_MEMORY_LIMIT', 'MEMORY_LIMIT']
    for env_var in env_vars:
        if env_var in os.environ:
            try:
                limit_str = os.environ[env_var].upper()
                if limit_str.endswith('G'):
                    return int(limit_str[:-1]) * 1024 * 1024 * 1024
                elif limit_str.endswith('M'):
                    return int(limit_str[:-1]) * 1024 * 1024
                else:
                    return int(limit_str) * 1024 * 1024
            except:
                continue
    return None

def calculate_plugins_memory(enabled_plugins):
    total_plugin_memory = 0
    for plugin_path in enabled_plugins:
        try:
            plugin_size_mb = plugin_path.stat().st_size / (1024 * 1024)
            if plugin_size_mb < 0.5:
                memory = 10
            elif plugin_size_mb < 2:
                memory = 20
            elif plugin_size_mb < 5:
                memory = 35
            elif plugin_size_mb < 10:
                memory = 50
            elif plugin_size_mb < 20:
                memory = 75
            else:
                memory = 100
            plugin_name = plugin_path.stem.lower()
            if any(keyword in plugin_name for keyword in ['world', 'map', 'terrain', 'generate']):
                memory = int(memory * 1.5)
            elif any(keyword in plugin_name for keyword in ['economy', 'shop', 'market', 'vault']):
                memory = int(memory * 0.8)
            total_plugin_memory += memory
        except Exception as e:
            print(f" Error analyzing {plugin_path.name}: {e}")
            total_plugin_memory += 30
    return total_plugin_memory

def calculate_players_memory(max_players, view_distance):
    visible_chunks = view_distance * view_distance
    chunks_per_player_mb = visible_chunks * 0.25
    base_memory_per_player = 50
    total_memory_per_player = base_memory_per_player + chunks_per_player_mb
    if view_distance <= 6:
        memory_multiplier = 0.75
    elif view_distance <= 10:
        memory_multiplier = 1.0
    elif view_distance <= 16:
        memory_multiplier = 1.25
    else:
        memory_multiplier = 1.5
    estimated_online_players = max(1, round(max_players * 0.2))
    players_memory = estimated_online_players * total_memory_per_player * memory_multiplier
    details = {
        'estimated_players': estimated_online_players,
        'view_distance': view_distance,
        'memory_multiplier': memory_multiplier
    }
    return players_memory, details

def validate_memory_allocation(total_mem_mb, allocated_mb, is_container=False):
    if is_container:
        max_allowed = total_mem_mb * 0.85
    else:
        max_allowed = total_mem_mb * 0.9
    if allocated_mb > max_allowed:
        print(f"Warning: Allocated memory {allocated_mb}MB exceeds recommended limit {max_allowed}MB")
        if is_container:
            safe_allocation = min(allocated_mb, total_mem_mb * 0.7)
            print(f"Container environment adjusted to: {safe_allocation}MB")
            return safe_allocation
        else:
            print(f"Adjusted to limit: {max_allowed}MB")
            return max_allowed
    return allocated_mb

def validate_java_path(java_path):
    path = Path(java_path)
    if path.is_file():
        if platform.system() == "Windows":
            if path.name.lower() in ["java.exe", "javaw.exe"]:
                try:
                    result = subprocess.run(
                        [str(path), "-version"],
                        stderr=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        text=True,
                        timeout=2
                    )
                    output = result.stderr or result.stdout
                    if "java version" in output or "openjdk version" in output:
                        return str(path)
                except (subprocess.SubprocessError, OSError):
                    return None
        else:
            if os.access(path, os.X_OK):
                try:
                    result = subprocess.run(
                        [str(path), "-version"],
                        stderr=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        text=True,
                        timeout=2
                    )
                    output = result.stderr or result.stdout
                    if "java version" in output or "openjdk version" in output:
                        return str(path)
                except (subprocess.SubprocessError, OSError):
                    return None
    elif path.is_dir():
        bin_dir = path / "bin"
        if bin_dir.exists():
            if platform.system() == "Windows":
                java_exe = bin_dir / "java.exe"
                if java_exe.exists():
                    return validate_java_path(java_exe)
            else:
                java_exe = bin_dir / "java"
                if java_exe.exists() and os.access(java_exe, os.X_OK):
                    return validate_java_path(java_exe)
        if platform.system() == "Windows":
            java_exe = path / "java.exe"
            if java_exe.exists():
                return validate_java_path(java_exe)
        else:
            java_exe = path / "java"
            if java_exe.exists() and os.access(java_exe, os.X_OK):
                return validate_java_path(java_exe)
    return None

def detect_server_cores():
    if SERVER_JAR.exists():
        print("core.jar already exists. Skipping core detection.")
        return True
    jar_files = list(BASE_DIR.glob("*.jar"))
    if not jar_files:
        print("No JAR files found in current directory.")
        return False
    valid_cores = []
    for jar_file in jar_files:
        try:
            with zipfile.ZipFile(jar_file, 'r') as jar:
                if 'version.json' in jar.namelist():
                    with jar.open('version.json') as f:
                        version_data = json.load(f)
                        version_id = version_data.get("id", "unknown")
                        valid_cores.append({
                            'path': jar_file,
                            'name': jar_file.name,
                            'version': version_id
                        })
                        print(f"Found valid server core: {jar_file.name} (Version: {version_id})")
        except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as e:
            print(f"Skipping {jar_file.name}: Not a valid server core ({e})")
            continue
        except Exception as e:
            print(f"Error checking {jar_file.name}: {e}")
            continue
    if not valid_cores:
        print("No valid server cores found in JAR files.")
        return False
    if len(valid_cores) == 1:
        core = valid_cores[0]
        print(f"Using the only valid server core: {core['name']}")
        shutil.copy2(core['path'], SERVER_JAR)
        print(f"Copied {core['name']} to core.jar")
        return True
    return valid_cores

def select_server_core(cores, auto_mode=False):
    if auto_mode:
        highest_core = None
        highest_version = ""
        for core in cores:
            try:
                if compare_versions(core['version'], highest_version) > 0:
                    highest_core = core
                    highest_version = core['version']
            except:
                if not highest_core:
                    highest_core = core
        if highest_core:
            print(f"Auto-selected highest version: {highest_core['name']} (Version: {highest_core['version']})")
            shutil.copy2(highest_core['path'], SERVER_JAR)
            print(f"Copied {highest_core['name']} to core.jar")
            return True
        else:
            print("Error: Could not auto-select a server core.")
            return False
    else:
        print("\nDetected multiple server cores in current directory:")
        for i, core in enumerate(cores, 1):
            print(f" {i}. {core['name']} (Version: {core['version']})")
        while True:
            try:
                choice = input("\nWhich one would you like to use (leave blank for newest): ").strip()
                if not choice:
                    highest_core = None
                    highest_version = ""
                    for core in cores:
                        try:
                            if compare_versions(core['version'], highest_version) > 0:
                                highest_core = core
                                highest_version = core['version']
                        except:
                            if not highest_core:
                                highest_core = core
                    if highest_core:
                        print(f"Selected newest version: {highest_core['name']} (Version: {highest_core['version']})")
                        shutil.copy2(highest_core['path'], SERVER_JAR)
                        print(f"Copied {highest_core['name']} to core.jar")
                        return True
                    else:
                        print("Error: Could not determine newest version.")
                        return False
                index = int(choice) - 1
                if 0 <= index < len(cores):
                    selected_core = cores[index]
                    print(f"Selected: {selected_core['name']} (Version: {selected_core['version']})")
                    shutil.copy2(selected_core['path'], SERVER_JAR)
                    print(f"Copied {selected_core['name']} to core.jar")
                    return True
                else:
                    print(f"Please enter a number between 1 and {len(cores)}")
            except ValueError:
                print("Please enter a valid number or leave blank for newest.")
            except Exception as e:
                print(f"Error selecting server core: {e}")
                return False

def init_config(prefill_version=None):
    logger.info("Starting manual server initialization")
    print("=" * 50)
    print("         Minecraft Server Initialization")
    print("=" * 50)
    if CONFIG_FILE.exists():
        logger.warning("Configuration file already exists, will be overwritten")
        print("\nConfiguration file already exists!")
        print("This will replace your current configuration.")
        confirm = input("\nDo you want to continue? (Y/N): ").strip().upper()
        if confirm != "Y":
            logger.info("User cancelled initialization, existing configuration preserved")
            print("\nOperation canceled.\nExisting configuration preserved.\n")
            return
    logger.info("Checking for server core files...")
    print("\nChecking for server core files...")
    core_result = detect_server_cores()
    if core_result is True:
        logger.info("Server core already exists as core.jar")
        pass
    elif isinstance(core_result, list) and len(core_result) > 0:
        logger.info(f"Found {len(core_result)} server core(s)")
        if not select_server_core(core_result, auto_mode=False):
            logger.error("Failed to select server core in manual initialization")
            print("Failed to select server core. Please check your JAR files.")
            return
        else:
            logger.info("Successfully selected server core")
    elif core_result is False:
        logger.error("No valid server cores found for manual initialization")
        print("No valid server cores found.")
        print("Please make sure you have server JAR files in the current directory.")
        return
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser()
    version = prefill_version
    if prefill_version:
        logger.info(f"Using prefill version: {version}")
        print(f"\nUsing version: {version}")
    else:
        detected_version = "unknown"
        if SERVER_JAR.exists():
            try:
                with zipfile.ZipFile(SERVER_JAR, 'r') as jar:
                    with jar.open('version.json') as f:
                        data = json.load(f)
                        detected_version = data.get("id", "unknown")
                        logger.info(f"Detected version from core.jar: {detected_version}")
            except Exception as e:
                logger.warning(f"Could not detect version from core.jar: {e}")
        if detected_version != "unknown":
            logger.info(f"Detected server version: {detected_version}")
            print(f"\nDetected server version: {detected_version}")
            use_detected = input("Use this version? (Y/N): ").strip().upper()
            if use_detected == "Y":
                version = detected_version
                logger.info("User accepted detected version")
            else:
                logger.info("User declined detected version, will prompt for version")
                while True:
                    version = input("\nEnter Minecraft server version (e.g., 1.21.5 or 1.21): ").strip()
                    if re.match(r"^\d+\.\d+(\.\d+)?$", version):
                        logger.info(f"User entered version: {version}")
                        break
                    logger.warning(f"Invalid version format entered: {version}")
                    print("Invalid version format. Use format like 1.21.5 or 1.21")
        else:
            logger.warning("Could not detect version from core.jar")
            while True:
                version = input("\nEnter Minecraft server version (e.g., 1.21.5 or 1.21): ").strip()
                if re.match(r"^\d+\.\d+(\.\d+)?$", version):
                    logger.info(f"User entered version: {version}")
                    break
                logger.warning(f"Invalid version format entered: {version}")
                print("Invalid version format. Use format like 1.21.5 or 1.21")
    while True:
        ram_input = input("\nSet maximum RAM (e.g., 4096 for 4GB, or 4 for 4GB): ").strip()
        if ram_input.isdigit():
            ram_value = int(ram_input)
            if ram_value < 256:
                max_ram = ram_value * 1024
                logger.info(f"Converted {ram_value} GB to {max_ram} MB")
                print(f"Converted {ram_value} GB to {max_ram} MB")
            else:
                max_ram = ram_value
            if max_ram < 512:
                logger.warning(f"Low RAM allocation requested: {max_ram} MB")
                print("Warning: Allocating less than 512MB may cause server instability!")
                confirm = input("Continue anyway? (Y/N): ").strip().upper()
                if confirm == "Y":
                    logger.info("User confirmed low RAM allocation")
                    break
                else:
                    logger.info("User cancelled low RAM allocation")
            else:
                break
        else:
            logger.warning(f"Invalid RAM input: {ram_input}")
            print("Invalid RAM size. Must be a positive integer")
    logger.info(f"RAM allocation set to: {max_ram} MB")
    print(f"\nAllocated RAM: {max_ram} MB ({max_ram/1024:.1f} GB)")
    print("\nYou can add additional files/directories to exclude from backups.")
    print("These will be added to the base exclusion list.")
    additional_exclude = input("Enter additional exclusions (comma-separated, leave empty if none): ").strip()
    if additional_exclude:
        logger.info(f"Additional exclusions entered: {additional_exclude}")
    else:
        logger.info("No additional exclusions entered")
    java_path = None
    logger.info("Selecting Java installation")
    while java_path is None:
        java_installations = find_java_installations()
        if not java_installations:
            logger.error("No Java installations found!")
            print("Error: No Java installations found! Please install Java first.\n")
            sys.exit(1)
        logger.info(f"Found {len(java_installations)} Java installations")
        print("\n" + format_java_table(java_installations))
        while True:
            try:
                choice = input(f"\nSelect Java installation (0-{len(java_installations)}): ").strip()
                if choice == "0":
                    logger.info("User chose custom Java path")
                    custom_path = input("\nEnter Java path (can be Java home or bin directory): ").strip()
                    if not custom_path:
                        logger.warning("No custom Java path entered")
                        print("No path entered. Please try again.")
                        continue
                    logger.info(f"Validating custom Java path: {custom_path}")
                    print("Validating Java...")
                    validated_path = validate_java_path(custom_path)
                    if validated_path:
                        java_path = validated_path
                        logger.info(f"Custom Java path validated successfully: {java_path}")
                        print("Validated successfully.")
                        break
                    else:
                        logger.warning(f"Invalid custom Java path: {custom_path}")
                        print("Invalid Java path or Java not found. Please check the path and try again.")
                        print("Make sure the path points to a valid Java installation.")
                        continue
                else:
                    choice_num = int(choice)
                    if 1 <= choice_num <= len(java_installations):
                        java_path = java_installations[choice_num-1]['path']
                        logger.info(f"Selected Java installation: {java_path}")
                        break
                    logger.warning(f"Invalid Java selection: {choice}")
                    print("Invalid selection.")
            except ValueError:
                logger.error("Invalid input for Java selection")
                print("Please enter a number.")
    print("\nYou can add additional server parameters (e.g., -nogui, --force-upgrade, etc.)")
    print("These will be appended after the default parameters.")
    additional_params = input("Enter additional parameters (leave empty if none): ").strip()
    if additional_params:
        logger.info(f"Additional parameters entered: {additional_params}")
    else:
        logger.info("No additional parameters entered")
    device_id = get_device_id()
    logger.info(f"Generated device ID: {device_id}")
    config["SERVER"] = {
        "version": version,
        "max_ram": str(max_ram),
        "java_path": java_path,
        "device": device_id
    }
    if additional_exclude:
        config["SERVER"]["additional_list"] = additional_exclude
    else:
        config["SERVER"]["additional_list"] = ""
    if additional_params:
        config["SERVER"]["additional_parameters"] = additional_params
    else:
        config["SERVER"]["additional_parameters"] = ""
    try:
        with open(CONFIG_FILE, "w") as f:
            config.write(f)
        logger.info(f"Configuration saved to {CONFIG_FILE}")
        print(f"\nConfiguration saved to {CONFIG_FILE}")
        show_info()
    except Exception as e:
        logger.error(f"Failed to save configuration: {e}")
        print(f"Error saving configuration: {e}\n")

def init_config_auto(prefill_version=None):
    logger.info("Starting automatic server initialization")
    start_time = time.time()
    print("=" * 50)
    print("         Automatic Server Initialization")
    print("=" * 50)
    if CONFIG_FILE.exists():
        logger.info("Configuration file already exists, will be overwritten")
        print("\nConfiguration file already exists. Overwriting...")
    logger.info("Checking for server core files...")
    print("\nChecking for server core files...")
    core_result = detect_server_cores()
    if core_result is True:
        logger.info("Server core already exists as core.jar")
        pass
    elif isinstance(core_result, list) and len(core_result) > 0:
        logger.info(f"Found {len(core_result)} server core(s), auto-selecting...")
        if not select_server_core(core_result, auto_mode=True):
            logger.error("Failed to auto-select server core")
            print("Failed to auto-select server core.")
            return
        else:
            logger.info("Successfully auto-selected server core")
    elif core_result is False:
        logger.error("No valid server cores found")
        print("No valid server cores found.")
        print("Please make sure you have server JAR files in the current directory.")
        print("The JAR files should contain a version.json file to be recognized as server cores.")
        return
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser()
    version = prefill_version
    java_required = 8
    if not version and SERVER_JAR.exists():
        try:
            with zipfile.ZipFile(SERVER_JAR, 'r') as jar:
                with jar.open('version.json') as f:
                    data = json.load(f)
                    version = data.get("id", "unknown")
                    java_required = int(data.get("java_version", 8))
                    logger.info(f"Detected version from core.jar: {version}, Java required: {java_required}")
        except Exception as e:
            logger.warning(f"Could not detect version from core.jar: {e}")
            version = "unknown"
            java_required = 8
    elif version and SERVER_JAR.exists():
        try:
            with zipfile.ZipFile(SERVER_JAR, 'r') as jar:
                with jar.open('version.json') as f:
                    data = json.load(f)
                    java_required = int(data.get("java_version", 8))
                    logger.info(f"Using prefill version: {version}, Java required: {java_required}")
        except Exception:
            java_required = 8
            logger.warning(f"Could not detect Java requirement, defaulting to Java {java_required}")
    if version != "unknown":
        logger.info(f"Using detected version: {version}")
        print(f"\nUsing detected version from core.jar: {version}")
    else:
        logger.warning(f"Could not detect version from core.jar, using: {version}")
        print(f"\nCould not detect version from core.jar, using: {version}")
    print(f"Required Java version: {java_required}")
    logger.info(f"Finding Java installations (required: Java {java_required})")
    java_installations = find_java_installations()
    available_versions = [int(j['version']) for j in java_installations if j['version'].isdigit()]
    java_path = None
    if not available_versions:
        logger.warning("No Java installations found!")
        print("\nNo Java installations found!")
        custom = input("Would you like to specify a custom Java path? (Y/N): ").strip().upper()
        if custom == "Y":
            while True:
                custom_path = input("Enter custom Java path: ").strip()
                validated = validate_java_path(custom_path)
                if validated:
                    java_path = validated
                    logger.info(f"Using custom Java path: {java_path}")
                    break
                else:
                    logger.warning(f"Invalid Java path: {custom_path}")
                    print("Invalid path. Try again.")
        else:
            logger.error("No Java available, exiting auto initialization")
            print("Exiting auto initialization.")
            return
    else:
        logger.info(f"Found {len(java_installations)} Java installation(s)")
        found = False
        test_ver = java_required
        while not found:
            for j in java_installations:
                if j["version"].isdigit() and int(j["version"]) == test_ver:
                    java_path = j["path"]
                    found = True
                    logger.info(f"Found matching Java {test_ver} at: {java_path}")
                    break
            if not found:
                test_ver += 1
                if test_ver > 25:
                    break
        if not java_path:
            logger.error(f"No suitable Java version found (required: {java_required})")
            print(f"No suitable Java version found up to Java {test_ver}.")
            print("Exiting auto initialization.")
            return
    logger.info("Detecting available memory...")
    print("\nDetecting available memory...")
    total_mem_bytes = get_total_memory()
    total_mem_gb = total_mem_bytes / (1024 ** 3)
    total_mem_mb = total_mem_gb * 1024
    is_container = is_running_in_container()
    if is_container:
        logger.info("Running in container environment")
        print(" - Running in container environment")
    logger.info(f"Total available memory: {total_mem_mb:.0f} MB ({total_mem_gb:.1f} GB)")
    print(f"Total available memory: {total_mem_mb:.0f} MB ({total_mem_gb:.1f} GB)")
    if total_mem_mb < 512:
        logger.error(f"Insufficient memory: {total_mem_mb:.0f} MB (< 512 MB)")
        print("\nERROR: Available memory is less than 512MB.")
        print("The server will likely crash due to insufficient memory.")
        print("Please use manual initialization (--init) to allocate memory carefully.")
        return
    if total_mem_mb <= 8192:
        base_ram_mb = (29 * total_mem_mb + 8192) / 60
        base_ram_mb = round(base_ram_mb)
    else:
        base_ram_mb = 4096
    logger.info(f"Base allocation calculated: {base_ram_mb} MB")
    print(f"Base allocation: {base_ram_mb} MB")
    plugins_ram_mb = 0
    plugins_dir = BASE_DIR / "plugins"
    if plugins_dir.exists():
        enabled_plugins = list(plugins_dir.glob("*.jar"))
        disabled_plugins = list(plugins_dir.glob("*.jar.disabled"))
        total_plugins = len(enabled_plugins) + len(disabled_plugins)
        enabled_count = len(enabled_plugins)
        logger.info(f"Found {enabled_count} enabled plugins out of {total_plugins} total")
        print(f"\nAnalyzing {enabled_count} enabled plugins:")
        plugins_ram_mb = calculate_plugins_memory(enabled_plugins)
        logger.info(f"Plugins memory allocation: {plugins_ram_mb} MB")
        print(f"Total plugins allocation: {plugins_ram_mb} MB")
    max_players = 20
    view_distance = 10
    if SERVER_PROPERTIES.exists():
        try:
            with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('max-players='):
                        try:
                            max_players = int(line.split('=')[1])
                        except ValueError:
                            pass
                    elif line.startswith('view-distance='):
                        try:
                            view_distance = int(line.split('=')[1])
                        except ValueError:
                            pass
            logger.info(f"Loaded server properties: max-players={max_players}, view-distance={view_distance}")
        except Exception as e:
            logger.warning(f"Error reading server.properties: {e}")
    players_ram_mb, player_details = calculate_players_memory(max_players, view_distance)
    logger.info(f"Players memory allocation: {players_ram_mb:.1f} MB (max_players={max_players}, view_distance={view_distance})")
    print(f"\nPlayer allocation details:")
    print(f" - Estimated players: {player_details['estimated_players']}")
    print(f" - View distance: {player_details['view_distance']}")
    print(f" - Multiplier: {player_details['memory_multiplier']}")
    print(f" - Total allocation: {players_ram_mb:.1f} MB")
    total_allocated_mb = base_ram_mb + plugins_ram_mb + players_ram_mb
    logger.info(f"Total memory allocation before validation: {total_allocated_mb:.1f} MB")
    print(f"\nMemory allocation breakdown:")
    print(f" - Base: {base_ram_mb} MB")
    print(f" - Plugins: {plugins_ram_mb} MB")
    print(f" - Players: {players_ram_mb:.1f} MB")
    print(f" - Total: {total_allocated_mb:.1f} MB")
    total_allocated_mb = validate_memory_allocation(total_mem_mb, total_allocated_mb, is_container)
    final_ram_mb = int(total_allocated_mb)
    logger.info(f"Final allocated RAM after validation: {final_ram_mb} MB")
    print(f"\nFinal allocated RAM: {final_ram_mb} MB ({final_ram_mb/1024:.1f} GB)")
    device_id = get_device_id()
    logger.info(f"Generated device ID: {device_id}")
    config["SERVER"] = {
        "version": version,
        "max_ram": str(final_ram_mb),
        "java_path": java_path,
        "device": device_id,
        "additional_list": " ",
        "additional_parameters": " "
    }
    with open(CONFIG_FILE, "w") as f:
        config.write(f)
    logger.info(f"Auto configuration saved to {CONFIG_FILE}")
    print(f"\nAuto configuration saved to {CONFIG_FILE}")
    show_info()
    elapsed_time = time.time() - start_time
    logger.info(f"Auto initialization completed in {elapsed_time:.2f}s")
    print(f"Auto initialization completed in {elapsed_time:.2f}s!\n")

def find_java_installations():
    java_installations = []
    search_paths = [
        "/usr/bin/java",
        "/usr/lib/jvm/*/bin/java",
        "/usr/lib/jvm/*/jre/bin/java",
        "/usr/lib/jvm/java-*-openjdk*/bin/java",
        "/usr/lib/jvm/java-*-openjdk*/jre/bin/java",
        "/opt/java/*/bin/java",
        "/opt/java/*/jre/bin/java",
        "/usr/local/bin/java",
        "/usr/local/lib/jvm/*/bin/java",
        "/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java",
        "/System/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java",
        "/Users/*/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java",
        "C:\\Program Files\\Java\\*\\bin\\java.exe",
        "C:\\Program Files (x86)\\Java\\*\\bin\\java.exe",
        "C:\\Java\\*\\bin\\java.exe",
        "C:\\jdk*\\bin\\java.exe",
        "C:\\jre*\\bin\\java.exe",
    ]
    for path in search_paths:
        for match in glob.glob(path):
            if os.path.exists(match) and os.access(match, os.X_OK):
                real_path = os.path.realpath(match)
                try:
                    result = subprocess.run(
                        [real_path, "-version"],
                        stderr=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        text=True,
                        timeout=2
                    )
                    output = result.stderr or result.stdout
                    if "java version" in output or "openjdk version" in output:
                        version, vendor = parse_java_version(output)
                        java_installations.append({
                            'path': real_path,
                            'version': version,
                            'vendor': vendor
                        })
                except:
                    continue
    try:
        if platform.system() == "Windows":
            result = subprocess.run(
                ["where", "java"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5
            )
            paths = result.stdout.strip().split('\n')
        else:
            result = subprocess.run(
                ["which", "-a", "java"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5
            )
            paths = result.stdout.strip().split('\n')
        for path in paths:
            path = path.strip()
            if path and os.path.exists(path) and os.access(path, os.X_OK):
                real_path = os.path.realpath(path)
                if not any(install['path'] == real_path for install in java_installations):
                    try:
                        result = subprocess.run(
                            [real_path, "-version"],
                            stderr=subprocess.PIPE,
                            stdout=subprocess.PIPE,
                            text=True,
                            timeout=2
                        )
                        output = result.stderr or result.stdout
                        if "java version" in output or "openjdk version" in output:
                            version, vendor = parse_java_version(output)
                            java_installations.append({
                                'path': real_path,
                                'version': version,
                                'vendor': vendor
                            })
                    except:
                        continue
    except:
        pass
    java_home = os.environ.get('JAVA_HOME')
    if java_home:
        java_path = os.path.join(java_home, 'bin', 'java')
        if platform.system() == "Windows":
            java_path += ".exe"
        if os.path.exists(java_path) and os.access(java_path, os.X_OK):
            real_path = os.path.realpath(java_path)
            if not any(install['path'] == real_path for install in java_installations):
                try:
                    result = subprocess.run(
                        [real_path, "-version"],
                        stderr=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        text=True,
                        timeout=2
                    )
                    output = result.stderr or result.stdout
                    if "java version" in output or "openjdk version" in output:
                        version, vendor = parse_java_version(output)
                        java_installations.append({
                            'path': real_path,
                            'version': version,
                            'vendor': vendor
                        })
                except:
                    pass
    unique_installations = []
    seen_paths = set()
    for install in java_installations:
        if install['path'] not in seen_paths:
            seen_paths.add(install['path'])
            unique_installations.append(install)
    def version_key(install):
        version = install['version']
        try:
            return int(version)
        except (ValueError, TypeError):
            return -1
    unique_installations.sort(key=version_key, reverse=True)
    return unique_installations

def parse_java_version(output):
    lines = output.strip().split('\n')
    if not lines:
        return "Unknown", "Unknown"
    first_line = lines[0]
    version_match = re.search(r'version\s+"([^"]+)"', first_line)
    if not version_match:
        version_match = re.search(r'(\d+\.\d+\.\d+|\d+)', first_line)
    version = "Unknown"
    if version_match:
        version_str = version_match.group(1)
        if version_str.startswith('1.'):
            parts = version_str.split('.')
            if len(parts) >= 2:
                version = parts[1]
        else:
            major_match = re.search(r'^(\d+)', version_str)
            if major_match:
                version = major_match.group(1)
    vendor = "Unknown"
    if len(lines) > 1:
        second_line = lines[1]
        if "OpenJDK" in second_line:
            vendor = "OpenJDK"
        elif "GraalVM" in second_line:
            vendor = "GraalVM"
        elif "Java(TM) SE" in second_line:
            vendor = "Oracle JDK"
        elif "Eclipse Temurin" in second_line:
            vendor = "Temurin"
        elif "Zulu" in second_line:
            vendor = "Zulu"
        elif "Microsoft" in second_line:
            vendor = "Microsoft"
        elif "Amazon Corretto" in second_line:
            vendor = "Corretto"
    return version, vendor

def load_config():
    if not CONFIG_FILE.exists():
        logger.error("Configuration file not found")
        print(f"\nError: Configuration file not found at {CONFIG_FILE}")
        print("Please run with --init to create a new configuration\n")
        sys.exit(1)
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    if "SERVER" not in config:
        logger.error("Invalid configuration format")
        print("Error: Invalid configuration format")
        sys.exit(1)
    return config["SERVER"]

def show_info():
    try:
        config = load_config()
        version = config.get("version", "Unknown")
        max_ram_mb = config.get("max_ram", "Unknown")
        java_path = config.get("java_path", "Not set")
        additional_list = config.get("additional_list", "None")
        additional_params = config.get("additional_parameters", "None")
        if max_ram_mb != "Unknown":
            max_ram_gb = int(max_ram_mb) / 1024
            ram_display = f"{max_ram_mb} MB ({max_ram_gb:.1f} GB)"
        else:
            ram_display = "Unknown"
        print("\nServer Configuration:")
        print("=" * 50)
        print(f"Minecraft Version: {version}")
        print(f"Max RAM: {ram_display}")
        print(f"Java Path: {java_path}")
        print(f"Additional Exclusions: {additional_list}")
        print(f"Additional Parameters: {additional_params}")
        print("=" * 50)
        print("")
    except Exception as e:
        print(f"Error loading configuration: {e}\n")
        sys.exit(1)

def list_versions():
    BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
    versions = [d.name for d in BUNDLES_DIR.iterdir() if d.is_dir()]
    if not versions:
        logger.info("No versions available in bundles directory")
        print("\nNo versions available in bundles directory\n")
        return
    exclude_list = get_exclude_list()
    print("\nAvailable Versions:")
    print("=" * 30)
    for version in sorted(versions, key=lambda v: [int(n) for n in v.split(".")]):
        zip_files = list((BUNDLES_DIR / version).glob("*.zip"))
        if zip_files:
            status = f"| ({len(zip_files)} backups)"
        else:
            status = "✗ (no backups)"
        print(f" - {version} {status}")
    print("=" * 30)
    print("\nExclusion List:")
    print("=" * 30)
    for i, item in enumerate(exclude_list, 1):
        print(f" {i}. {item}")
    print("=" * 30)
    print("")

def save_version(version):
    if not version:
        logger.error("No version specified in save_version")
        print("Usage: --save <version>")
        return
    logger.info(f"Starting save_version function for version: {version}")
    if not create_lock(["--save", version]):
        logger.error("Failed to create lock for save_version operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info(f"Attempting to load configuration for save_version {version}")
        config = load_config()
        current_version = config.get("version", "unknown")
        logger.info(f"Current server version from config: {current_version}")
    except:
        logger.error("Failed to load configuration, using default version 'unknown'")
        current_version = "unknown"
        print("Warning: Could not load config, using default version 'unknown'")
    target_dir = BUNDLES_DIR / version
    logger.info(f"Target directory for version {version}: {target_dir}")
    target_dir.mkdir(parents=True, exist_ok=True)
    logger.info(f"Ensured target directory exists: {target_dir}")
    zip_path = target_dir / "server.zip"
    logger.info(f"Zip file path: {zip_path}")
    print(f"\nSaving current version ({current_version}) as {version}...")
    logger.info(f"Saving current version {current_version} as {version}")
    temp_dir = BASE_DIR / "temp_save"
    logger.info(f"Temporary directory for save operation: {temp_dir}")
    if temp_dir.exists():
        logger.info(f"Temporary directory already exists, removing: {temp_dir}")
        shutil.rmtree(temp_dir)
    temp_dir.mkdir(exist_ok=True)
    logger.info(f"Created temporary directory: {temp_dir}")
    exclude_list = get_exclude_list()
    logger.info(f"Using exclude list with {len(exclude_list)} patterns for save operation")
    logger.info(f"Exclude list patterns: {exclude_list}")
    try:
        logger.info("Starting file copy process to temporary directory")
        copied_count = 0
        skipped_count = 0
        for item in BASE_DIR.iterdir():
            item_name = item.name
            if any(fnmatch.fnmatch(item_name, pattern) for pattern in exclude_list):
                skipped_count += 1
                continue
            dest = temp_dir / item_name
            try:
                if item.is_dir():
                    if hasattr(shutil, 'copytree') and hasattr(shutil.copytree, '__code__'):
                        import inspect
                        sig = inspect.signature(shutil.copytree)
                        if 'dirs_exist_ok' in sig.parameters:
                            shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
                        else:
                            if dest.exists():
                                logger.info(f"Removing existing destination directory: {dest}")
                                shutil.rmtree(dest)
                            shutil.copytree(item, dest, symlinks=True)
                            logger.info(f"Copied directory (legacy method): {item_name}")
                    else:
                        if dest.exists():
                            logger.info(f"Removing existing destination directory: {dest}")
                            shutil.rmtree(dest)
                        shutil.copytree(item, dest, symlinks=True)
                        logger.info(f"Copied directory (fallback method): {item_name}")
                else:
                    shutil.copy2(item, dest)
                copied_count += 1
            except Exception as copy_error:
                logger.error(f"Failed to copy {item_name}: {copy_error}")
                skipped_count += 1
        logger.info(f"File copy completed: {copied_count} items copied, {skipped_count} items skipped")
        logger.info(f"Creating ZIP archive: {zip_path}")
        zip_file_count = 0
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            logger.info("Opened ZIP file for writing")
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, temp_dir)
                    zipf.write(file_path, arcname)
                    zip_file_count += 1
                    if zip_file_count % 100 == 0:
                        logger.info(f"Added {zip_file_count} files to ZIP archive")
        zip_size = os.path.getsize(zip_path)
        logger.info(f"ZIP archive created successfully: {zip_path}, size: {format_file_size(zip_size)}, files: {zip_file_count}")
        print(f"Version {version} saved successfully to {zip_path}\n")
        logger.info(f"Version {version} saved successfully")
    except Exception as e:
        logger.error(f"Error saving version: {e}", exc_info=True)
        print(f"Error saving version: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            logger.info(f"Cleaning up temporary directory: {temp_dir}")
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info(f"Successfully removed temporary directory: {temp_dir}")
            except Exception as cleanup_error:
                logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        logger.info("Removing task lock for save_version operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock")

def backup_version():
    logger.info("Starting backup_version function")
    if not create_lock(["--backup"]):
        logger.error("Failed to create lock for backup operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Attempting to load configuration for backup_version")
        config = load_config()
        version = config.get("version", "unknown")
        logger.info(f"Current server version from config: {version}")
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        print("Error: Could not load configuration to determine current version\n")
        remove_lock()
        return
    target_dir = BUNDLES_DIR / version
    logger.info(f"Target directory for version {version}: {target_dir}")
    target_dir.mkdir(parents=True, exist_ok=True)
    logger.info(f"Ensured target directory exists: {target_dir}")
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    zip_name = f"{version}_{timestamp}.zip"
    zip_path = target_dir / zip_name
    logger.info(f"Backup zip file path: {zip_path}")
    print(f"\nCreating backup of current version ({version})...")
    logger.info(f"Creating backup of current version {version}")
    temp_dir = BASE_DIR / "temp_backup"
    logger.info(f"Temporary directory for backup operation: {temp_dir}")
    if temp_dir.exists():
        logger.info(f"Temporary directory already exists, removing: {temp_dir}")
        shutil.rmtree(temp_dir)
    temp_dir.mkdir(exist_ok=True)
    logger.info(f"Created temporary directory: {temp_dir}")
    exclude_list = get_exclude_list()
    logger.info(f"Using exclude list with {len(exclude_list)} patterns for backup operation")
    try:
        logger.info("Starting file copy process to temporary directory")
        copied_count = 0
        skipped_count = 0
        for item in BASE_DIR.iterdir():
            item_name = item.name
            if any(fnmatch.fnmatch(item_name, pattern) for pattern in exclude_list):
                skipped_count += 1
                logger.info(f"Skipped item (excluded): {item_name}")
                continue
            dest = temp_dir / item_name
            try:
                if item.is_dir():
                    if hasattr(shutil, 'copytree') and hasattr(shutil.copytree, '__code__'):
                        import inspect
                        sig = inspect.signature(shutil.copytree)
                        if 'dirs_exist_ok' in sig.parameters:
                            shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
                        else:
                            if dest.exists():
                                logger.info(f"Removing existing destination directory: {dest}")
                                shutil.rmtree(dest)
                            shutil.copytree(item, dest, symlinks=True)
                            logger.info(f"Copied directory (legacy method): {item_name}")
                    else:
                        if dest.exists():
                            logger.info(f"Removing existing destination directory: {dest}")
                            shutil.rmtree(dest)
                        shutil.copytree(item, dest, symlinks=True)
                        logger.info(f"Copied directory (fallback method): {item_name}")
                else:
                    shutil.copy2(item, dest)
                    logger.info(f"Copied file: {item_name}")
                copied_count += 1
            except Exception as copy_error:
                logger.error(f"Failed to copy {item_name}: {copy_error}")
                skipped_count += 1
        logger.info(f"File copy completed: {copied_count} items copied, {skipped_count} items skipped")
        logger.info(f"Creating ZIP archive: {zip_path}")
        zip_file_count = 0
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            logger.info("Opened ZIP file for writing")
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, temp_dir)
                    zipf.write(file_path, arcname)
                    zip_file_count += 1
                    if zip_file_count % 100 == 0:
                        logger.info(f"Added {zip_file_count} files to ZIP archive")
        zip_size = os.path.getsize(zip_path)
        logger.info(f"ZIP archive created successfully: {zip_path}, size: {format_file_size(zip_size)}, files: {zip_file_count}")
        print(f"Backup created successfully: {zip_path}\n")
        logger.info(f"Backup created successfully: {zip_path}")
    except Exception as e:
        logger.error(f"Error creating backup: {e}", exc_info=True)
        print(f"Error creating backup: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            logger.info(f"Cleaning up temporary directory: {temp_dir}")
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info(f"Successfully removed temporary directory: {temp_dir}")
            except Exception as cleanup_error:
                logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        logger.info("Removing task lock for backup operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock")

def delete_version(version):
    logger.info(f"Starting delete_version function for version: {version}")
    if not version:
        logger.error("No version specified in delete_version")
        print("Usage: --delete <version>")
        return
    if not create_lock(["--delete", version]):
        logger.error("Failed to create lock for delete operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        target_dir = BUNDLES_DIR / version
        logger.info(f"Target directory to delete: {target_dir}")
        if not target_dir.exists():
            logger.warning(f"Version {version} does not exist at path: {target_dir}")
            print("")
            print(f"Version {version} does not exist")
            print("")
            remove_lock()
            return
        logger.info(f"Version {version} found at: {target_dir}")
        try:
            total_size = 0
            file_count = 0
            for root, dirs, files in os.walk(target_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    total_size += os.path.getsize(file_path)
                    file_count += 1
            logger.info(f"Version {version} contains {file_count} files, total size: {format_file_size(total_size)}")
        except Exception as size_error:
            logger.warning(f"Could not calculate directory size for {version}: {size_error}")
        
        confirm = input(f"\nAre you sure you want to delete version '{version}'? (Y/N): ")
        logger.info(f"User confirmation prompt for deleting version {version}: {confirm}")
        if confirm != "Y":
            logger.info(f"User cancelled deletion of version {version}")
            print("Deletion canceled\n")
            remove_lock()
            return
        logger.info(f"User confirmed deletion of version {version}")
        print(f"\nDeleting version {version}...")
        try:
            if logger.isEnabledFor(logging.DEBUG):
                logger.info(f"Contents of {target_dir} before deletion:")
                for root, dirs, files in os.walk(target_dir):
                    for file in files:
                        file_path = os.path.join(root, file)
                        try:
                            file_size = os.path.getsize(file_path)
                            logger.info(f"  {os.path.relpath(file_path, target_dir)} - {format_file_size(file_size)}")
                        except:
                            logger.info(f"  {os.path.relpath(file_path, target_dir)} - size unknown")
            shutil.rmtree(target_dir)
            logger.info(f"Successfully deleted version {version} from {target_dir}")
            print(f"Version {version} deleted successfully\n")
            
        except Exception as delete_error:
            logger.error(f"Error deleting version {version}: {delete_error}", exc_info=True)
            print(f"Error deleting version: {delete_error}\n")
    except Exception as e:
        logger.error(f"Unexpected error in delete_version function: {e}", exc_info=True)
        print(f"Error deleting version: {e}\n")
    finally:
        logger.info("Removing task lock for delete operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock for delete operation")

def change_version(target_version):
    logger.info(f"Starting change_version function for target version: {target_version}")
    if not target_version:
        logger.error("No target version specified in change_version")
        print("Usage: --change <version>")
        return
    if not create_lock(["--change", target_version]):
        logger.error("Failed to create lock for change version operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Checking if configuration file exists")
        if not CONFIG_FILE.exists():
            logger.error("Configuration file not found for change version")
            print("\nConfiguration file not found! Run with --init first.\n")
            remove_lock()
            return
        logger.info("Reading configuration file")
        config = configparser.ConfigParser()
        config.read(CONFIG_FILE)
        if "SERVER" not in config:
            logger.warning("Configuration file missing [SERVER] section, creating default...")
            print("\nWarning: Configuration file missing [SERVER] section. Creating default...\n")
            config["SERVER"] = {}
        current_version = config["SERVER"].get("version", "unknown")
        logger.info(f"Current server version: {current_version}, target version: {target_version}")
        logger.info(f"Saving current version {current_version} before switching")
        print(f"Saving current version {current_version}...")
        save_version(current_version)
        zip_path = BUNDLES_DIR / target_version / "server.zip"
        logger.info(f"Looking for target version zip file at: {zip_path}")
        if not zip_path.exists():
            logger.error(f"Target version {target_version} not found at {zip_path}")
            print(f"Version {target_version} not found")
            print("")
            remove_lock()
            return
        logger.info(f"Target version found: {zip_path}")
        print(f"Switching to version {target_version}...")
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns for cleanup")
        logger.info(f"Exclude patterns: {exclude_list}")
        logger.info("Starting cleanup of current directory")
        deleted_count = 0
        skipped_count = 0
        for item in BASE_DIR.iterdir():
            item_name = item.name
            if any(fnmatch.fnmatch(item_name, pattern) for pattern in exclude_list):
                skipped_count += 1
                logger.info(f"Skipped item (excluded): {item_name}")
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
                deleted_count += 1
            except Exception as cleanup_error:
                logger.error(f"Failed to remove {item_name}: {cleanup_error}")
                skipped_count += 1
        logger.info(f"Cleanup completed: {deleted_count} items removed, {skipped_count} items skipped")
        logger.info(f"Extracting target version from: {zip_path}")
        try:
            with zipfile.ZipFile(zip_path, "r") as zipf:
                file_count = 0
                for info in zipf.infolist():
                    zipf.extract(info, BASE_DIR)
                    file_count += 1
                    if file_count % 100 == 0:
                        logger.info(f"Extracted {file_count} files...")
                logger.info(f"Successfully extracted {file_count} files from {zip_path}")
        except Exception as extract_error:
            logger.error(f"Error extracting version {target_version}: {extract_error}", exc_info=True)
            print(f"Error switching version: {extract_error}\n")
            remove_lock()
            return
        logger.info("Updating configuration file with new version")
        if not CONFIG_FILE.exists():
            logger.warning("No config file found in target version, creating default...")
            print("\nWarning: No config file found in target version. Creating default...\n")
            CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
            config["SERVER"] = {"version": target_version}
        else:
            config = configparser.ConfigParser()
            config.read(CONFIG_FILE)
            if "SERVER" not in config:
                config["SERVER"] = {}
            config["SERVER"]["version"] = target_version
            logger.info(f"Updated configuration: version = {target_version}")
        with open(CONFIG_FILE, "w") as f:
            config.write(f)
        logger.info(f"Configuration file saved: {CONFIG_FILE}")
        print(f"Successfully switched to version {target_version}")
        logger.info(f"Successfully switched from version {current_version} to {target_version}")
        show_info()
    except Exception as e:
        logger.error(f"Error switching version: {e}", exc_info=True)
        print(f"Error switching version: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        logger.info("Removing task lock for change version operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock for change version operation")

def cleanup_files():
    if not create_lock(["--cleanup"]):
        print("\nError: Could not create task lock\n")
        return
    try:
        print("\nPreparing to clean up server files...")
        cleanup_patterns = [
            BASE_DIR / "logs" / "*",
            BASE_DIR / "worlds" / "usercache.json",
            BASE_DIR / "worlds" / "*" / "level.dat_old",
            BASE_DIR / "worlds" / "*" / "session.lock"
        ]
        files_to_clean = []
        for pattern in cleanup_patterns:
            if "*" in str(pattern):
                files_to_clean.extend(glob.glob(str(pattern)))
            else:
                if pattern.exists():
                    files_to_clean.append(str(pattern))
        if not files_to_clean:
            print("No files to clean up found.")
            print("")
            return
        print("\nThe following files will be deleted:")
        print("=" * 50)
        for file_path in files_to_clean:
            file_size = os.path.getsize(file_path) if os.path.exists(file_path) else 0
            print(f"{file_path} ({file_size} bytes)")
        print("=" * 50)
        total_size = sum(os.path.getsize(f) for f in files_to_clean if os.path.exists(f))
        print(f"Total space to free: {total_size} bytes (~{total_size // (1024*1024)} MB)\n")
        confirm = input("Are you sure you want to delete these files? (Y/N): ")
        if confirm != "Y":
            print("Cleanup canceled.\n")
            return
        print("")
        deleted_count = 0
        freed_space = 0
        for file_path in files_to_clean:
            try:
                if os.path.exists(file_path):
                    file_size = os.path.getsize(file_path)
                    if os.path.isdir(file_path):
                        shutil.rmtree(file_path)
                    else:
                        os.remove(file_path)
                    deleted_count += 1
                    freed_space += file_size
                    print(f"Deleted: {file_path}")
            except Exception as e:
                print(f"Error deleting {file_path}: {e}\n")
        print(f"\nCleanup completed. Deleted {deleted_count} files, freed {freed_space} bytes (~{freed_space // (1024*1024)} MB).\n")
    finally:
        remove_lock()

def dump_logs():
    command = ["--dump"] + sys.argv[2:]
    logger.info(f"Starting dump_logs function with command: {' '.join(command)}")
    if not create_lock(command):
        logger.error("Failed to create lock for dump_logs operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logs_dir = BASE_DIR / "logs"
        logger.info(f"Checking logs directory: {logs_dir}")
        if not logs_dir.exists() or not any(logs_dir.iterdir()):
            logger.warning("No log files found to dump")
            print("")
            print("No log files found to dump.")
            print("")
            return
        search_terms = sys.argv[2:] if len(sys.argv) > 2 else []
        logger.info(f"Search terms: {search_terms}")
        if search_terms:
            logger.info(f"Starting log search with terms: {search_terms}")
            print("\n" + "=" * 45)
            print("          Log Search Utility")
            print("=" * 45)
            print(f"Searching for: {', '.join(search_terms)} (case-insensitive)")
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = BASE_DIR / f"logs_search_{timestamp}.zip"
            logger.info(f"Output file: {output_file}")
            temp_dir = BASE_DIR / f"temp_search_{timestamp}"
            logger.info(f"Temporary directory: {temp_dir}")
            temp_dir.mkdir(parents=True, exist_ok=True)
            try:
                files_scanned = 0
                files_matched = 0
                total_matched_lines = 0
                logger.info("Starting log file scanning...")
                for log_file in logs_dir.rglob("*"):
                    if not log_file.is_file():
                        continue
                    files_scanned += 1
                    file_matched_lines = 0
                    file_content = []
                    logger.info(f"Scanning file: {log_file}")
                    try:
                        if log_file.suffix == '.gz':
                            logger.info(f"Processing gzipped log file: {log_file}")
                            with gzip.open(log_file, 'rt', encoding='utf-8', errors='ignore') as f:
                                for line_num, line in enumerate(f, 1):
                                    line_lower = line.lower()
                                    if any(term.lower() in line_lower for term in search_terms):
                                        file_matched_lines += 1
                                        file_content.append(f"Line {line_num}: {line.rstrip()}")
                        else:
                            logger.info(f"Processing plain text log file: {log_file}")
                            with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
                                for line_num, line in enumerate(f, 1):
                                    line_lower = line.lower()
                                    if any(term.lower() in line_lower for term in search_terms):
                                        file_matched_lines += 1
                                        file_content.append(f"Line {line_num}: {line.rstrip()}")
                        if file_content:
                            files_matched += 1
                            total_matched_lines += file_matched_lines
                            rel_path = log_file.relative_to(logs_dir)
                            output_filename = temp_dir / f"{rel_path}.matched.txt"
                            output_filename.parent.mkdir(parents=True, exist_ok=True)
                            with open(output_filename, 'w', encoding='utf-8') as f:
                                f.write("=" * 20 + "\n")
                                f.write(f"{rel_path}\n")
                                f.write("=" * 20 + "\n\n")
                                f.write("\n".join(file_content))
                                f.write("\n")
                            logger.info(f"Found {file_matched_lines} matches in: {rel_path}")
                            print(f"Found {file_matched_lines} matches in: {rel_path}")
                    except Exception as e:
                        logger.error(f"Error processing {log_file}: {e}")
                        print(f"Error processing {log_file}: {e}")
                        continue
                logger.info(f"File scanning completed: scanned={files_scanned}, matched={files_matched}, total_lines={total_matched_lines}")
                report_content = f"""===============================
        Log Dump Report
===============================

 - Date: {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
 - Searched keyword: "{'", "'.join(search_terms)}"
 - Files scanned: {files_scanned}
 - Files matched: {files_matched}
 - Total lines matched: {total_matched_lines}
 - Archive file: {output_file.name}"""
                report_file = temp_dir / "report.txt"
                with open(report_file, 'w', encoding='utf-8') as f:
                    f.write(report_content)
                logger.info(f"Report file created: {report_file}")
                if files_matched > 0:
                    logger.info(f"Creating ZIP archive with {files_matched} matched files")
                    with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
                        for file_path in temp_dir.rglob("*"):
                            if file_path.is_file():
                                arcname = file_path.relative_to(temp_dir)
                                zipf.write(file_path, arcname)
                    file_size = os.path.getsize(output_file)
                    logger.info(f"ZIP archive created: {output_file}, size: {format_file_size(file_size)}")
                    print("\n" + "=" * 45)
                    print(f"Dumped {files_matched} log files.")
                    print(f"Found {total_matched_lines} matching lines in {files_matched} files.")
                    print(f"\nResult saved to: {output_file.name}")
                    print(f"File size: {file_size} bytes (~{file_size // (1024*1024)} MB)")
                    print("=" * 45)
                    confirm = input("\nDo you want to delete the original log files? (Y/N): ").strip().upper()
                    logger.info(f"User confirmation for log deletion: {confirm}")
                    if confirm == "Y":
                        logger.info("Starting deletion of original log files")
                        deleted_count = 0
                        freed_space = 0
                        for log_file in logs_dir.rglob("*"):
                            if log_file.is_file():
                                try:
                                    file_size = log_file.stat().st_size
                                    log_file.unlink()
                                    deleted_count += 1
                                    freed_space += file_size
                                    logger.info(f"Deleted log file: {log_file}")
                                except Exception as e:
                                    logger.error(f"Error deleting {log_file}: {e}")
                                    print(f"Error deleting {log_file}: {e}")
                        logger.info(f"Log deletion completed: {deleted_count} files deleted, {format_file_size(freed_space)} freed")
                        print(f"Deleted {deleted_count} log files, freed {freed_space} bytes.")
                    else:
                        logger.info("User chose not to delete original log files")
                else:
                    logger.info("No matching content found in any log files")
                    print("\nNo matching content found in any log files.")
                print("")
            except Exception as e:
                logger.error(f"Error creating log search: {e}", exc_info=True)
                print(f"Error creating log search: {e}")
                import traceback
                traceback.print_exc()
            finally:
                if temp_dir.exists():
                    logger.info(f"Cleaning up temporary directory: {temp_dir}")
                    try:
                        shutil.rmtree(temp_dir, ignore_errors=True)
                        logger.info(f"Temporary directory removed: {temp_dir}")
                    except Exception as cleanup_error:
                        logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        else:
            logger.info("Starting full log dump (no search terms)")
            print("\n" + "=" * 45)
            print("          Log Dump Utility")
            print("=" * 45)
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = BASE_DIR / f"logs_dump_{timestamp}.zip"
            logger.info(f"Full log dump output file: {output_file}")
            print(f"\nCreating complete log dump...")
            try:
                temp_dir = BASE_DIR / f"temp_logs_{timestamp}"
                logger.info(f"Temporary directory for full dump: {temp_dir}")
                temp_dir.mkdir(parents=True, exist_ok=True)
                file_count = 0
                logger.info("Starting full log file collection")
                for root, _, files in os.walk(logs_dir):
                    for file in files:
                        src_path = os.path.join(root, file)
                        rel_path = os.path.relpath(src_path, BASE_DIR)
                        dest_path = temp_dir / rel_path
                        dest_path.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src_path, dest_path)
                        file_count += 1
                        if file_count % 50 == 0:
                            logger.info(f"Collected {file_count} files...")
                logger.info(f"Collected {file_count} log files for full dump")
                report_content = f"""===============================
        Log Dump Report
===============================

 - Date: {datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
 - Searched keyword: "Full dump (no keyword search)"
 - Files scanned: {file_count}
 - Files matched: {file_count}
 - Total lines matched: N/A (full dump)
 - Archive file: {output_file.name}"""
                report_file = temp_dir / "report.txt"
                with open(report_file, 'w', encoding='utf-8') as f:
                    f.write(report_content)
                logger.info(f"Creating ZIP archive with {file_count} files")
                with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
                    for root, _, files in os.walk(temp_dir):
                        for file in files:
                            file_path = os.path.join(root, file)
                            arcname = os.path.relpath(file_path, temp_dir)
                            zipf.write(file_path, arcname)
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info(f"Temporary directory cleaned up: {temp_dir}")
                file_size = os.path.getsize(output_file)
                logger.info(f"Full log dump completed: {output_file}, size: {format_file_size(file_size)}")
                print("\n" + "=" * 45)
                print(f"Dumped {file_count} log files.")
                print(f"Result saved to: {output_file.name}")
                print(f"File size: {file_size} bytes (~{file_size // (1024*1024)} MB)")
                print("=" * 45)
                confirm = input("\nDo you want to delete the original log files? (Y/N): ").strip().upper()
                logger.info(f"User confirmation for full log deletion: {confirm}")
                if confirm == "Y":
                    logger.info("Starting deletion of all original log files")
                    deleted_count = 0
                    freed_space = 0
                    for root, _, files in os.walk(logs_dir):
                        for file in files:
                            file_path = os.path.join(root, file)
                            try:
                                file_size = os.path.getsize(file_path)
                                os.remove(file_path)
                                deleted_count += 1
                                freed_space += file_size
                                logger.info(f"Deleted log file: {file_path}")
                            except Exception as e:
                                logger.error(f"Error deleting {file_path}: {e}")
                                print(f"Error deleting {file_path}: {e}")
                    logger.info(f"Full log deletion completed: {deleted_count} files deleted, {format_file_size(freed_space)} freed")
                    print(f"Deleted {deleted_count} log files, freed {freed_space} bytes.")
                else:
                    logger.info("User chose not to delete original log files")
                print("")
            except Exception as e:
                logger.error(f"Error creating log dump: {e}", exc_info=True)
                print(f"Error creating log dump: {e}\n")
                import traceback
                traceback.print_exc()
                if temp_dir.exists():
                    logger.info(f"Cleaning up temporary directory after error: {temp_dir}")
                    shutil.rmtree(temp_dir, ignore_errors=True)
    finally:
        logger.info("Removing task lock for dump_logs operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock for dump_logs operation")

def check_config_file():
    if not CONFIG_FILE.exists():
        return "missing_or_corrupted"
    config = configparser.ConfigParser()
    try:
        config.read(CONFIG_FILE)
        if "SERVER" not in config:
            return "missing_or_corrupted"
        server_config = config["SERVER"]
        critical_params = ["version", "max_ram", "java_path"]
        missing_critical = [param for param in critical_params if param not in server_config or not server_config[param].strip()]
        if missing_critical:
            return "critical_missing"
        optional_params = ["additional_list", "additional_parameters"]
        missing_optional = [param for param in optional_params if param not in server_config]
        if missing_optional:
            return "optional_missing"
        try:
            max_ram = int(server_config["max_ram"])
            if max_ram <= 0:
                return "critical_missing"
        except (ValueError, TypeError):
            return "critical_missing"
        java_path = Path(server_config["java_path"])
        if not java_path.exists():
            return "critical_missing"
        return "ok"
    except (configparser.Error, KeyError, ValueError, TypeError) as e:
        print(f"Debug: Config parsing error: {e}")
        return "missing_or_corrupted"

def analyze_server_crash(exit_code, uptime_str=None):
    start_time = time.time()
    print("\n" + "=" * 50)
    uptime_display, crash_time = get_uptime()
    if uptime_str:
        uptime_display = uptime_str
    if exit_code == 0:
        print("        POTENTIAL CRASH DETECTED FROM LOGS")
    else:
        print("                  CRASH DETECTED")
    print("=" * 50)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    if exit_code == 0:
        report_file = BASE_DIR / f"potential_crash_{timestamp}.txt"
    else:
        report_file = BASE_DIR / f"crash_{timestamp}.txt"
    log_file = BASE_DIR / "logs" / "latest.log"
    print(f"\nExit Code: {exit_code}")
    print(f"Server Uptime: {uptime_display}")
    print(f"Crash Time: {crash_time}")
    print(f"Log File: {log_file}")
    print(f"Report File: {report_file}")
    analysis_data = collect_crash_data(log_file, exit_code, uptime_display, crash_time)
    generate_crash_report(report_file, analysis_data, log_file, exit_code, uptime_display, crash_time)
    if exit_code == 0:
        print("\nNote: This is a potential crash detected from log analysis.")
        print("The server exited with code 0 but showed error indicators.\n")
    else:
        print("\nPlease check the crash report for details about the server crash.\n")
    elapsed_time = time.time() - start_time
    print(f"Crash analysis completed in {elapsed_time:.2f}s!\n")

def collect_crash_data(log_file, exit_code, uptime_str=None, crash_time_str=None):
    data = {
        'exit_code': exit_code,
        'uptime': uptime_str or "Unknown",
        'crash_time': crash_time_str or "Unknown",
        'warn_errors': [],
        'keywords_found': {},
        'plugin_dependencies': {},
        'log_lines': []
    }
    if log_file.exists():
        try:
            with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
                data['log_lines'] = f.readlines()
        except Exception as e:
            print(f"Warning: Could not read log file: {e}")
            data['log_lines'] = []
    analyze_log_content(data)
    analyze_plugin_dependencies(data)
    return data

def analyze_log_content(data):
    log_lines = data['log_lines']
    warn_errors = []
    keywords = {
        'Out of memory': [],
        'OutOfMemory': [],
        "Can't keep up": [],
        'Exception': [],
        'Error': [],
        'Crash': [],
        'Failed': [],
        'Timeout': [],
        'Deadlock': [],
        'StackOverflowError': [],
        'java.lang': []
    }
    error_indices = []
    for i, line in enumerate(log_lines):
        line = line.strip()
        if not line:
            continue    
        is_error_line = False
        if 'WARN]' in line or 'ERROR]' in line:
            is_error_line = True
        elif ('Exception:' in line or 'java.lang' in line) and not line.startswith('['):
            is_error_line = True
        elif line.startswith('Exception:'):
            is_error_line = True
        if is_error_line:
            error_indices.append(i)
        for keyword in keywords.keys():
            if keyword.lower() in line.lower():
                keywords[keyword].append(i + 1)
    merged_error_groups = []
    if error_indices:
        current_group = [error_indices[0]]
        for i in range(1, len(error_indices)):
            if error_indices[i] - error_indices[i-1] <= 2:
                current_group.append(error_indices[i])
            else:
                merged_error_groups.append(current_group)
                current_group = [error_indices[i]]
        merged_error_groups.append(current_group)
    for error_group in merged_error_groups:
        if not error_group:
            continue
        start_idx = max(0, error_group[0] - 2)
        end_idx = min(len(log_lines), error_group[-1] + 3)
        context_lines = []
        for ctx_i in range(start_idx, end_idx):
            if ctx_i < len(log_lines):
                is_target = ctx_i in error_group
                context_lines.append({
                    'line_number': ctx_i + 1,
                    'content': log_lines[ctx_i].rstrip(),
                    'is_target': is_target
                })
        warn_errors.append(context_lines)
    data['warn_errors'] = warn_errors
    data['keywords_found'] = {k: v for k, v in keywords.items() if v}

def analyze_plugin_dependencies(data):
    try:
        if not PLUGINS_DIR.exists():
            return
        plugin_files = list(PLUGINS_DIR.glob("*.jar"))
        if not plugin_files:
            return
        enabled_plugins = []
        for plugin_path in plugin_files:
            if not plugin_path.name.endswith('.disabled'):
                name, version, main_class = get_plugin_info(plugin_path)
                enabled_plugins.append({
                    'path': plugin_path,
                    'name': name,
                    'version': version,
                    'main_class': main_class
                })
        missing_hard_deps = {}
        missing_soft_deps = {}
        for plugin in enabled_plugins:
            try:
                dependencies = get_plugin_dependencies(plugin['path'])
                hard_deps_missing = []
                for dep in dependencies.get('depend', []):
                    if not is_plugin_enabled(dep, enabled_plugins):
                        hard_deps_missing.append(dep)
                soft_deps_missing = []
                for dep in dependencies.get('softdepend', []):
                    if not is_plugin_enabled(dep, enabled_plugins):
                        soft_deps_missing.append(dep)
                if hard_deps_missing:
                    missing_hard_deps[plugin['name']] = hard_deps_missing
                if soft_deps_missing:
                    missing_soft_deps[plugin['name']] = soft_deps_missing
            except Exception as e:
                print(f"Error analyzing dependencies for {plugin['name']}: {e}")
                continue
        data['plugin_dependencies'] = {
            'missing_hard': missing_hard_deps,
            'missing_soft': missing_soft_deps
        }
    except Exception as e:
        print(f"Error in plugin dependency analysis: {e}")
        data['plugin_dependencies'] = {
            'missing_hard': {},
            'missing_soft': {}
        }

def analyze_plugin_dependencies_cli():
    logger.info("Starting analyze_plugin_dependencies_cli function")
    print("\n" + "=" * 52)
    print("             Plugin Dependency Analysis")
    print("=" * 52)
    if not PLUGINS_DIR.exists():
        logger.error("Plugins directory not found: %s", PLUGINS_DIR)
        print("\nPlugins directory not found!")
        print("")
        return
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    logger.info("Found %d plugin files (including disabled)", len(plugin_files))
    if not plugin_files:
        logger.info("No plugins found in directory")
        print("\nNo plugins found!")
        print("")
        return
    all_plugins = []
    logger.info("Processing plugin files...")
    for plugin_path in plugin_files:
        name, version, main_class = get_plugin_info(plugin_path)
        enabled = not plugin_path.name.endswith('.disabled')
        dependencies = get_plugin_dependencies(plugin_path)
        all_plugins.append({
            'path': plugin_path,
            'name': name,
            'version': version,
            'enabled': enabled,
            'dependencies': dependencies
        })
        logger.info("Plugin loaded: %s (version: %s, enabled: %s, dependencies: %s)", 
                    name, version, enabled, dependencies)
    logger.info("Total plugins processed: %d", len(all_plugins))
    installed_plugin_names = {plugin['name'].lower() for plugin in all_plugins}
    enabled_plugin_names = {plugin['name'].lower() for plugin in all_plugins if plugin['enabled']}
    logger.info("Installed plugin names (lowercase): %s", installed_plugin_names)
    logger.info("Enabled plugin names (lowercase): %s", enabled_plugin_names)
    found_issues = False
    logger.info("Starting dependency analysis...")
    for plugin in all_plugins:
        if not plugin['enabled']:
            continue
        plugin_name = plugin['name']
        logger.info("Analyzing dependencies for plugin: %s", plugin_name)
        dependencies = plugin['dependencies']
        hard_deps = dependencies.get('depend', [])
        soft_deps = dependencies.get('softdepend', [])
        logger.info("Plugin %s hard dependencies: %s", plugin_name, hard_deps)
        logger.info("Plugin %s soft dependencies: %s", plugin_name, soft_deps)
        hard_dep_not_installed = []
        hard_dep_not_enabled = []
        for dep in hard_deps:
            dep_lower = dep.lower()
            if dep_lower not in installed_plugin_names:
                hard_dep_not_installed.append(dep)
                logger.warning("Hard dependency not installed: %s (required by: %s)", dep, plugin_name)
            elif dep_lower not in enabled_plugin_names:
                disabled_dep = next((p for p in all_plugins if p['name'].lower() == dep_lower and not p['enabled']), None)
                if disabled_dep:
                    hard_dep_not_enabled.append(dep)
                    logger.warning("Hard dependency not enabled: %s (required by: %s)", dep, plugin_name)
        soft_dep_not_installed = []
        soft_dep_not_enabled = []
        for dep in soft_deps:
            dep_lower = dep.lower()
            if dep_lower not in installed_plugin_names:
                soft_dep_not_installed.append(dep)
                logger.info("Soft dependency not installed: %s (used by: %s)", dep, plugin_name)
            elif dep_lower not in enabled_plugin_names:
                disabled_dep = next((p for p in all_plugins if p['name'].lower() == dep_lower and not p['enabled']), None)
                if disabled_dep:
                    soft_dep_not_enabled.append(dep)
                    logger.info("Soft dependency not enabled: %s (used by: %s)", dep, plugin_name)
        if soft_dep_not_installed:
            found_issues = True
            logger.info("Plugin %s has missing soft dependencies: %s", plugin_name, soft_dep_not_installed)
            print(f"\nPlugin '{plugin_name}' requires following soft dependencies but not installed:")
            for dep in soft_dep_not_installed:
                print(f" - {dep}")
        if soft_dep_not_enabled:
            found_issues = True
            logger.info("Plugin %s has disabled soft dependencies: %s", plugin_name, soft_dep_not_enabled)
            print(f"\nPlugin '{plugin_name}' requires following soft dependencies but not enabled:")
            for dep in soft_dep_not_enabled:
                print(f" - {dep}")
        if hard_dep_not_installed:
            found_issues = True
            logger.warning("Plugin %s has missing hard dependencies: %s", plugin_name, hard_dep_not_installed)
            print(f"\nPlugin '{plugin_name}' requires following hard dependencies but not installed:")
            for dep in hard_dep_not_installed:
                print(f" - {dep}")
        if hard_dep_not_enabled:
            found_issues = True
            logger.warning("Plugin %s has disabled hard dependencies: %s", plugin_name, hard_dep_not_enabled)
            print(f"\nPlugin '{plugin_name}' requires following hard dependencies but not enabled:")
            for dep in hard_dep_not_enabled:
                print(f" - {dep}")
    if not found_issues:
        logger.info("All plugin dependencies are satisfied")
        print("\nAll plugin dependencies are satisfied!")
        print("No missing or disabled dependencies found.")
    disabled_plugins = [p for p in all_plugins if not p['enabled']]
    logger.info("Found %d disabled plugins", len(disabled_plugins))
    if disabled_plugins:
        print("\n" + "=" * 50)
        print("Currently Disabled Plugins:")
        print("=" * 50)
        for plugin in disabled_plugins:
            print(f" - {plugin['name']} (version: {plugin['version']})")
            logger.info("Disabled plugin: %s (version: %s)", plugin['name'], plugin['version'])
    enabled_count = len([p for p in all_plugins if p['enabled']])
    disabled_count = len([p for p in all_plugins if not p['enabled']])
    total_hard_deps = sum(len(p['dependencies'].get('depend', [])) for p in all_plugins if p['enabled'])
    total_soft_deps = sum(len(p['dependencies'].get('softdepend', [])) for p in all_plugins if p['enabled'])
    logger.info("Plugin statistics - Total: %d, Enabled: %d, Disabled: %d, Hard dependencies: %d, Soft dependencies: %d",
                len(all_plugins), enabled_count, disabled_count, total_hard_deps, total_soft_deps)
    print("\nYou can ignore soft dependencies if not critical.")
    print("You should never ignore missing hard dependencies!")
    print(f"\n" + "=" * 52)
    print("Statistics:")
    print(f" - Total plugins: {len(all_plugins)}")
    print(f" - Enabled plugins: {enabled_count}")
    print(f" - Disabled plugins: {disabled_count}")
    print(f" - Total hard dependencies: {total_hard_deps}")
    print(f" - Total soft dependencies: {total_soft_deps}")
    print("=" * 52)
    print("")
    logger.info("Plugin dependency analysis completed")

def is_plugin_enabled(plugin_name, enabled_plugins):
    return any(plugin['name'].lower() == plugin_name.lower() for plugin in enabled_plugins)

def get_environment_info():
    info = {}
    info['os_name'] = platform.system()
    info['os_version'] = platform.release()
    try:
        if platform.system() == "Windows":
            info['cpu_info'] = platform.processor()
        elif platform.system() == "Darwin":
            info['cpu_info'] = platform.processor()
        elif platform.system() == "Linux":
            try:
                with open('/proc/cpuinfo', 'r') as f:
                    for line in f:
                        if line.strip().startswith('model name'):
                            info['cpu_info'] = line.split(':')[1].strip()
                            break
                    else:
                        info['cpu_info'] = platform.processor()
            except:
                info['cpu_info'] = platform.processor()
        else:
            info['cpu_info'] = platform.processor()
    except:
        info['cpu_info'] = "Unknown"
    try:
        config = load_config()
        java_path = config.get("java_path", "Not set")
        info['java_path'] = java_path
        try:
            result = subprocess.run(
                [java_path, "-version"],
                stderr=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                timeout=5
            )
            output = result.stderr or result.stdout
            version, vendor = parse_java_version(output)
            info['java_version'] = version
            info['java_vendor'] = vendor
        except:
            info['java_version'] = "Unknown"
            info['java_vendor'] = "Unknown"
    except:
        info['java_path'] = "Not configured"
        info['java_version'] = "Unknown"
        info['java_vendor'] = "Unknown"
    try:
        config = load_config()
        max_ram_mb = config.get("max_ram", "Unknown")
        if max_ram_mb != "Unknown":
            max_ram_gb = int(max_ram_mb) / 1024
            total_mem_bytes = get_total_memory()
            total_mem_gb = total_mem_bytes / (1024 ** 3)
            if total_mem_gb > 0:
                allocation_percent = (max_ram_gb / total_mem_gb) * 100
                info['allocated_ram'] = f"{max_ram_gb:.1f}GB ({allocation_percent:.0f}%)"
            else:
                info['allocated_ram'] = f"{max_ram_gb:.1f}GB"
        else:
            info['allocated_ram'] = "Unknown"
    except:
        info['allocated_ram'] = "Unknown"
    try:
        config = load_config()
        info['game_version'] = config.get("version", "Unknown")
    except:
        info['game_version'] = "Unknown"
    try:
        if SERVER_PROPERTIES.exists():
            with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
                for line in f:
                    if line.strip().startswith('server-port='):
                        info['server_port'] = line.split('=')[1].strip()
                        break
                else:
                    info['server_port'] = "25565 (default)"
        else:
            info['server_port'] = "25565 (default)"
    except:
        info['server_port'] = "Unknown"
    if is_running_in_container():
        container_mem = get_container_memory_limit()
        if container_mem:
            container_mem_gb = container_mem / (1024 ** 3)
            info['container_info'] = f"Yes ({container_mem_gb:.1f}GB limit)"
        else:
            info['container_info'] = "Yes"
    else:
        info['container_info'] = "No"
    try:
        config = load_config()
        info['device_id'] = config.get("device", get_device_id())[:12] + "..."
    except:
        info['device_id'] = get_device_id()[:12] + "..."
    try:
        config = load_config()
        additional_params = config.get("additional_parameters", "").strip()
        info['additional_params'] = additional_params if additional_params else "None"
    except:
        info['additional_params'] = "None"
    return info

def generate_crash_report(report_file, data, log_file, exit_code):
    logger.info(f"Starting crash report generation for exit code: {exit_code}")
    logger.info(f"Report file: {report_file}, Log file: {log_file}")
    try:
        with open(report_file, 'w', encoding='utf-8') as f:
            logger.info(f"Opened report file for writing: {report_file}")
            f.write("=" * 47 + "\n")
            if exit_code == -1:
                f.write("      Server Interrupted - Crash Analysis\n")
                logger.info("Crash type: Server Interrupted (exit code -1)")
            elif exit_code == 0:
                f.write("       Potential Crash Detected From Logs\n")
                logger.info("Crash type: Potential Crash (exit code 0)")
            else:
                f.write("        Minecraft Server Crash Analysis\n")
                logger.info(f"Crash type: Actual Crash (exit code {exit_code})")
            f.write("=" * 47 + "\n\n")
            if exit_code == -1:
                f.write("The server was interrupted by user (CTRL+C) but showed signs of issues.\n")
                f.write("This may indicate the server was unresponsive and required force quit.\n\n")
                logger.info("Adding interrupt analysis description")
            elif exit_code == 0:
                f.write("The server exited normally but error indicators were found in logs.\n\n")
                logger.info("Adding normal exit with errors description")
            else:
                f.write("The server exited with unexpected return value\n\n")
                logger.info("Adding crash exit description")
            f.write(f"Report Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"Returned Exit Code: {exit_code}\n")
            f.write(f"Server Uptime: {data.get('uptime', 'Unknown')}\n")
            f.write(f"Crash Time: {data.get('crash_time', 'Unknown')}\n")
            f.write(f"Log Path: {log_file}\n")
            f.write(f"Report Path: {report_file}\n\n")
            logger.info(f"Added report metadata - Generated: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}, "
                       f"Exit Code: {exit_code}, Uptime: {data.get('uptime', 'Unknown')}")
            f.write("=" * 47 + "\n")
            f.write("            Environment Information\n")
            f.write("=" * 47 + "\n\n")
            logger.info("Adding environment information section")
            system_info = get_environment_info()
            logger.info("Retrieved environment information")
            env_items = [
                ("System", f"{system_info['os_name']} {system_info['os_version']}"),
                ("CPU", system_info['cpu_info']),
                ("Architecture", platform.machine()),
                ("Allocated RAM", system_info['allocated_ram']),
                ("Java", f"{system_info['java_version']} ({system_info['java_vendor']})"),
                ("Java Path", system_info['java_path']),
                ("Game Version", system_info['game_version']),
                ("Server Port", system_info['server_port']),
                ("Container", system_info['container_info']),
                ("Python Version", platform.python_version()),
                ("Script Version", SCRIPT_VERSION),
                ("Device ID", system_info['device_id']),
                ("Additional Parameters", system_info['additional_params'])
            ]
            for key, value in env_items:
                if value:
                    f.write(f"{key}: {value}\n")
                    logger.debug(f"Environment item: {key}: {value}")
            f.write("\n")
            logger.info("Environment information written to report")
            f.write("=" * 47 + "\n")
            f.write("                    Summary\n")
            f.write("=" * 47 + "\n\n")
            error_context_count = len(data['warn_errors'])
            f.write(f"Found {error_context_count} error contexts in the log.\n")
            f.write("Error contexts are listed below:\n\n")
            logger.info(f"Found {error_context_count} error contexts in crash data")
            f.write("=" * 47 + "\n\n")
            for i, context_block in enumerate(data['warn_errors'], 1):
                f.write(f"Error Context #{i}:\n")
                logger.debug(f"Writing error context #{i} with {len(context_block)} lines")
                for ctx_line in context_block:
                    marker = " >>" if ctx_line['is_target'] else "   "
                    f.write(f"{marker} Line{ctx_line['line_number']:4d}: {ctx_line['content']}\n")
                f.write("\n")
            logger.info(f"Written {error_context_count} error contexts to report")
            f.write("=" * 47 + "\n\n")
            f.write("Found keywords in log:\n")
            logger.info("Adding keywords section")
            for keyword, lines in data['keywords_found'].items():
                line_count = len(lines)
                f.write(f"\n{keyword} at lines:\n")
                logger.debug(f"Keyword '{keyword}' found {line_count} times")
                for line_num in lines[:10]:
                    f.write(f" - Line {line_num}\n")
                if len(lines) > 10:
                    additional_count = len(lines) - 10
                    f.write(f" - ... and {additional_count} more\n")
                    logger.debug(f"Keyword '{keyword}' has {additional_count} additional occurrences not shown")
            plugin_deps = data.get('plugin_dependencies', {})
            logger.info(f"Plugin dependencies data available: {bool(plugin_deps)}")
            if plugin_deps and isinstance(plugin_deps, dict):
                missing_hard = plugin_deps.get('missing_hard', {})
                missing_soft = plugin_deps.get('missing_soft', {})
                logger.info(f"Missing hard dependencies: {len(missing_hard)}, Missing soft dependencies: {len(missing_soft)}")
                if missing_hard or missing_soft:
                    f.write("\n" + "=" * 47 + "\n")
                    f.write("            Plugin Dependency Issues\n")
                    f.write("=" * 47 + "\n")
                    logger.info("Adding plugin dependency issues section")
                    if missing_hard and isinstance(missing_hard, dict):
                        f.write("\nMissing Hard Dependencies:\n")
                        logger.info(f"Writing {len(missing_hard)} hard dependency issues")
                        for plugin_name, deps in missing_hard.items():
                            if isinstance(deps, list):
                                f.write(f"\nPlugin '{plugin_name}' requires:\n")
                                for dep in deps:
                                    f.write(f" - {dep}\n")
                                logger.debug(f"Plugin '{plugin_name}' missing hard dependencies: {deps}")
                    if missing_soft and isinstance(missing_soft, dict):
                        f.write("\nMissing Soft Dependencies:\n")
                        logger.info(f"Writing {len(missing_soft)} soft dependency issues")
                        for plugin_name, deps in missing_soft.items():
                            if isinstance(deps, list):
                                f.write(f"\nPlugin '{plugin_name}' suggests:\n")
                                for dep in deps:
                                    f.write(f" - {dep}\n")
                                logger.debug(f"Plugin '{plugin_name}' missing soft dependencies: {deps}")
            f.write("\n" + "=" * 47 + "\n")
            f.write("                Recommendations\n")
            f.write("=" * 47 + "\n\n")
            logger.info("Adding recommendations section")
            has_specific_issues = False
            if data['keywords_found'].get('Out of memory') or data['keywords_found'].get('OutOfMemory'):
                f.write("OUT OF MEMORY DETECTED:\n")
                f.write(" - Increase server RAM allocation\n")
                f.write(" - Reduce view-distance in server.properties\n")
                f.write(" - Install optimization plugins\n\n")
                logger.warning("Out of memory issues detected in crash report")
                has_specific_issues = True
            if data['keywords_found'].get("Can't keep up"):
                f.write("SERVER LAG DETECTED:\n")
                f.write(" - Check CPU usage on your machine\n")
                f.write(" - Reduce entity count in worlds\n")
                f.write(" - Optimize redstone contraptions\n")
                f.write(" - Install performance monitoring plugins\n\n")
                logger.warning("Server lag issues detected in crash report")
                has_specific_issues = True
            plugin_deps = data.get('plugin_dependencies', {})
            if plugin_deps and isinstance(plugin_deps, dict):
                missing_hard = plugin_deps.get('missing_hard', {})
                if missing_hard and isinstance(missing_hard, dict) and missing_hard:
                    f.write("MISSING PLUGIN DEPENDENCIES:\n")
                    f.write(" - Install the required dependencies\n")
                    f.write(" - Or disable the plugins that require them\n\n")
                    logger.warning("Missing plugin dependencies detected in crash report")
                    has_specific_issues = True
            if not has_specific_issues:
                f.write("No specific issues detected in logs.\n")
                f.write("Consider checking:\n")
                f.write(" - Server hardware resources\n")
                f.write(" - Operating system logs\n")
                f.write(" - Java version compatibility\n")
                f.write(" - Environment compatibility\n")
                f.write(" - World file corruption\n\n")
                logger.info("No specific issues detected in crash report, adding general recommendations")
            f.write("=" * 47)
            logger.info("Crash report generation completed successfully")
    except IOError as e:
        logger.error(f"IOError writing crash report to {report_file}: {e}")
        print(f"Error writing crash report: {e}\n")
        import traceback
        traceback.print_exc()
    except Exception as e:
        logger.error(f"Unexpected error generating crash report: {e}", exc_info=True)
        print(f"Error generating crash report: {e}\n")
        import traceback
        traceback.print_exc()

def check_logs_for_errors():
    log_file = BASE_DIR / "logs" / "latest.log"
    if not log_file.exists():
        return False
    error_keywords = [
        'ERROR',
        'Out of memory',
        'OutOfMemory',
        "Can't keep up",
        'Exception',
        'Error',
        'Crash',
        'Failed',
        'Timeout',
        'Deadlock',
        'StackOverflowError',
        'java.lang'
    ]
    try:
        with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        last_lines = lines[-200:] if len(lines) > 200 else lines
        for line in last_lines:
            line_lower = line.lower()
            for keyword in error_keywords:
                if keyword.lower() in line_lower:
                    return True
        return False
    except Exception as e:
        print(f"Error reading log file: {e}\n")
        return False

def ask_user_for_crash_analysis():
    print("\n" + "=" * 61)
    print("               POSSIBLE CRASH DETECTED IN LOGS")
    print("=" * 61)
    uptime_seconds, uptime_str, crash_time = get_uptime()
    if uptime_seconds >= 60:
        print(f"\nServer Uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
    else:
        print(f"\nServer Uptime: {uptime_str}")
    print(f"Crash Time: {crash_time}")
    print("\nWarning: The server exited normally (return code 0),")
    print("but potential crash/error indicators were found in the logs.")
    print("\nThis could indicate:")
    print(" - Out of memory issues")
    print(" - Plugin conflicts or errors")
    print(" - World corruption")
    print(" - Other runtime problems")
    while True:
        print("\nDo you want to analyze the logs for potential issues?")
        print(" Y - Yes, analyze the logs and generate a crash report")
        print(" N - No, ignore the warnings and exit normally")
        choice = input("\nEnter your choice (Y/N): ").strip().upper()
        if choice == 'Y':
            return True
        elif choice == 'N':
            print("\nContinuing without analysis...")
            return False
        else:
            print("Please enter Y or N.")

def handle_server_crash(process, uptime_str=None):
    if process.returncode == 0:
        if not check_logs_for_errors():
            return
        if not ask_user_for_crash_analysis():
            return
    if not uptime_str:
        uptime_str = get_uptime()
    else:
        uptime_str = get_uptime()
    analyze_server_crash(process.returncode, uptime_str)

def ask_user_for_interrupt_analysis():
    print("\n" + "=" * 60)
    print("       SERVER INTERRUPTED - POTENTIAL ISSUES DETECTED")
    print("=" * 60)
    uptime_seconds, uptime_str, crash_time = get_uptime()
    if uptime_seconds >= 60:
        print(f"\nServer Uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
    else:
        print(f"\nServer Uptime: {uptime_str}")
    print(f"Interrupt Time: {crash_time}")
    print("\nThe server was interrupted by user (CTRL+C),")
    print("but potential issues were detected in the logs.")
    print("\nThis could indicate:")
    print(" - Server was unresponsive and required force quit")
    print(" - Memory issues causing server to hang")
    print(" - Plugin conflicts preventing normal shutdown")
    print(" - World corruption or loading problems")
    while True:
        print("\nDo you want to analyze the logs for potential issues?")
        print(" Y - Yes, analyze the logs and generate a crash report")
        print(" N - No, this was an intentional interrupt")
        choice = input("\nEnter your choice (Y/N): ").strip().upper()
        if choice == 'Y':
            return True
        elif choice == 'N':
            print("\nContinuing without analysis...")
            return False
        else:
            print("Please enter Y or N.")

def start_server():
    global SERVER_START_TIME, SERVER_END_TIME
    logger.info("Starting server startup process")
    config_check_result = check_config_file()
    if config_check_result == "missing_or_corrupted":
        logger.error("Configuration file is missing or corrupted")
        print("\nError: Configuration file is missing or corrupted!")
        print("Please run with --init to create a new configuration first.\n")
        return
    elif config_check_result == "critical_missing":
        logger.error("Critical configuration parameters are missing")
        print("\nError: Critical configuration parameters are missing!")
        print("Required parameters: version, max_ram, java_path")
        print("Please run with --init to fix the configuration first.\n")
        return
    elif config_check_result == "optional_missing":
        logger.warning("Some optional configuration parameters are missing")
        print("\nWarning: Some optional configuration parameters are missing.")
        print("The server will start, but some features may not work properly.")
        print("Consider running --init to complete the configuration.\n")
    logger.info("Checking server requirements...")
    port_ok, java_ok, permissions_ok = check_server_requirements()
    if not all([port_ok, java_ok, permissions_ok]):
        logger.error(f"Server requirements check failed: port_ok={port_ok}, java_ok={java_ok}, permissions_ok={permissions_ok}")
        print("\nServer requirements check failed. Please fix the issues above.\n")
        return
    logger.info("All server requirements passed")
    show_info()
    if not check_and_accept_eula():
        logger.error("Failed to accept EULA")
        print("\nFailed to accept EULA. Server cannot start without accepting Mojang's EULA.")
        print("Please manually check and accept the EULA in eula.txt\n")
        return
    logger.info("EULA accepted successfully")
    config = load_config()
    logger.info("Creating necessary directories if they don't exist")
    (BASE_DIR / "logs").mkdir(exist_ok=True)
    (BASE_DIR / "worlds").mkdir(exist_ok=True)
    (BASE_DIR / "config").mkdir(exist_ok=True)
    java_path = config["java_path"]
    max_ram_mb = config["max_ram"]
    additional_params = config.get("additional_parameters", "")
    logger.info(f"Java path: {java_path}")
    logger.info(f"Max RAM: {max_ram_mb} MB")
    logger.info(f"Additional parameters: {additional_params}")
    if not Path(java_path).exists():
        logger.error(f"Java executable not found at: {java_path}")
        print(f"Error: Java executable not found at {java_path}\n")
        sys.exit(1)
    if not SERVER_JAR.exists():
        logger.error(f"Server JAR not found at: {SERVER_JAR}")
        print(f"Error: Server JAR not found at {SERVER_JAR}\n")
        sys.exit(1)
    command = [
        java_path,
        f"-Xmx{max_ram_mb}M",
        "--add-modules=jdk.incubator.vector",
        "-jar", str(SERVER_JAR),
        "--commands-settings", str(BASE_DIR / "config" / "commands.yml"),
        "--spigot-settings", str(BASE_DIR / "config" / "spigot.yml"),
        "--world-dir", str(BASE_DIR / "worlds"),
        "--bukkit-settings", str(BASE_DIR / "config" / "bukkit.yml"),
        "--config", str(BASE_DIR / "config" / "server.properties"),
        "--paper-settings", str(BASE_DIR / "config" / "paper.yml"),
        "--purpur-settings", str(BASE_DIR / "config" / "purpur.yml"),
        "-nogui"
    ]
    if additional_params:
        additional_args = additional_params.split()
        command.extend(additional_args)
        logger.info(f"Added additional parameters: {additional_params}")
    logger.info(f"Server command: {' '.join(command)}")
    print("=" * 50)
    print("Starting Minecraft server...")
    print("")
    print("Command:", " ".join(command))
    print("=" * 50)
    print("")
    SERVER_START_TIME = time.time()
    SERVER_END_TIME = None
    process = None
    try:
        logger.info("Starting server process")
        process = subprocess.Popen(
            command,
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
        logger.info(f"Server process started with PID: {process.pid}")
        for line in process.stdout:
            print(line, end="")
        process.wait()
        SERVER_END_TIME = time.time()
        uptime_seconds, uptime_str, _ = get_uptime()
        logger.info(f"Server process ended with return code: {process.returncode}, uptime: {uptime_str}")
        if uptime_seconds >= 60:
            print(f"\nServer uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
        else:
            print(f"\nServer uptime: {uptime_str}")
        if process.returncode != 0:
            logger.warning(f"Server crashed with exit code: {process.returncode}")
            handle_server_crash(process, uptime_str)
        else:
            if check_logs_for_errors():
                logger.info("Server stopped normally but errors found in logs")
                if ask_user_for_crash_analysis():
                    logger.info("User requested crash analysis for normal exit with errors")
                    analyze_server_crash(0, uptime_str)
                else:
                    logger.info("User skipped crash analysis for normal exit with errors")
                    print("\nServer stopped normally (with warnings).\n")
            else:
                logger.info("Server stopped normally without errors")
                print("\nServer stopped normally.\n")
    except KeyboardInterrupt:
        SERVER_END_TIME = time.time()
        logger.warning("Server shutdown requested by user (KeyboardInterrupt)")
        print("\nServer shutdown requested by user (KeyboardInterrupt).\n")
        uptime_seconds, uptime_str, _ = get_uptime()
        if uptime_seconds >= 60:
            print(f"Server uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
        else:
            print(f"Server uptime: {uptime_str}")
        if process:
            logger.info(f"Terminating server process (PID: {process.pid})")
            process.terminate()
            process.wait()
            logger.info("Server process terminated")
        print("Checking for potential issues that caused the interrupt...")
        if check_logs_for_errors():
            logger.info("Errors found in logs after user interrupt")
            if ask_user_for_interrupt_analysis():
                logger.info("User requested interrupt analysis")
                analyze_server_crash(-1, uptime_str)
            else:
                logger.info("User skipped interrupt analysis")
                print("\nServer interrupted by user.\n")
        else:
            logger.info("No errors found in logs after user interrupt")
            print("\nServer interrupted by user (no issues detected in logs).\n")
    except Exception as e:
        logger.error(f"Error starting server: {e}")
        print(f"Error starting server: {e}\n")
        SERVER_END_TIME = time.time()
        uptime_seconds, uptime_str, _ = get_uptime()
        if uptime_seconds >= 60:
            print(f"Server uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
        else:
            print(f"Server uptime: {uptime_str}")
        if process and process.poll() is None:
            logger.info(f"Terminating server process due to error (PID: {process.pid})")
            process.terminate()
            process.wait()
        if process:
            uptime_seconds, uptime_str, _ = get_uptime()
            logger.warning(f"Handling server crash after error, uptime: {uptime_str}")
            handle_server_crash(process, uptime_str)

def format_backup_name(filename, version):
    if filename == "server.zip":
        return version
    pattern = r"^\d+\.\d+\.\d+_(\d{8})_(\d{6})\.zip$"
    match = re.match(pattern, filename)
    if match:
        date_str = match.group(1)
        time_str = match.group(2)
        try:
            date_obj = datetime.datetime.strptime(date_str + time_str, "%Y%m%d%H%M%S")
            return date_obj.strftime("%Y-%m-%d %H:%M:%S")
        except ValueError:
            pass
    return filename.replace(".zip", "")

def rollback_version():
    logger.info("Starting rollback_version function")
    if not create_lock(["--rollback"]):
        logger.error("Failed to create lock for rollback operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Loading configuration for current version")
        config = load_config()
        current_version = config.get("version", "unknown")
        logger.info(f"Current server version: {current_version}")
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        print("Error: Could not load configuration to determine current version\n")
        remove_lock()
        return
    backup_dir = BUNDLES_DIR / current_version
    logger.info(f"Backup directory: {backup_dir}")
    if not backup_dir.exists():
        logger.warning(f"Backup directory does not exist: {backup_dir}")
        print(f"\nNo backups found for version {current_version}")
        print("")
        remove_lock()
        return
    backup_files = list(backup_dir.glob("*.zip"))
    logger.info(f"Found {len(backup_files)} backup files in directory")
    if not backup_files:
        logger.warning(f"No backup files found in directory: {backup_dir}")
        print(f"\nNo backup files found for version {current_version}")
        print("")
        remove_lock()
        return
    backup_files.sort(key=os.path.getmtime, reverse=True)
    logger.info(f"Sorted backup files by modification time (newest first)")
    print("\nAvailable Backups:")
    print("======================")
    backup_list = []
    for i, backup_file in enumerate(backup_files, 1):
        friendly_name = format_backup_name(backup_file.name, current_version)
        backup_list.append((backup_file, friendly_name))
        file_size = os.path.getsize(backup_file)
        logger.debug(f"Backup {i}: {backup_file.name} ({format_file_size(file_size)}), friendly name: {friendly_name}")
        print(f"{i}. {friendly_name}")
    print("======================")
    logger.info(f"Displayed {len(backup_list)} available backups")
    try:
        selection = input("\nPlease select one to rollback: ").strip()
        logger.info(f"User selection input: '{selection}'")
        if not selection:
            logger.info("User cancelled selection (empty input)")
            print("No selection made.\n")
            remove_lock()
            return
        index = int(selection) - 1
        if index < 0 or index >= len(backup_list):
            logger.warning(f"Invalid selection index: {index}, valid range: 0-{len(backup_list)-1}")
            print("Invalid selection.\n")
            remove_lock()
            return
        selected_file, friendly_name = backup_list[index]
        file_size = os.path.getsize(selected_file)
        logger.info(f"Selected backup: {selected_file.name} ({format_file_size(file_size)}), friendly name: {friendly_name}")
        print(f"\nSelected file: {selected_file.name}")
        print("Rolling back now, please wait...")
        temp_dir = BASE_DIR / "temp_rollback"
        logger.info(f"Temporary directory for extraction: {temp_dir}")
        if temp_dir.exists():
            logger.info(f"Temporary directory already exists, removing: {temp_dir}")
            shutil.rmtree(temp_dir)
        temp_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Created temporary directory: {temp_dir}")
        logger.info(f"Extracting backup archive: {selected_file}")
        try:
            with zipfile.ZipFile(selected_file, "r") as zipf:
                file_count = len(zipf.namelist())
                logger.info(f"Backup archive contains {file_count} files/entries")
                zipf.extractall(temp_dir)
                logger.info(f"Successfully extracted {file_count} files to temporary directory")
        except zipfile.BadZipFile as e:
            logger.error(f"Bad ZIP file error: {e}", exc_info=True)
            print("Error: The backup file appears to be corrupted or not a valid ZIP archive\n")
            if temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info("Cleaned up temporary directory after error")
            remove_lock()
            return
        except Exception as e:
            logger.error(f"Error extracting backup file: {e}", exc_info=True)
            print(f"Error extracting backup file: {e}\n")
            if temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info("Cleaned up temporary directory after error")
            remove_lock()
            return
        if not temp_dir.exists() or not any(temp_dir.iterdir()):
            logger.error(f"Extraction failed or produced empty directory: {temp_dir}")
            print("Error: Failed to extract backup file or backup is empty\n")
            if temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info("Cleaned up empty temporary directory")
            remove_lock()
            return
        logger.info("Checking extracted content...")
        extracted_items = list(temp_dir.iterdir())
        logger.info(f"Found {len(extracted_items)} items in temporary directory")
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns")
        logger.debug(f"Exclude patterns: {exclude_list}")
        logger.info("Starting cleanup of current directory before rollback")
        deleted_count = 0
        skipped_count = 0
        for item in BASE_DIR.iterdir():
            item_name = item.name
            if any(fnmatch.fnmatch(item_name, pattern) for pattern in exclude_list):
                skipped_count += 1
                logger.debug(f"Skipped item (excluded): {item_name}")
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
                deleted_count += 1
            except Exception as cleanup_error:
                logger.error(f"Failed to remove {item_name}: {cleanup_error}")
                skipped_count += 1
        logger.info(f"Cleanup completed: {deleted_count} items removed, {skipped_count} items skipped")
        logger.info("Copying extracted files to current directory")
        copied_count = 0
        for item in temp_dir.iterdir():
            dest = BASE_DIR / item.name
            try:
                if item.is_dir():
                    if dest.exists():
                        shutil.rmtree(dest)
                        logger.debug(f"Removed existing directory: {dest.name}")
                    shutil.copytree(item, dest, symlinks=True)
                else:
                    shutil.copy2(item, dest)
                copied_count += 1
            except Exception as copy_error:
                logger.error(f"Failed to copy {item.name}: {copy_error}")
        logger.info(f"File copy completed: {copied_count} items copied")
        logger.info("Cleaning up temporary directory")
        try:
            shutil.rmtree(temp_dir, ignore_errors=True)
            logger.info(f"Successfully removed temporary directory: {temp_dir}")
        except Exception as cleanup_error:
            logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        logger.info("Cleaning up other temporary directories if they exist")
        temp_save_dir = BASE_DIR / "temp_save"
        if temp_save_dir.exists():
            try:
                shutil.rmtree(temp_save_dir, ignore_errors=True)
                logger.info(f"Cleaned up temp_save directory: {temp_save_dir}")
            except Exception as e:
                logger.warning(f"Failed to clean up temp_save directory: {e}")
        logger.info("Rollback completed successfully")
        print("Server rollbacked successfully\n")
    except ValueError:
        logger.error("Invalid input - expected a number")
        print("Invalid input. Please enter a number.\n")
    except KeyboardInterrupt:
        logger.warning("Rollback operation interrupted by user")
        print("\nRollback interrupted by user.\n")
        temp_dir = BASE_DIR / "temp_rollback"
        if temp_dir.exists():
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info("Cleaned up temporary directory after user interrupt")
            except Exception as e:
                logger.error(f"Failed to clean up temporary directory after interrupt: {e}")
    except Exception as e:
        logger.error(f"Error during rollback: {e}", exc_info=True)
        print(f"Error during rollback: {e}")
        import traceback
        traceback.print_exc()
        temp_dir = BASE_DIR / "temp_rollback"
        if temp_dir.exists():
            try:
                shutil.rmtree(temp_dir, ignore_errors=True)
                logger.info("Cleaned up temporary directory after error")
            except Exception as cleanup_error:
                logger.error(f"Failed to clean up temporary directory after error: {cleanup_error}")
    finally:
        logger.info("Removing task lock for rollback operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock for rollback operation")

def disable_all_plugins():
    if not PLUGINS_DIR.exists():
        print("Plugins directory not found.")
        return False
    plugin_files = list(PLUGINS_DIR.glob("*.jar"))
    if not plugin_files:
        print("No plugins found to disable.")
        return True
    disabled_count = 0
    for plugin_path in plugin_files:
        if not plugin_path.name.endswith('.disabled'):
            new_path = plugin_path.parent / (plugin_path.name + ".disabled")
            try:
                plugin_path.rename(new_path)
                disabled_count += 1
            except Exception as e:
                print(f"Error disabling {plugin_path.name}: {e}")
                return False
    print(f"Successfully disabled {disabled_count} plugins.")
    return True

def upgrade_server(force=False):
    logger.info(f"Starting upgrade_server function, force mode: {force}")
    command = ["--upgrade"]
    if force:
        command.append("force")
        logger.info(f"Force mode enabled, command: {' '.join(command)}")
    if not create_lock(command):
        logger.error("Failed to create lock for upgrade operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Initializing server upgrade interface")
        print("\n" + "=" * 50)
        print("               Server Core Upgrade")
        print("=" * 50)
        if force:
            logger.info("Force mode: showing all available versions regardless of compatibility")
            print("\nForce mode: Showing all available versions regardless of compatibility.\n")
        try:
            logger.info("Loading configuration to determine current version")
            config = load_config()
            current_version = config.get("version", "unknown")
            logger.info(f"Current server version from config: {current_version}")
        except Exception as e:
            logger.error(f"Failed to load configuration: {e}")
            print("Error: Could not determine current server version.")
            print("Please ensure the server is properly configured.\n")
            return
        print(f"Current server version: {current_version}")
        try:
            current_major = '.'.join(current_version.split('.')[:2])
            logger.info(f"Parsed current major version: {current_major}")
        except Exception as e:
            logger.error(f"Could not parse current version format '{current_version}': {e}")
            print("Error: Could not parse current version format.")
            return
        backup_choice = input("\nDo you want to create a backup before upgrading? (Y/N): ").strip().upper()
        logger.info(f"User backup choice: {backup_choice}")
        if backup_choice == "Y":
            logger.info("User chose to create backup before upgrade")
            print("Creating backup...")
            backup_version()
        else:
            logger.info("User skipped backup before upgrade")
        available_versions = []
        if BUNDLES_DIR.exists():
            logger.info("Scanning bundles directory for available versions")
            for version_dir in BUNDLES_DIR.iterdir():
                if version_dir.is_dir():
                    core_zip = version_dir / "core.zip"
                    if core_zip.exists():
                        version_name = version_dir.name
                        if force:
                            available_versions.append(version_name)
                            logger.debug(f"Force mode: added version {version_name}")
                        else:
                            try:
                                version_major = '.'.join(version_name.split('.')[:2])
                                if (compare_versions(version_name, current_version) >= 0 and 
                                    version_major == current_major):
                                    available_versions.append(version_name)
                                    logger.debug(f"Compatible version found: {version_name} (major: {version_major})")
                                else:
                                    logger.debug(f"Skipping incompatible version: {version_name} (major: {version_major}, current major: {current_major})")
                            except Exception as e:
                                logger.warning(f"Could not parse version {version_name}: {e}")
                                continue
            logger.info(f"Found {len(available_versions)} available versions")
        else:
            logger.warning("Bundles directory does not exist")
        if not available_versions:
            if force:
                logger.warning(f"No versions found in bundles directory")
                print(f"\nNo versions found in bundles directory.")
            else:
                logger.warning(f"No compatible versions found for upgrade from {current_version}")
                print(f"\nNo compatible versions found for upgrade.")
                print(f"Current version: {current_version}")
                print(f"Looking for versions with major version {current_major} or higher.")
                print('Use "--upgrade force" to show all available versions.\n')
            return
        sorted_versions = sorted(
            available_versions, 
            key=lambda v: [int(n) for n in v.split('.')], 
            reverse=True
        )
        logger.info(f"Sorted {len(sorted_versions)} versions for display")
        if force:
            print(f"\nAll available versions:")
        else:
            print('\nUse "--upgrade force" to show all available versions.')
            print(f"Available upgrade versions (compatible with {current_major}.x):")
        print("=" * 30)
        for i, version in enumerate(sorted_versions, 1):
            if force:
                try:
                    version_major = '.'.join(version.split('.')[:2])
                    if version_major != current_major:
                        status = "! INCOMPATIBLE"
                        logger.debug(f"Version {version}: INCOMPATIBLE (major: {version_major})")
                    elif compare_versions(version, current_version) > 0:
                        status = "↑ NEWER"
                        logger.debug(f"Version {version}: NEWER")
                    elif compare_versions(version, current_version) == 0:
                        status = "= CURRENT"
                        logger.debug(f"Version {version}: CURRENT")
                    else:
                        status = "↓ OLDER"
                        logger.debug(f"Version {version}: OLDER")
                except Exception as e:
                    logger.warning(f"Could not determine status for version {version}: {e}")
                    status = "? UNKNOWN"
            else:
                status = "↑ NEWER" if compare_versions(version, current_version) > 0 else "= CURRENT"
                logger.debug(f"Version {version}: {status}")
            print(f"{i}. {version} {status}")
        print("=" * 30)
        try:
            selection = input("\nSelect a version to upgrade to (number): ").strip()
            logger.info(f"User selection input: '{selection}'")
            if not selection:
                logger.info("User cancelled selection (empty input)")
                print("No selection made.\n")
                return
            index = int(selection) - 1
            if index < 0 or index >= len(sorted_versions):
                logger.warning(f"Invalid selection index: {index}, valid range: 0-{len(sorted_versions)-1}")
                print("Invalid selection.")
                return
            selected_version = sorted_versions[index]
            logger.info(f"Selected version: {selected_version}")
            print(f"Selected version: {selected_version}")
            if force:
                try:
                    selected_major = '.'.join(selected_version.split('.')[:2])
                    if selected_major != current_major:
                        logger.warning(f"Major version mismatch: current={current_major}, selected={selected_major}")
                        print(f"\nWARNING: Major version mismatch!")
                        print(f"Current: {current_version} (major {current_major})")
                        print(f"Selected: {selected_version} (major {selected_major})")
                        print("This upgrade may cause world corruption or plugin incompatibility!")
                        confirm = input("\nAre you sure you want to continue? (Y/N): ").strip().upper()
                        logger.info(f"User confirmation for major version mismatch: {confirm}")
                        if confirm != "Y":
                            logger.info("User cancelled upgrade due to major version mismatch")
                            print("Upgrade canceled.\n")
                            return
                    elif compare_versions(selected_version, current_version) < 0:
                        logger.warning(f"Downgrade detected: from {current_version} to {selected_version}")
                        print(f"\nWARNING: Downgrading from {current_version} to {selected_version}")
                        print("This may cause data loss or compatibility issues!")
                        confirm = input("\nAre you sure you want to continue? (Y/N): ").strip().upper()
                        logger.info(f"User confirmation for downgrade: {confirm}")
                        if confirm != "Y":
                            logger.info("User cancelled downgrade")
                            print("Upgrade canceled.\n")
                            return
                except Exception as e:
                    logger.warning(f"Could not compare versions: {e}")
            if selected_version == current_version:
                logger.info("Selected version is same as current version")
                print("Selected version is the same as current version.")
                reinstall = input("Do you want to reinstall the current version? (Y/N): ").strip().upper()
                logger.info(f"User reinstall choice: {reinstall}")
                if reinstall != "Y":
                    logger.info("User cancelled reinstall")
                    print("Upgrade canceled.\n")
                    return
            if check_for_updates(selected_version):
                logger.info(f"Update available for version {selected_version}")
                update_choice = input("\nNewer build available. Download now? (Y/N): ").strip().upper()
                logger.info(f"User update choice: {update_choice}")
                if update_choice == "Y":
                    logger.info("User chose to download newer build")
                    print("Updating to latest build...")
                    download_version(selected_version)
                else:
                    logger.info("User skipped downloading newer build")
            show_version_info(selected_version)
            confirm = input(f"\nAre you sure you want to upgrade from {current_version} to {selected_version}? (Y/N): ").strip().upper()
            logger.info(f"Final user confirmation for upgrade: {confirm}")
            if confirm != "Y":
                logger.info("User cancelled upgrade after final confirmation")
                print("Upgrade canceled.\n")
                return
            print("\nUpgrading server core...")
            core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
            logger.info(f"Core ZIP path for selected version: {core_zip_path}")
            if not core_zip_path.exists():
                logger.error(f"Core package not found for version {selected_version}")
                print(f"Error: Core package not found for version {selected_version}")
                return
            temp_jar_dir = BASE_DIR / "temp_jar"
            logger.info(f"Temporary JAR directory: {temp_jar_dir}")
            if temp_jar_dir.exists():
                logger.info(f"Temporary directory already exists, removing: {temp_jar_dir}")
                shutil.rmtree(temp_jar_dir)
            temp_jar_dir.mkdir()
            logger.info(f"Created temporary directory: {temp_jar_dir}")
            try:
                logger.info(f"Extracting core.zip from {core_zip_path}")
                with zipfile.ZipFile(core_zip_path, 'r') as zipf:
                    file_count = len(zipf.namelist())
                    logger.info(f"Core ZIP contains {file_count} files/entries")
                    zipf.extractall(temp_jar_dir)
                    logger.info(f"Extracted {file_count} files to temporary directory")
                core_jar_temp = temp_jar_dir / "core.jar"
                logger.info(f"Looking for core.jar in extracted files: {core_jar_temp}")
                if not core_jar_temp.exists():
                    logger.error("core.jar not found in the extracted package")
                    print("Error: core.jar not found in the package.")
                    return
                logger.info("core.jar found in extracted package")
                if SERVER_JAR.exists():
                    backup_jar = BASE_DIR / "core.jar.bak"
                    shutil.copy2(SERVER_JAR, backup_jar)
                    logger.info(f"Backed up current core.jar to: {backup_jar}")
                    print("Backed up current core.jar")
                shutil.copy2(core_jar_temp, SERVER_JAR)
                logger.info(f"Copied new core.jar from {core_jar_temp} to {SERVER_JAR}")
                print("\nCore upgraded successfully.")
                config = configparser.ConfigParser()
                config.read(CONFIG_FILE)
                if "SERVER" in config:
                    config["SERVER"]["version"] = selected_version
                    with open(CONFIG_FILE, "w") as f:
                        config.write(f)
                    logger.info(f"Updated configuration to version {selected_version}")
                    print(f"Updated configuration to version {selected_version}")
                else:
                    logger.warning("SERVER section not found in config, cannot update version")
            except Exception as e:
                logger.error(f"Error during core upgrade: {e}", exc_info=True)
                print(f"Error during core upgrade: {e}")
                return
            finally:
                if temp_jar_dir.exists():
                    logger.info(f"Cleaning up temporary directory: {temp_jar_dir}")
                    try:
                        shutil.rmtree(temp_jar_dir)
                        logger.info(f"Successfully removed temporary directory: {temp_jar_dir}")
                    except Exception as e:
                        logger.error(f"Failed to remove temporary directory {temp_jar_dir}: {e}")
            plugin_choice = input("\nDo you want to disable all plugins for data safety? (Y/N): ").strip().upper()
            logger.info(f"User plugin disable choice: {plugin_choice}")
            if plugin_choice == "Y":
                if disable_all_plugins():
                    logger.info("All plugins have been disabled")
                    print("All plugins have been disabled.")
                else:
                    logger.warning("Failed to disable some plugins")
                    print("Failed to disable some plugins.")
            else:
                logger.info("User chose to leave plugins unchanged")
                print("Plugins left unchanged.")
            logger.info("Server upgrade completed successfully")
            print("\nServer upgrade completed successfully!")
            print("Please review your plugin compatibility before starting the server.\n")
        except ValueError:
            logger.error("Invalid input in version selection - expected a number")
            print("Invalid input. Please enter a number.\n")
        except Exception as e:
            logger.error(f"Error during upgrade process: {e}", exc_info=True)
            print(f"Error during upgrade process: {e}\n")
    finally:
        logger.info("Removing task lock for upgrade operation")
        if remove_lock():
            logger.info("Task lock removed successfully")
        else:
            logger.error("Failed to remove task lock for upgrade operation")

def compare_versions(version1, version2):
    try:
        v1_parts = [int(x) for x in version1.split('.')]
        v2_parts = [int(x) for x in version2.split('.')]
        max_len = max(len(v1_parts), len(v2_parts))
        v1_parts.extend([0] * (max_len - len(v1_parts)))
        v2_parts.extend([0] * (max_len - len(v2_parts)))
        for i in range(max_len):
            if v1_parts[i] > v2_parts[i]:
                return 1
            elif v1_parts[i] < v2_parts[i]:
                return -1
        return 0
    except:
        return 0

def compare_script_versions(current, latest):
    try:
        current_parts = [int(x) for x in current.split('.')]
        latest_parts = [int(x) for x in latest.split('.')]
        max_len = max(len(current_parts), len(latest_parts))
        current_parts.extend([0] * (max_len - len(current_parts)))
        latest_parts.extend([0] * (max_len - len(latest_parts)))
        for i in range(max_len):
            if current_parts[i] < latest_parts[i]:
                return -1
            elif current_parts[i] > latest_parts[i]:
                return 1
        return 0
    except Exception as e:
        print(f"Error comparing versions: {e}")

def check_self_update(force=False):
    logger.info(f"Starting self update check (force mode: {force})")
    print("\n" + "=" * 50)
    print("                Self Update Check")
    print("=" * 50)
    print(f"\nCurrent script version: {SCRIPT_VERSION}")
    if force:
        logger.info("Force mode enabled, bypassing version check")
        print("\nForce mode: Bypassing version check, will download latest version directly.")
        confirm = input("\nDo you want to download the latest version from GitHub? (Y/N): ").strip().upper()
        if confirm == "Y":
            logger.info("User confirmed force download")
            return download_latest_version()
        else:
            logger.info("User canceled force download")
            print("Download canceled.\n")
            return False
    logger.info("Checking for updates from GitHub...")
    print("Checking for updates...\n")
    update_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/update.json"
    try:
        with urllib.request.urlopen(update_url, timeout=10) as response:
            update_info = json.loads(response.read().decode())
        latest_version = update_info.get("latest_version")
        expected_md5 = update_info.get("md5")
        release_date = update_info.get("date", "Unknown")
        if not latest_version or not expected_md5:
            logger.error("Invalid update information format received")
            print("Error: Invalid update information format.\n")
            return False
        logger.info(f"Latest version available: {latest_version} (Released: {release_date})")
        print(f"Latest version available: {latest_version} (Released: {release_date})")
        comparison_result = compare_script_versions(SCRIPT_VERSION, latest_version)
        if comparison_result >= 0:
            logger.info(f"Already running latest version (current: {SCRIPT_VERSION}, latest: {latest_version})")
            print("You are already running the latest version.")
            print('You can use "--version force" to download the latest version.\n')
            return True
        else:
            logger.info(f"New version available (current: {SCRIPT_VERSION}, latest: {latest_version})")
            print(f"\nNew version {latest_version} is available!")
            confirm = input("Do you want to download and update? (Y/N): ").strip().upper()
            if confirm != "Y":
                logger.info("User canceled update")
                print("Update canceled.")
                return False
            logger.info("User confirmed update")
            return download_latest_version()
    except urllib.error.URLError as e:
        logger.error(f"Network error checking for updates: {e}")
        print(f"Network error: Could not check for updates - {e}\n")
        return False
    except Exception as e:
        logger.error(f"Error checking for updates: {e}")
        print(f"Error checking for updates: {e}\n")
        return False

def download_latest_version():
    logger.info("Starting download of latest version")
    script_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/start.sh"
    update_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/update.json"
    print(f"\nDownloading latest version from: {script_url}")
    try:
        logger.info("Fetching update metadata...")
        with urllib.request.urlopen(update_url, timeout=10) as response:
            update_info = json.loads(response.read().decode())
        expected_md5 = update_info.get("md5")
        latest_version = update_info.get("latest_version", "Unknown")
        if not expected_md5:
            logger.warning("No MD5 hash available for verification")
            print("Warning: Could not verify file integrity - no MD5 hash available.")
        logger.info(f"Starting download of version {latest_version}")
        print("\nDownload started...")
        start_time = time.time()
        with urllib.request.urlopen(script_url, timeout=30) as response:
            script_content = response.read()
        elapsed_time = time.time() - start_time
        file_size = len(script_content)
        download_speed = file_size / elapsed_time / 1024
        logger.info(f"Download completed in {elapsed_time:.2f}s, size: {file_size} bytes, speed: {download_speed:.2f} KB/s")
        print(f"\nDownload completed in {elapsed_time:.2f} seconds.")
        print(f"Download speed: {download_speed:.2f} KB/s\n")
        if expected_md5:
            logger.info("Verifying file integrity with MD5...")
            print("Verifying file integrity...")
            file_hash = hashlib.md5()
            file_hash.update(script_content)
            actual_md5 = file_hash.hexdigest()
            if actual_md5 != expected_md5:
                logger.error(f"MD5 verification failed (expected: {expected_md5}, got: {actual_md5})")
                print(f"MD5 verification failed!")
                print(f"Expected: {expected_md5}")
                print(f"Got: {actual_md5}")
                print("\nThe downloaded file may be corrupted or tampered with.")
                print("Update aborted for security reasons.")
                return False
            logger.info("MD5 verification passed")
            print("MD5 verification passed.\n")
        current_script = Path(__file__).resolve()
        backup_script = current_script.with_name(current_script.name + '.bak')
        new_script = current_script.with_name(current_script.name + '.new')
        try:
            shutil.copy2(current_script, backup_script)
            logger.info(f"Backup created: {backup_script}")
            print(f"Backup created: {backup_script}")
        except Exception as e:
            logger.warning(f"Could not create backup: {e}")
            print(f"Warning: Could not create backup: {e}")
        with open(new_script, 'wb') as f:
            f.write(script_content)
        try:
            if platform.system() != "Windows":
                os.chmod(new_script, 0o755)
                logger.info("Set executable permissions on new script")
        except Exception as e:
            logger.warning(f"Could not set executable permissions: {e}")
            print(f"Warning: Could not set executable permissions: {e}")
        try:
            if platform.system() == "Windows":
                os.remove(current_script)
                shutil.move(new_script, current_script)
            else:
                os.replace(new_script, current_script)
            logger.info(f"Update completed successfully to version {latest_version}")
            print("\nUpdate completed successfully!")
            print(f"Script has been updated to version {latest_version}.")
            print("Please run the script again to use the new version.")
            print("")
            return True
        except Exception as e:
            logger.error(f"Failed to replace current script: {e}")
            print(f"\nFailed to replace the current script: {e}")
            print("This is usually due to file permission issues or the script being in use.")
            print("\nManual replacement required:")
            print("=" * 40)
            if platform.system() == "Windows":
                print("Please perform the following steps manually:")
                print(f"1. Delete the current script: {current_script}")
                print(f"2. Rename '{new_script}' to '{current_script.name}'")
            else:
                print("Please run these commands manually:")
                print(f"  rm '{current_script}'")
                print(f"  mv '{new_script}' '{current_script}'")
                print(f"  chmod +x '{current_script}'")
            print("=" * 40)
            return False
    except Exception as e:
        logger.error(f"Error during update process: {e}")
        print(f"Error during update process: {e}\n")
        new_script = Path(__file__).resolve().with_name(current_script.name + '.new')
        if new_script.exists():
            try:
                new_script.unlink()
                logger.info("Cleaned up temporary new script file")
            except:
                logger.warning("Could not clean up temporary new script file")
                pass
        return False

def show_help():
    print("=" * 51)
    print(f"      Minecraft Server Management Tool (v{SCRIPT_VERSION})")
    print("=" * 51)
    print("")
    print("A comprehensive command-line tool for managing")
    print("Minecraft server versions, backups, plugins and")
    print("other configurations with ease.")
    print("")
    print("Usage:")
    print(f"  {SCRIPT_NAME} [command] [options]")
    print("")
    print("Commands:")
    print("  (no command)           Start the server")
    print("  --init [auto]          Initialize new server configuration")
    print("  --info                 Show current server configuration")
    print("  --list                 List all available versions")
    print("  --plugins [analyze]    Show installed plugins and toggle them")
    print("  --save <ver>           Save current version to bundles")
    print("  --backup               Create timestamped backup of current version")
    print("  --worlds               Manage worlds with multiple options")
    print("  --get [ver]            Fetch a Purpur server info and download")
    print("  --new                  Save current server and create a new one")
    print("  --rollback             Rollback to a previous backup")
    print("  --delete <ver>         Delete specified version from bundles")
    print("  --change <ver>         Switch to specified version")
    print("  --upgrade [force]      Upgrade server core to compatible version")
    print("  --cleanup              Clean up server files to free up space")
    print("  --dump [keyword]       Create a compressed dump of log files")
    print("  --settings             Edit server properties and settings")
    print("  --players              Manage banned players, IPs, and whitelist")
    print("  --version [force]      Check for script updates and update if available")
    print("  --license              Show the open source license for this tool")
    print("  --help                 Show this help message")
    print("")

clear_screen()

def main():
    global logger
    logger = setup_logger()
    logger.info(f"Starting {SCRIPT_NAME} version {SCRIPT_VERSION}")
    try:
        logger.info("Checking environment...")
        if not check_environment_change():
            logger.warning("Environment check failed or user chose to exit")
            return
        pending_command = handle_pending_task()
        if pending_command:
            logger.info(f"Resuming pending command: {' '.join(pending_command)}")
            sys.argv = [sys.argv[0]] + pending_command
        BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
        logger.info(f"Working directory: {BASE_DIR}")
        logger.info(f"User executed: {' '.join(sys.argv)}")
        if len(sys.argv) == 1:
            logger.info("Starting server")
            start_server()
        elif sys.argv[1] == "--init":
            logger.info("Initializing server configuration")
            if len(sys.argv) > 2 and sys.argv[2].lower() == "auto":
                logger.info("Using auto initialization mode")
                init_config_auto()
            else:
                logger.info("Using manual initialization mode")
                init_config()
        elif sys.argv[1] == "--info":
            logger.info("Showing server configuration info")
            show_info()
        elif sys.argv[1] == "--list":
            logger.info("Listing available versions")
            list_versions()
        elif sys.argv[1] == "--save" and len(sys.argv) > 2:
            version = sys.argv[2]
            logger.info(f"Saving current version as: {version}")
            save_version(version)
        elif sys.argv[1] == "--backup":
            logger.info("Creating backup of current version")
            backup_version()
        elif sys.argv[1] == "--delete" and len(sys.argv) > 2:
            version = sys.argv[2]
            logger.info(f"Deleting version: {version}")
            delete_version(version)
        elif sys.argv[1] == "--change" and len(sys.argv) > 2:
            version = sys.argv[2]
            logger.info(f"Changing to version: {version}")
            change_version(version)
        elif sys.argv[1] == "--cleanup":
            logger.info("Cleaning up server files")
            cleanup_files()
        elif sys.argv[1] == "--dump":
            logger.info("Dumping log files")
            dump_logs()
        elif sys.argv[1] == "--plugins" and len(sys.argv) > 2 and sys.argv[2] == "analyze":
            logger.info("Analyzing plugin dependencies")
            analyze_plugin_dependencies_cli()
        elif sys.argv[1] == "--plugins":
            logger.info("Managing plugins")
            manage_plugins_with_dependencies()
        elif sys.argv[1] == "--rollback":
            logger.info("Rolling back to previous version")
            rollback_version()
        elif sys.argv[1] == "--get":
            if len(sys.argv) > 2:
                version = sys.argv[2]
                logger.info(f"Fetching version info for: {version}")
                download_version(version)
            else:
                logger.info("Fetching available versions list")
                download_version()
        elif sys.argv[1] == "--worlds":
            logger.info("Managing worlds")
            manage_worlds()
        elif sys.argv[1] == "--new":
            logger.info("Creating new server")
            create_new_server()
        elif sys.argv[1] == "--upgrade":
            if len(sys.argv) > 2 and sys.argv[2].lower() == "force":
                logger.info("Force upgrading server")
                upgrade_server(force=True)
            else:
                logger.info("Upgrading server")
                upgrade_server(force=False)
        elif sys.argv[1] == "--version":
            if len(sys.argv) > 2 and sys.argv[2].lower() == "force":
                logger.info("Force checking script version")
                check_self_update(force=True)
            else:
                logger.info("Checking script version")
                check_self_update(force=False)
        elif sys.argv[1] == "--settings":
            logger.info("Editing server settings")
            edit_server_settings()
        elif sys.argv[1] == "--license":
            logger.info("Showing license information")
            show_license()
        elif sys.argv[1] == "--players":
            logger.info("Managing player lists")
            manage_player_lists()
        elif sys.argv[1] == "--help":
            logger.info("Showing help")
            show_help()
        else:
            logger.warning(f"Invalid command: {' '.join(sys.argv[1:])}")
            print("\nInvalid command or arguments")
            print(f"Use '{SCRIPT_NAME} --help' for usage information\n")
            sys.exit(1)
        logger.info("Command execution completed")
    except KeyboardInterrupt:
        logger.warning("Script interrupted by user (KeyboardInterrupt)")
        print("\n\nScript interrupted by user\n")
        sys.exit(0)
    except SystemExit as e:
        logger.info(f"Script exiting with code: {e.code}\n")
        raise
    except Exception as e:
        logger.error(f"Unexpected error in main(): {e}\n", exc_info=True)
        print(f"\nAn unexpected error occurred: {e}")
        print("Check the log file for more details:", LOG_FILE, "\n")
        sys.exit(1)
    logger.info("Exiting script\n")

if __name__ == "__main__":
    main()
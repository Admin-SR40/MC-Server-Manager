#!/usr/bin/env python3

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
import uuid
from pathlib import Path

try:
    import yaml
except ImportError:
    print("\nError: PyYAML is not installed.\nPlease install it with: pip install PyYAML\n")
    sys.exit(1)

SCRIPT_VERSION = "5.2"

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
    "info.txt"
]

def get_device_id():
    try:
        hostname = socket.gethostname()
        
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
        except (subprocess.SubprocessError, FileNotFoundError):
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
                    
                    result2 = subprocess.run(
                        ['getprop', 'ro.product.manufacturer'],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=5
                    )
                    manufacturer = result2.stdout.strip() if result2.returncode == 0 else "unknown"
                    
                    android_id = f"{manufacturer}:{model}"
            except (subprocess.SubprocessError, FileNotFoundError):
                pass
        
        if not android_id:
            android_id = hostname
        
        device_str = f"{hostname}:{android_id}"
        return hashlib.md5(device_str.encode()).hexdigest()
        
    except Exception as e:
        print(f"Warning: Could not generate stable device ID: {e}")
        print(" - Using 'unknown' as device identifier")
        return "unknown"

def check_environment_change():
    read_only_commands = ["--help", "--license", "--info", "--list"]
    is_read_only_command = len(sys.argv) > 1 and sys.argv[1] in read_only_commands
    is_init_command = len(sys.argv) > 1 and sys.argv[1] == "--init"
    
    if is_read_only_command or is_init_command:
        return True

    if not CONFIG_FILE.exists():
        return True
    
    try:
        config = configparser.ConfigParser()
        config.read(CONFIG_FILE)
        
        if "SERVER" not in config or "device" not in config["SERVER"]:
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
                print("Exiting script...\n")
                sys.exit(0)
            
            return True
        
        stored_device_id = config["SERVER"]["device"]
        current_device_id = get_device_id()
        
        if stored_device_id == "unknown" or current_device_id == "unknown":
            print("\n" + "=" * 61)
            print("                 LIMITED ENVIRONMENT DETECTION")
            print("=" * 61)
            print("\nNote: Running on a system with limited device identification.")
            print("Environment change detection is disabled for this session.")
            print("\nIf you're experiencing issues, consider running --init again")
            print("to refresh the configuration.")
            print("\nContinuing with normal operation...\n")
            return True
        
        if stored_device_id == current_device_id:
            return True
        
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
                return handle_environment_change("manual")
            elif choice == "2":
                return handle_environment_change("auto")
            elif choice == "3":
                return update_device_id_and_continue()
            elif choice == "4":
                print("Exiting script...\n")
                sys.exit(0)
            else:
                print("Invalid choice. Please enter 1, 2, 3, or 4.")
                
    except Exception as e:
        print(f"Error during environment check: {e}")
        print("Continuing with normal operation...")
        return True

def handle_environment_change(init_type):
    try:
        if CONFIG_FILE.exists():
            backup_file = CONFIG_FILE.with_suffix('.cfg.bak')
            shutil.copy2(CONFIG_FILE, backup_file)
            print(f"\nConfiguration backed up to: {backup_file}")
        
        if init_type == "manual":
            print("Running manual initialization...")
            init_config()
        else:
            print("Running auto initialization...")
            init_config_auto()
        
        print("\nEnvironment configuration completed successfully!")
        print("Please run the script again to start the server.\n")
        sys.exit(0)
        
    except Exception as e:
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
        print("\n" + "=" * 50)
        print("          Server Configuration Editor")
        print("=" * 50)
        print("\nError: server.properties file not found!")
        print("Please start the server at least once to generate the file.")
        print("")
        return
    
    print("\n" + "=" * 50)
    print("          Server Configuration Editor")
    print("=" * 50)
    
    properties = {}
    try:
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    if '=' in line:
                        key, value = line.split('=', 1)
                        properties[key.strip()] = value.strip()
    except Exception as e:
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
                print("Exiting configuration editor.\n")
                break
            
            index = int(choice) - 1
            if index < 0 or index >= len(settings_config):
                print("Invalid selection. Please choose a valid number.")
                continue
            
            setting = settings_config[index]
            key = setting['key']
            current_value = properties.get(key, setting['default'])
            
            print(f"\nEditing: {setting['name']}")
            print(f"\nDescription: {setting['description']}")
            print(f"Current value: {current_value if current_value else '(empty)'}")
            
            if setting['type'] == 'boolean':
                print("\nOptions:")
                print("1. Enable (true)")
                print("2. Disable (false)")
                
                while True:
                    bool_choice = input("\nSelect option (1/2): ").strip()
                    if not bool_choice:
                        print("Cancelled editing.\n")
                        break
                    
                    if bool_choice == '1':
                        new_value = 'true'
                        break
                    elif bool_choice == '2':
                        new_value = 'false'
                        break
                    else:
                        print("Invalid choice. Please enter 1 or 2.")
                
                if bool_choice:
                    properties[key] = new_value
                    print(f" - {setting['name']} set to: {new_value}")
            
            elif setting['type'] == 'int':
                min_val, max_val = setting['range']
                print(f"\nValid range: {min_val} - {max_val}")
                
                while True:
                    int_input = input("\nEnter new value: ").strip()
                    if not int_input:
                        print("Cancelled editing.\n")
                        break
                    
                    try:
                        int_value = int(int_input)
                        if min_val <= int_value <= max_val:
                            properties[key] = str(int_value)
                            
                            if key == 'view-distance':
                                properties['simulation-distance'] = str(int_value)
                                print(f" - {setting['name']} set to: {int_value}")
                                print(f" - simulation-distance also set to: {int_value}")
                            else:
                                print(f" - {setting['name']} set to: {int_value}")
                            break
                        else:
                            print(f"Value must be between {min_val} and {max_val}.")
                    except ValueError:
                        print("Please enter a valid number.")
            
            elif setting['type'] == 'enum':
                print("\nAvailable options:")
                for j, option in enumerate(setting['options'], 1):
                    print(f"{j}. {option}")
                
                while True:
                    enum_choice = input("\nSelect option: ").strip()
                    if not enum_choice:
                        print("Cancelled editing.\n")
                        break
                    
                    try:
                        option_index = int(enum_choice) - 1
                        if 0 <= option_index < len(setting['options']):
                            new_value = setting['options'][option_index]
                            properties[key] = new_value
                            print(f" - {setting['name']} set to: {new_value}")
                            break
                        else:
                            print(f"Please enter a number between 1 and {len(setting['options'])}")
                    except ValueError:
                        print("Please enter a valid number.")
            
            elif setting['type'] == 'string':
                string_input = input("\nEnter new value: ").strip()
                if not string_input:
                    print("Cancelled editing.\n")
                else:
                    properties[key] = string_input
                    print(f" - {setting['name']} set to: {string_input}")
            
            try:
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
                
                print("\nConfiguration saved successfully!")
                
            except Exception as e:
                print(f"\nError saving configuration: {e}\n")
        
        except ValueError:
            print("Please enter a valid number.")
        except KeyboardInterrupt:
            print("\n\nOperation cancelled by user.\n")
            break
        except Exception as e:
            print(f"\nUnexpected error: {e}\n")

def show_license():
    print("\n" + "=" * 51)
    print("                License Information")
    print("=" * 51)
    
    print("\nFetching license...")
    
    license_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/LICENSE"
    
    try:
        with urllib.request.urlopen(license_url, timeout=10) as response:
            license_content = response.read().decode('utf-8')
        
        print("\nCurrent license:")
        print("=" * 51)
        print(license_content)
        print("=" * 51)
        print("")
        
    except urllib.error.HTTPError as e:
        print(f"\nError: Could not fetch license - HTTP {e.code}")
        print("The license file may not be available at the moment.\n")
    except urllib.error.URLError as e:
        print(f"\nError: Could not connect to server - {e.reason}")
        print("Please check your internet connection and try again.\n")
    except Exception as e:
        print(f"\nError: Failed to retrieve license - {e}")
        print("")

def format_uuid(uuid_str):
    if len(uuid_str) == 32 and '-' not in uuid_str:
        return f"{uuid_str[:8]}-{uuid_str[8:12]}-{uuid_str[12:16]}-{uuid_str[16:20]}-{uuid_str[20:32]}"
    return uuid_str

def get_mojang_uuid(username):
    try:
        url = f"https://api.mojang.com/users/profiles/minecraft/{username}"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode())
            return format_uuid(data.get("id")), data.get("name", username)
    except Exception as e:
        return None, username

def is_online_mode():
    if not SERVER_PROPERTIES.exists():
        return True
    
    try:
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip().startswith('online-mode='):
                    value = line.split('=', 1)[1].strip().lower()
                    return value == 'true'
    except Exception:
        pass
    
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
            print("")
            return
        
        list_choice = int(choice)
        if list_choice not in [1, 2, 3]:
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
        
        items = []
        if file_path.exists():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    items = json.load(f)
                if not isinstance(items, list):
                    items = []
            except Exception as e:
                print(f"Error reading {selected_file}: {e}")
                items = []
        
        print("\n" + format_list_table(items, selected_type))
        
        print("\nAvailable operations:")
        print(" A - Add new entry")
        if items:
            print(" D - Delete existing entry")
        print("")
        
        op_choice = input("Enter operation (A/D) or press Enter to exit: ").strip().upper()
        if not op_choice:
            print("")
            return
        
        if op_choice == 'A':
            add_to_list(items, selected_type, file_path)
        elif op_choice == 'D':
            if items:
                delete_from_list(items, selected_type, file_path)
            else:
                print("No entries to delete.\n")
        else:
            print("Invalid operation.\n")
            
    except ValueError:
        print("Invalid input. Please enter a number.\n")
    except Exception as e:
        print(f"Error: {e}\n")

def delete_from_list(items, list_type, file_path):
    if not items:
        print(f"\n{list_type} is empty. Nothing to delete.\n")
        return
    
    print(f"\nDeleting from {list_type}...")
    
    try:
        selection = input("Enter the number(s) to delete (space-separated): ").strip()
        if not selection:
            print("Operation cancelled.\n")
            return
        
        indices = [int(i.strip()) for i in selection.split()]
        indices.sort(reverse=True)
        
        valid_indices = [i for i in indices if 1 <= i <= len(items)]
        
        if not valid_indices:
            print("No valid numbers selected.\n")
            return
        
        print("\nThe following entries will be deleted:")
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                print(f" - IP: {item.get('ip', 'Unknown')}")
            else:
                print(f" - {item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})")
        
        confirm = input("\nAre you sure? (Y/N): ").strip().upper()
        if confirm != 'Y':
            print("Deletion cancelled.\n")
            return
        
        for idx in valid_indices:
            del items[idx-1]
        
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        
        print(f"\nSuccessfully deleted {len(valid_indices)} entries from {list_type}!\n")
        
    except ValueError:
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
        print(f"Error deleting from {list_type}: {e}\n")

def add_to_list(items, list_type, file_path):
    print(f"\nAdding to {list_type}...")
    
    if list_type == "banned-ips":
        
        while True:
            ip = input("Enter IP address to ban: ").strip()
            if not ip:
                print("Operation cancelled.\n")
                return
            
            if re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip):
                break
            else:
                print("Invalid IP address format. Please try again.")
        
        reason = input("Enter ban reason (optional): ").strip() or "Banned by an operator."
        
        new_entry = {
            "ip": ip,
            "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
            "source": "Server",
            "expires": "forever",
            "reason": reason
        }
        
        items.append(new_entry)
        
    else:
        online_mode = is_online_mode()
        
        if not online_mode and list_type in ["banned-players", "whitelist"]:
            print("\nWARNING: Server is in offline mode (online-mode=false).")
            print("Cannot add players to this list because UUID generation")
            print("differs between online and offline modes.")
            print("You can only remove existing entries in offline mode.")
            print("You can use in-game commands to add players instead.\n")
            return
        
        while True:
            username = input("Enter player username: ").strip()
            if not username:
                print("Operation cancelled.\n")
                return
            
            if len(username) > 20:
                print("Username too long (max 20 characters). Please try again.")
                continue
            
            print(f"Fetching UUID for {username}...")
            uuid, actual_name = get_mojang_uuid(username)
            
            if not uuid:
                print(f"Error: Could not fetch UUID for '{username}'.")
                print("Please check the username and try again.")
                continue
            
            print(f"Found: {actual_name} -> {uuid}")
            break
        
        if list_type == "banned-players":
            reason = input("Enter ban reason (optional): ").strip() or "Banned by an operator."
            
            new_entry = {
                "uuid": uuid,
                "name": actual_name,
                "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
                "source": "Server",
                "expires": "forever",
                "reason": reason
            }
        else:
            new_entry = {
                "uuid": uuid,
                "name": actual_name
            }
        
        items.append(new_entry)
    
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        print(f"\nSuccessfully added to {list_type}!\n")
    except Exception as e:
        print(f"Error saving {list_type}: {e}\n")

def delete_from_list(items, list_type, file_path):
    if not items:
        print(f"\n{list_type} is empty. Nothing to delete.\n")
        return
    
    print(f"\nDeleting from {list_type}...")
    
    try:
        selection = input("Enter the number(s) to delete (space-separated): ").strip()
        if not selection:
            print("Operation cancelled.\n")
            return
        
        indices = [int(i.strip()) for i in selection.split()]
        indices.sort(reverse=True)
        
        valid_indices = [i for i in indices if 1 <= i <= len(items)]
        
        if not valid_indices:
            print("No valid numbers selected.\n")
            return
        
        print("\nThe following entries will be deleted:")
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                print(f" - IP: {item.get('ip', 'Unknown')}")
            else:
                print(f" - {item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})")
        
        confirm = input("\nAre you sure? (Y/N): ").strip().upper()
        if confirm != 'Y':
            print("Deletion cancelled.\n")
            return
        
        for idx in valid_indices:
            del items[idx-1]
        
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        
        print(f"\nSuccessfully deleted {len(valid_indices)} entries from {list_type}!\n")
        
    except ValueError:
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
        print(f"Error deleting from {list_type}: {e}\n")

def create_lock(command):
    try:
        with open(LOCK_FILE, 'w', encoding='utf-8') as f:
            f.write(f"Command: {' '.join(command)}\n")
            f.write(f"Timestamp: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"PID: {os.getpid()}\n")
        return True
    except Exception as e:
        print(f"\nError creating lock file: {e}\n")
        return False

def remove_lock():
    try:
        if LOCK_FILE.exists():
            LOCK_FILE.unlink()
        return True
    except Exception as e:
        print(f"\nError removing lock file: {e}\n")
        return False

def check_lock():
    if not LOCK_FILE.exists():
        return None
    
    try:
        with open(LOCK_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
        
        command_match = re.search(r'Command:\s*(.+)', content)
        pid_match = re.search(r'PID:\s*(\d+)', content)
        timestamp_match = re.search(r'Timestamp:\s*(.+)', content)
        
        if not command_match:
            return None
        
        command_line = command_match.group(1).strip()
        pid = int(pid_match.group(1)) if pid_match else None
        
        lock_time = None
        if timestamp_match:
            try:
                time_str = timestamp_match.group(1).strip()
                lock_time = datetime.datetime.strptime(time_str, '%Y-%m-%d %H:%M:%S')
            except ValueError:
                try:
                    lock_time = datetime.datetime.fromtimestamp(os.path.getctime(LOCK_FILE))
                except:
                    lock_time = None
        
        if lock_time is None:
            try:
                lock_time = datetime.datetime.fromtimestamp(os.path.getctime(LOCK_FILE))
            except:
                lock_time = datetime.datetime.now()
        
        is_running = pid and is_process_running(pid)
        
        return {
            'command': command_line.split(),
            'pid': pid,
            'is_running': is_running,
            'timestamp': lock_time
        }
        
    except Exception as e:
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
    lock_info = check_lock()
    if not lock_info:
        return False
    
    print("\n" + "=" * 51)
    
    lock_time = lock_info['timestamp']
    time_duration = format_time_duration(lock_time)
    time_str = lock_time.strftime("%Y-%m-%d %H:%M:%S")
    
    if lock_info['is_running']:
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
                print("\nExiting script...\n")
                sys.exit(0)
            elif choice == 'F':
                confirm = input("\nAre you sure? This may cause DATA CORRUPTION! (Y/N): ").strip().upper()
                if confirm == 'Y':
                    print("\nForce clearing lock and continuing...\n")
                    remove_lock()
                    return False
                else:
                    continue
            else:
                print("Please enter Q or F.")
    else:
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
                print("\nResuming pending task...\n")
                return lock_info['command']
            elif choice == 'N':
                print("\nClearing pending task...\n")
                remove_lock()
                return False
            elif choice == 'Q':
                print("\nExiting script without any changes...\n")
                sys.exit(0)
            else:
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
        print("By using this server, you agree to Mojang's EULA (https://aka.ms/MinecraftEULA)")
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
            print("By using this server, you agree to Mojang's EULA (https://aka.ms/MinecraftEULA)")
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
        print("\nError: Could not create task lock\n")
        return
    
    try:
        print("\n" + "=" * 52)
        print("                World Management Utility")
        print("=" * 52)

        WORLDS_DIR.mkdir(parents=True, exist_ok=True)

        world_folders = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]

        if not world_folders:
            print("\nNo world folders found.")
            print("\nAvailable operations:")
            print(" 1. Import worlds")
            print(" 2. Configure world seed")
            
            while True:
                try:
                    choice = input("\nYour choice (1/2): ").strip()
                    if choice == "1":
                        import_world()
                        break
                    elif choice == "2":
                        configure_world_seed()
                        break
                    else:
                        print("Invalid option. Please choose 1 or 2.\n")
                except KeyboardInterrupt:
                    print("\nOperation canceled.\n")
                    break
            return

        print("\n                - Existing Worlds -")

        world_info = []
        total_size = 0
        for world_folder in world_folders:
            try:
                world_size = sum(f.stat().st_size for f in world_folder.rglob('*') if f.is_file())
                status = "OK" if (world_folder / "level.dat").exists() else "CORRUPTED"
                world_info.append((world_folder, world_size, status))
                total_size += world_size
            except Exception as e:
                world_info.append((world_folder, 0, "ERROR"))
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

        print("\nAvailable operations:")
        print(" 1. Delete worlds")
        print(" 2. Backup worlds")
        print(" 3. Import worlds")
        print(" 4. Configure world seed")
        
        try:
            operation_choice = input("\nSelect operation (1-4): ").strip()
            if not operation_choice:
                print("No operation selected. Operation canceled.\n")
                return

            if operation_choice == "1":
                delete_worlds(world_info)
            elif operation_choice == "2":
                backup_worlds(world_info)
            elif operation_choice == "3":
                import_world()
            elif operation_choice == "4":
                configure_world_seed()
            else:
                print("Invalid operation selection.\n")
                return

        except KeyboardInterrupt:
            print("\nOperation canceled by user.\n")
        except Exception as e:
            print(f"Error during world operation: {e}\n")
    
    finally:
        remove_lock()

def backup_worlds(world_info):
    try:
        config = load_config()
        current_version = config.get("version", "unknown")
    except:
        print("Error: Could not determine current server version for backup.\n")
        return

    selection = input("\nSelect world folders to backup (space-separated numbers, 0 for all): ").strip()
    if not selection:
        print("No selection made. Operation canceled.\n")
        return

    selected_indices = []
    for num_str in selection.split():
        try:
            num = int(num_str)
            if 0 <= num <= len(world_info):
                selected_indices.append(num)
            else:
                print(f"Invalid number: {num}")
                return
        except ValueError:
            print(f"Invalid input: {num_str}")
            return

    if 0 in selected_indices:
        worlds_to_backup = [world_info[i][0] for i in range(len(world_info))]
        print("\nYou have selected ALL worlds to backup:")
    else:
        worlds_to_backup = [world_info[i - 1][0] for i in selected_indices]
        print("\nYou have selected the following world(s) to backup:")

    for w in worlds_to_backup:
        print(f" - {w.name}")

    confirm = input("\nProceed with backup? (Y/N): ").strip().upper()
    if confirm != "Y":
        print("Operation canceled.\n")
        return

    backup_dir = BUNDLES_DIR / current_version / "worlds"
    backup_dir.mkdir(parents=True, exist_ok=True)
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"worlds_{timestamp}.zip"
    backup_path = backup_dir / backup_filename

    print(f"\nCreating backup: {backup_path}")

    try:
        with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for world_folder in worlds_to_backup:
                if not world_folder.exists():
                    print(f"Warning: World folder {world_folder.name} does not exist, skipping.")
                    continue
                
                print(f"Adding: {world_folder.name}")
                for root, _, files in os.walk(world_folder):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.join(world_folder.name, os.path.relpath(file_path, world_folder))
                        zipf.write(file_path, arcname)

        file_size = os.path.getsize(backup_path)
        print(f"\nBackup created successfully: {backup_path}")
        print(f"File size: {format_file_size(file_size)}")
        print(f"Worlds backed up: {len(worlds_to_backup)}")
        print("")

    except Exception as e:
        print(f"Error creating backup: {e}\n")
        if backup_path.exists():
            backup_path.unlink()

def delete_worlds(world_info):
    try:
        selection = input("\nSelect world folders to delete (space-separated numbers, 0 for all): ").strip()
        if not selection:
            print("No selection made. Operation canceled.\n")
            return

        selected_indices = []
        for num_str in selection.split():
            try:
                num = int(num_str)
                if 0 <= num <= len(world_info):
                    selected_indices.append(num)
                else:
                    print(f"Invalid number: {num}")
                    return
            except ValueError:
                print(f"Invalid input: {num_str}")
                return

        if 0 in selected_indices:
            confirm = input("\nAre you sure you want to delete ALL world folders?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                print("Operation canceled.\n")
                return

            for world_folder, _, _ in world_info:
                try:
                    shutil.rmtree(world_folder)
                    print(f"Deleted: {world_folder.name}")
                except Exception as e:
                    print(f"Error deleting {world_folder.name}: {e}")

            print("\nAll world folders deleted successfully.\n")

        else:
            worlds_to_delete = [world_info[i - 1][0] for i in selected_indices]
            print("\nYou have selected the following world(s) to delete:")
            for w in worlds_to_delete:
                print(f" - {w.name}")

            confirm = input("\nAre you sure you want to delete these world(s)?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                print("Operation canceled.\n")
                return

            for w in worlds_to_delete:
                try:
                    shutil.rmtree(w)
                    print(f"Deleted: {w.name}")
                except Exception as e:
                    print(f"Error deleting {w.name}: {e}")

            print("\nSelected world(s) deleted successfully.\n")

        remaining = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        if not remaining:
            choice = input("All world folders have been removed.\nDo you want to configure a new world seed now? (Y/N): ").strip().upper()
            if choice == "Y":
                configure_world_seed()
            else:
                print("Skipped seed configuration.\n")
        else:
            print("Some world folders remain. Skipping seed configuration.\n")

    except KeyboardInterrupt:
        print("\nOperation canceled by user.\n")

def backup_worlds(world_info):
    try:
        config = load_config()
        current_version = config.get("version", "unknown")
    except:
        print("Error: Could not determine current server version for backup.\n")
        return

    selection = input("\nSelect world folders to backup (space-separated numbers, 0 for all): ").strip()
    if not selection:
        print("No selection made. Operation canceled.\n")
        return

    selected_indices = []
    for num_str in selection.split():
        try:
            num = int(num_str)
            if 0 <= num <= len(world_info):
                selected_indices.append(num)
            else:
                print(f"Invalid number: {num}")
                return
        except ValueError:
            print(f"Invalid input: {num_str}")
            return

    if 0 in selected_indices:
        worlds_to_backup = [world_info[i][0] for i in range(len(world_info))]
        print("\nYou have selected ALL worlds to backup:")
    else:
        worlds_to_backup = [world_info[i - 1][0] for i in selected_indices]
        print("\nYou have selected the following world(s) to backup:")

    for w in worlds_to_backup:
        print(f" - {w.name}")

    confirm = input("\nProceed with backup? (Y/N): ").strip().upper()
    if confirm != "Y":
        print("Operation canceled.\n")
        return

    backup_dir = BUNDLES_DIR / current_version
    backup_dir.mkdir(parents=True, exist_ok=True)
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"worlds_{timestamp}.zip"
    backup_path = backup_dir / backup_filename

    print(f"\nCreating backup: {backup_path}")

    try:
        with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for world_folder in worlds_to_backup:
                if not world_folder.exists():
                    print(f"Warning: World folder {world_folder.name} does not exist, skipping.")
                    continue
                
                print(f"Adding: {world_folder.name}")
                for root, _, files in os.walk(world_folder):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.join(world_folder.name, os.path.relpath(file_path, world_folder))
                        zipf.write(file_path, arcname)

        file_size = os.path.getsize(backup_path)
        print(f"\nBackup created successfully: {backup_path}")
        print(f"File size: {format_file_size(file_size)}")
        print(f"Worlds backed up: {len(worlds_to_backup)}")
        print("")

    except Exception as e:
        print(f"Error creating backup: {e}\n")
        if backup_path.exists():
            backup_path.unlink()

def import_world():
    print("\n" + "=" * 50)
    print("               World Import Utility")
    print("=" * 50)
    
    while True:
        zip_path_input = input("\nEnter the path to the world backup ZIP file: ").strip()
        if not zip_path_input:
            print("Operation canceled.\n")
            return
        
        zip_path = Path(zip_path_input)
        
        if not zip_path.exists():
            print(f"Error: File not found: {zip_path}")
            continue
        
        if zip_path.suffix.lower() != '.zip':
            print("Error: File must be a ZIP archive.")
            continue
        
        break

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
            
            if not world_candidates:
                print("Error: No valid worlds found in the archive.")
                print("A valid world must contain a level.dat file.")
                print("")
                return
            
            print(f"Found {len(world_candidates)} world(s) in archive:")
            for i, world_name in enumerate(world_candidates, 1):
                print(f" {i}. {world_name}")
            
            existing_worlds = [d.name for d in WORLDS_DIR.iterdir() if d.is_dir()]
            conflicting_worlds = [w for w in world_candidates if w in existing_worlds]
            
            if conflicting_worlds:
                print(f"\nWarning: The following worlds already exist:")
                for world in conflicting_worlds:
                    print(f" - {world}")
                
                replace_choice = input("\nReplace existing worlds? (Y/N): ").strip().upper()
                if replace_choice != "Y":
                    print("Import canceled.\n")
                    return
                
                for world_name in conflicting_worlds:
                    world_path = WORLDS_DIR / world_name
                    try:
                        shutil.rmtree(world_path)
                        print(f"Removed existing world: {world_name}")
                    except Exception as e:
                        print(f"Error removing {world_name}: {e}")
            
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
                    print(f"✓ Imported: {world_name}")
                    extracted_count += 1
                else:
                    print(f"✗ Invalid world (missing level.dat): {world_name}")
                    shutil.rmtree(world_path)
            
            print(f"\nSuccessfully imported {extracted_count} world(s).")
            print("")
            
    except zipfile.BadZipFile:
        print("Error: The file is not a valid ZIP archive.\n")
    except Exception as e:
        print(f"Error importing worlds: {e}\n")

def configure_world_seed():
    if not SERVER_PROPERTIES.exists():
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
                break
    
    print("\nTo generate new worlds, there are 3 options for the seed:")
    print("1. Keep the current seed")
    print("2. Use a random seed")
    print("3. Set a custom seed")
    
    while True:
        try:
            option = input("\nYour option (1-3): ").strip()
            if option == "1":
                print("Keeping current seed...")
                break
            elif option == "2":
                print("Using random seed...")
                current_seed = ""
                break
            elif option == "3":
                new_seed = input("Enter your seed: ").strip()
                if new_seed:
                    current_seed = new_seed
                    print(f"Seed set to: {current_seed}")
                    break
                else:
                    print("Seed cannot be empty. Please try again.\n")
            else:
                print("Invalid option. Please choose 1, 2, or 3.\n")
        except KeyboardInterrupt:
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
    
    with open(SERVER_PROPERTIES, 'w') as f:
        f.writelines(new_properties_content)
    
    print("\nSuccessfully configured world seed.")
    print("New worlds will be generated with the specified seed when server starts.")
    print("")

def create_new_server():
    if not create_lock(["--new"]):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        print("\n" + "=" * 50)
        print("               New Server Creation")
        print("=" * 50)
        
        try:
            config = load_config()
            current_version = config.get("version", "unknown")
        except:
            current_version = "unknown"
        
        available_versions = []
        if BUNDLES_DIR.exists():
            for version_dir in BUNDLES_DIR.iterdir():
                if version_dir.is_dir():
                    core_zip = version_dir / "core.zip"
                    if core_zip.exists():
                        available_versions.append(version_dir.name)
        
        if not available_versions:
            print("\nNo server versions found in bundles directory.")
            print("Please download a version first using: --get <version>")
            return
        
        print("\nAvailable Versions:")
        print("=" * 30)
        sorted_versions = sorted(available_versions, key=lambda v: [int(n) for n in v.split('.')], reverse=True)
        for i, version in enumerate(sorted_versions, 1):
            print(f"{i}. {version}")
        print("=" * 30)
        
        try:
            selection = input("\nSelect a version to create (number): ").strip()
            if not selection:
                print("No selection made.")
                return
            index = int(selection) - 1
            if not (0 <= index < len(sorted_versions)):
                print("Invalid selection.")
                return
            selected_version = sorted_versions[index]
            print(f"Selected version: {selected_version}")
        except ValueError:
            print("Invalid input. Please enter a number.")
            return
        
        if check_for_updates(selected_version):
            confirm = input("\nUpdate to latest build before creating? (Y/N): ").strip().upper()
            if confirm == "Y":
                download_version(selected_version)
        
        show_version_info(selected_version)
        
        core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
        if not core_zip_path.exists():
            print(f"Error: core.zip missing for {selected_version}")
            return
        
        print("\nCreating new server...")
        exclude_list = get_exclude_list()
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                continue
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
            else:
                try:
                    item.unlink()
                except:
                    pass
        
        try:
            with zipfile.ZipFile(core_zip_path, 'r') as zipf:
                zipf.extractall(BASE_DIR)
            print(f"Extracted core for version {selected_version}")
        except Exception as e:
            print(f"Error extracting core: {e}\n")
            return
        
        print("\nInitialization options:")
        print("1. Enter --init")
        print("2. Enter --init auto")
        print("3. Exit without initialization")
        
        while True:
            choice = input("\nYour choice (1-3): ").strip()
            if choice == "1":
                init_config(prefill_version=selected_version)
                break
            elif choice == "2":
                init_config_auto(prefill_version=selected_version)
                break
            elif choice == "3":
                print("Server created but not initialized.")
                break
            else:
                print("Invalid input. Choose 1, 2, or 3.")
    
    finally:
        remove_lock()

def check_for_updates(version):
    print(f"\nChecking for updates for version {version}...")
    
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    
    if not core_zip_path.exists():
        print("No local version found to check for updates.")
        return False
    
    local_build = None
    try:
        with zipfile.ZipFile(core_zip_path, 'r') as zipf:
            if 'info.txt' in zipf.namelist():
                with zipf.open('info.txt') as info_file:
                    info_content = info_file.read().decode('utf-8')
                    build_match = re.search(r'Build\s+(\d+)', info_content)
                    if build_match:
                        local_build = int(build_match.group(1))
    except Exception as e:
        print(f"Error reading local version info: {e}")
        return False
    
    if local_build is None:
        print("Could not determine local build number.")
        return False
    
    try:
        with urllib.request.urlopen(f"https://api.purpurmc.org/v2/purpur/{version}", timeout=10) as response:
            version_data = json.loads(response.read().decode())
        
        builds = version_data.get("builds", {})
        all_builds = builds.get("all", [])
        
        if not all_builds:
            print("No builds found for this version.")
            return False
            
        latest_build = None
        for build in sorted(all_builds, key=int, reverse=True):
            try:
                with urllib.request.urlopen(f"https://api.purpurmc.org/v2/purpur/{version}/{build}", timeout=5) as build_response:
                    build_data = json.loads(build_response.read().decode())
                
                if build_data.get("result") == "SUCCESS":
                    latest_build = int(build)
                    break
            except:
                continue
        
        if latest_build is None:
            print("No successful builds found for this version.")
            return False
        
        print(f"Local build: {local_build}, Latest build: {latest_build}")
        
        if latest_build > local_build:
            print("Update available!")
            return True
        else:
            print("No updates found.")
            return False
            
    except Exception as e:
        print(f"Could not check for updates: {e}")
        print("Continuing with local version...")
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
    command = ["--get"]
    if version:
        command.append(version)
    if not create_lock(command):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        if version is None:
            try:
                with urllib.request.urlopen("https://api.purpurmc.org/v2/purpur", timeout=10) as response:
                    data = json.loads(response.read().decode())
                    versions = data.get("versions", [])
                    
                    version_groups = {}
                    for v in versions:
                        major_version = ".".join(v.split(".")[:2])
                        if major_version not in version_groups:
                            version_groups[major_version] = []
                        version_groups[major_version].append(v)
                    
                    print("\nAvailable Versions:")
                    print("=" * 50)
                    
                    for major, minors in sorted(version_groups.items(), key=lambda x: tuple(map(int, x[0].split('.'))), reverse=True):
                        sorted_minors = sorted(minors, key=lambda v: tuple(map(int, v.split('.'))), reverse=True)
                        print(f"[{major}]: {', '.join(sorted_minors)}")
                    
                    print("=" * 50)
                    print("")
                    
            except Exception as e:
                print(f"Error fetching available versions: {e}\n")
                return
        else:
            if not re.match(r"^\d+\.\d+(\.\d+)?$", version):
                print(f"Invalid version format: {version}")
                print("Use format like 1.21.5 or 1.21")
                return
                
            target_dir = BUNDLES_DIR / version
            zip_path = target_dir / "core.zip"
            
            print(f"\nFetching version information for {version}...")
            
            try:
                with urllib.request.urlopen(f"https://api.purpurmc.org/v2/purpur/{version}", timeout=10) as response:
                    version_data = json.loads(response.read().decode())
                    
                builds = version_data.get("builds", {})
                latest_build = builds.get("latest")
                all_builds = builds.get("all", [])
                
                if not all_builds:
                    print(f"No builds found for version {version}\n")
                    return
                    
                all_builds.sort(key=int, reverse=True)
                
                successful_build = None
                build_data = None
                for build in all_builds:
                    print(f"Checking build {build}...")
                    
                    try:
                        with urllib.request.urlopen(f"https://api.purpurmc.org/v2/purpur/{version}/{build}", timeout=10) as build_response:
                            build_data = json.loads(build_response.read().decode())
                        
                        if build_data.get("result") == "SUCCESS":
                            successful_build = build
                            print(f"Found successful build: {build}")
                            
                            print("\nBuild Information:")
                            print("=" * 50)
                            
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
                                    
                                    print(f"Author: {author}")
                                    print(f"Date: {build_date}")
                                    md5_hash = build_data.get("md5", "Not available")
                                    print(f"MD5: {md5_hash}")
                                    print("")
                                    print("Description:")
                                    print(f"{description}")
                                    print("=" * 50)
                                    print("")
                            else:
                                print("No commit information available.")
                                md5_hash = build_data.get("md5", "Not available")
                                print(f"MD5: {md5_hash}")
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
                    except Exception as e:
                        print(f"Error checking build {build}: {e}\n")
                        continue
                
                if not successful_build:
                    print(f"No successful builds found for version {version}\n")
                    return
                    
                confirm = input("Do you want to download this version? (Y/N): ").strip().upper()
                if confirm != "Y":
                    print("Download canceled.\n")
                    return
                    
                if zip_path.exists():
                    confirm = input(f"Version {version} already exists. Overwrite? (Y/N): ").strip().upper()
                    if confirm != "Y":
                        print("Download canceled.\n")
                        return
                    
                download_url = f"https://api.purpurmc.org/v2/purpur/{version}/{successful_build}/download"
                print(f"\nDownloading from {download_url}...")
                print("This may take a while depending on your network speed.")
                print("Press CTRL+C to cancel the download.\n")
                
                target_dir.mkdir(parents=True, exist_ok=True)
                
                temp_jar = target_dir / "temp_core.jar"
                
                try:
                    with urllib.request.urlopen(download_url) as download_response:
                        with open(temp_jar, 'wb') as f:
                            while True:
                                chunk = download_response.read(8192)
                                if not chunk:
                                    break
                                f.write(chunk)
                    
                    expected_md5 = build_data.get("md5")
                    if expected_md5:
                        print("Verifying file integrity...")
                        with open(temp_jar, 'rb') as f:
                            file_hash = hashlib.md5()
                            while chunk := f.read(8192):
                                file_hash.update(chunk)
                            actual_md5 = file_hash.hexdigest()
                        
                        if actual_md5 != expected_md5:
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
                        print("MD5 verified successfully!\n")
                    
                    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                        zipf.write(temp_jar, "core.jar")
                        
                        info_file = target_dir / "info.txt"
                        with open(info_file, 'w', encoding='utf-8') as f:
                            f.write(info_content)
                        zipf.write(info_file, "info.txt")
                        info_file.unlink()
                    
                    temp_jar.unlink()
                    
                    print(f"Successfully downloaded {version} (build {successful_build}) to {zip_path}\n")
                    
                except KeyboardInterrupt:
                    print("\nDownload canceled by user.\n")
                    if temp_jar.exists():
                        temp_jar.unlink()
                    if zip_path.exists():
                        zip_path.unlink()
                    return
                    
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    print(f"Version {version} not found on PurpurMC\n")
                else:
                    print(f"HTTP Error: {e.code} - {e.reason}\n")
            except Exception as e:
                print(f"Error downloading version {version}: {e}\n")
    finally:
        remove_lock()

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

def manage_plugins():
    if not PLUGINS_DIR.exists():
        print("\nPlugins directory not found!")
        print("")
        return
    
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    
    if not plugin_files:
        print("\nNo plugins found!")
        print("")
        return
    
    plugins = []
    for plugin_path in plugin_files:
        name, version = get_plugin_info(plugin_path)
        enabled = not plugin_path.name.endswith('.disabled')
        plugins.append({
            'path': plugin_path,
            'name': name,
            'version': version,
            'enabled': enabled
        })
    
    print("\n" + format_plugins_table(plugins))
    
    choice = input("\nDo you want to toggle these plugins? (Y/N): ").strip().upper()
    
    if choice != 'Y':
        print("")
        return
    
    try:
        selected = input("Enter the numbers of the plugin you want to toggle (e.g., '1 2 3'): ").strip()
        if not selected:
            print("No plugins selected.\n")
            return
        
        indices = [int(i) for i in selected.split()]
        indices = [i for i in indices if 1 <= i <= len(plugins)]
        
        if not indices:
            print("No valid plugin numbers selected.\n")
            return
        
        for idx in indices:
            plugin = plugins[idx-1]
            old_path = plugin['path']
            
            if plugin['enabled']:
                new_path = old_path.parent / (old_path.name + ".disabled")
                old_path.rename(new_path)
                print(f"Disabled: {plugin['name']}")
            else:
                new_name = old_path.name.replace(".disabled", "")
                new_path = old_path.parent / new_name
                old_path.rename(new_path)
                print(f"Enabled: {plugin['name']}")
        
        print("\nPlugin states changed successfully!")
        print("")
        
    except ValueError:
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
        print(f"Error toggling plugins: {e}\n")

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
    if not PLUGINS_DIR.exists():
        print("\nPlugins directory not found!")
        print("")
        return
    
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    
    if not plugin_files:
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
    
    print("\n" + format_plugins_table(plugins))
    
    choice = input("\nDo you want to toggle these plugins? (Y/N): ").strip().upper()
    
    if choice != 'Y':
        print("")
        return
    
    try:
        selected = input("Enter the numbers of the plugin you want to toggle (e.g., '1 2 3'): ").strip()
        if not selected:
            print("No plugins selected.\n")
            return
        
        indices = [int(i) for i in selected.split()]
        indices = [i for i in indices if 1 <= i <= len(plugins)]
        
        if not indices:
            print("No valid plugin numbers selected.\n")
            return
        
        plugins_to_disable = []
        plugins_to_enable = []
        
        for idx in indices:
            plugin = plugins[idx-1]
            if plugin['enabled']:
                plugins_to_disable.append(plugin)
            else:
                plugins_to_enable.append(plugin)
        
        for plugin in plugins_to_enable:
            old_path = plugin['path']
            new_name = old_path.name.replace(".disabled", "")
            new_path = old_path.parent / new_name
            old_path.rename(new_path)
            print(f"Enabled: {plugin['name']}")
        
        for plugin in plugins_to_disable:
            dependencies = check_plugin_dependencies(plugins, plugin)
            hard_dependents = dependencies['hard_dependents']
            soft_dependents = dependencies['soft_dependents']
            
            if hard_dependents or soft_dependents:
                warning_message = format_dependency_warning(plugin, hard_dependents, soft_dependents)
                print(warning_message)
                
                if hard_dependents:
                    print(f"\nYou have multiple options:")
                    print("1. Disable the dependent plugins first, then disable this one")
                    print("2. Force disable this plugin anyway (RISKY)")
                    print("3. Disable the whole plugin chain for me (AUTOMATIC)")
                    
                    while True:
                        choice = input("\nChoose option (1/2/3) or 'C' to cancel: ").strip().upper()
                        if choice == '1':
                            print("Please disable the dependent plugins first:")
                            for dependent in hard_dependents:
                                print(f" - {dependent['name']}")
                            print("Then try disabling this plugin again.\n")
                            continue
                        elif choice == '2':
                            confirm = input("Are you sure?\nThis may break other plugins or crash the server! (Y/N): ").strip().upper()
                            if confirm == 'Y':
                                old_path = plugin['path']
                                new_path = old_path.parent / (old_path.name + ".disabled")
                                old_path.rename(new_path)
                                print(f"Force disabled: {plugin['name']}\n")
                                break
                            else:
                                continue
                        elif choice == '3':
                            disabled_plugins = disable_dependency_chain(plugins, plugin)
                            if disabled_plugins:
                                print(f"\nAutomatically disabled the following plugins:")
                                for disabled_plugin in disabled_plugins:
                                    print(f" - {disabled_plugin['name']}")
                                
                                if soft_dependents:
                                    print(f"\nNote: The following plugins have soft dependencies and were NOT automatically disabled:")
                                    for soft_dep in soft_dependents:
                                        print(f"  - {soft_dep['name']}")
                                    print("These plugins may lose some functionality but should still work.\n")
                            break
                        elif choice == 'C':
                            print(f"Cancelled disabling: {plugin['name']}\n")
                            break
                        else:
                            print("Invalid choice. Please enter 1, 2, 3, or C.\n")
                else:
                    confirm = input(f"\nDo you still want to disable {plugin['name']}? (Y/N): ").strip().upper()
                    if confirm == 'Y':
                        old_path = plugin['path']
                        new_path = old_path.parent / (old_path.name + ".disabled")
                        old_path.rename(new_path)
                        print(f"Disabled: {plugin['name']}")
                    else:
                        print(f"Skipped: {plugin['name']}")
            else:
                old_path = plugin['path']
                new_path = old_path.parent / (old_path.name + ".disabled")
                old_path.rename(new_path)
                print(f"Disabled: {plugin['name']}")
        
        print("\nPlugin states changed successfully!")
        print("")
        
    except ValueError:
        print("Invalid input. Please enter numbers separated by spaces.\n")
    except Exception as e:
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

def init_config(prefill_version=None):
    print("=" * 50)
    print("         Minecraft Server Initialization")
    print("=" * 50)
    
    if CONFIG_FILE.exists():
        print("\nConfiguration file already exists!")
        print("This will replace your current configuration.")
        confirm = input("\nDo you want to continue? (Y/N): ").strip().upper()
        if confirm != "Y":
            print("\nOperation canceled.\nExisting configuration preserved.\n")
            return
    
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    
    config = configparser.ConfigParser()
    
    if prefill_version:
        version = prefill_version
        print(f"\nUsing version: {version}")
    else:
        while True:
            version = input("\nEnter Minecraft server version (e.g., 1.21.5 or 1.21): ").strip()
            if re.match(r"^\d+\.\d+(\.\d+)?$", version):
                break
            print("Invalid version format. Use format like 1.21.5 or 1.21")
    
    while True:
        ram_input = input("\nSet maximum RAM (e.g., 4096 for 4GB, or 4 for 4GB): ").strip()
        if ram_input.isdigit():
            ram_value = int(ram_input)
            if ram_value < 256:
                max_ram = ram_value * 1024
                print(f"Converted {ram_value} GB to {max_ram} MB")
            else:
                max_ram = ram_value
            
            if max_ram < 512:
                print("Warning: Allocating less than 512MB may cause server instability!")
                confirm = input("Continue anyway? (Y/N): ").strip().upper()
                if confirm == "Y":
                    break
            else:
                break
        else:
            print("Invalid RAM size. Must be a positive integer")
    
    print(f"\nAllocated RAM: {max_ram} MB ({max_ram/1024:.1f} GB)")
    
    print("\nYou can add additional files/directories to exclude from backups.")
    print("These will be added to the base exclusion list.")
    additional_exclude = input("Enter additional exclusions (comma-separated, leave empty if none): ").strip()
    
    
    java_path = None
    while java_path is None:
        java_installations = find_java_installations()
        
        if not java_installations:
            print("Error: No Java installations found! Please install Java first.\n")
            sys.exit(1)
        
        print("\n" + format_java_table(java_installations))
        
        while True:
            try:
                choice = input(f"\nSelect Java installation (0-{len(java_installations)}): ").strip()
                if choice == "0":
                    
                    custom_path = input("\nEnter Java path (can be Java home or bin directory): ").strip()
                    if not custom_path:
                        print("No path entered. Please try again.")
                        continue
                    
                    print("Validating Java...")
                    validated_path = validate_java_path(custom_path)
                    if validated_path:
                        java_path = validated_path
                        print("Validated successfully.")
                        break
                    else:
                        print("Invalid Java path or Java not found. Please check the path and try again.")
                        print("Make sure the path points to a valid Java installation.")
                        continue
                else:
                    choice_num = int(choice)
                    if 1 <= choice_num <= len(java_installations):
                        java_path = java_installations[choice_num-1]['path']
                        break
                    print("Invalid selection.")
            except ValueError:
                print("Please enter a number.")
    
    
    print("\nYou can add additional server parameters (e.g., -nogui, --force-upgrade, etc.)")
    print("These will be appended after the default parameters.")
    additional_params = input("Enter additional parameters (leave empty if none): ").strip()
    
    device_id = get_device_id()
    
    config["SERVER"] = {
        "version": version,
        "max_ram": str(max_ram),
        "java_path": java_path,
        "device": device_id
    }
    
    if additional_exclude:
        config["SERVER"]["additional_list"] = additional_exclude
    
    if additional_params:
        config["SERVER"]["additional_parameters"] = additional_params
    
    with open(CONFIG_FILE, "w") as f:
        config.write(f)
    
    print(f"\nConfiguration saved to {CONFIG_FILE}")
    show_info()

def init_config_auto(prefill_version=None):
    print("=" * 50)
    print("         Automatic Server Initialization")
    print("=" * 50)

    if CONFIG_FILE.exists():
        print("\nConfiguration file already exists!")
        print("This will replace your current configuration.")
        confirm = input("\nDo you want to continue? (Y/N): ").strip().upper()
        if confirm != "Y":
            print("\nOperation canceled.\nExisting configuration preserved.\n")
            return

    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser()
    
    version = prefill_version
    if not version and SERVER_JAR.exists():
        try:
            with zipfile.ZipFile(SERVER_JAR, 'r') as jar:
                with jar.open('version.json') as f:
                    data = json.load(f)
                    version = data.get("id", "unknown")
                    java_required = int(data.get("java_version", 8))
        except Exception:
            version = "unknown"
            java_required = 8
    else:
        java_required = 8
    
    print(f"\nDetected version: {version}")
    print(f"Required Java version: {java_required}")

    java_installations = find_java_installations()
    available_versions = [int(j['version']) for j in java_installations if j['version'].isdigit()]
    
    java_path = None
    if not available_versions:
        print("\nNo Java installations found!")
        custom = input("Would you like to specify a custom Java path? (Y/N): ").strip().upper()
        if custom == "Y":
            while True:
                custom_path = input("Enter custom Java path: ").strip()
                validated = validate_java_path(custom_path)
                if validated:
                    java_path = validated
                    break
                else:
                    print("Invalid path. Try again.")
        else:
            print("Exiting auto initialization.")
            return
    else:
        found = False
        test_ver = java_required
        while not found:
            for j in java_installations:
                if j["version"].isdigit() and int(j["version"]) == test_ver:
                    java_path = j["path"]
                    found = True
                    break
            if not found:
                test_ver += 1
                if test_ver > 25:
                    break
        if not java_path:
            print(f"No suitable Java version found up to Java {test_ver}.")
            print("Exiting auto initialization.")
            return

    print("\nDetecting available memory...")
    total_mem_bytes = get_total_memory()
    total_mem_gb = total_mem_bytes / (1024 ** 3)
    total_mem_mb = total_mem_gb * 1024
    
    is_container = is_running_in_container()
    if is_container:
        print(" - Running in container environment")
    
    print(f"Total available memory: {total_mem_mb:.0f} MB ({total_mem_gb:.1f} GB)")

    if total_mem_mb < 512:
        print("\nERROR: Available memory is less than 512MB.")
        print("The server will likely crash due to insufficient memory.")
        print("Please use manual initialization (--init) to allocate memory carefully.")
        return
    
    if total_mem_mb <= 8192:
        base_ram_mb = (29 * total_mem_mb + 8192) / 60
        base_ram_mb = round(base_ram_mb)
    else:
        base_ram_mb = 4096
    
    print(f"Base allocation: {base_ram_mb} MB")

    plugins_ram_mb = 0
    plugins_dir = BASE_DIR / "plugins"
    if plugins_dir.exists():
        enabled_plugins = list(plugins_dir.glob("*.jar"))
        disabled_plugins = list(plugins_dir.glob("*.jar.disabled"))
        total_plugins = len(enabled_plugins) + len(disabled_plugins)
        enabled_count = len(enabled_plugins)
        
        print(f"\nAnalyzing {enabled_count} enabled plugins:")
        
        plugins_ram_mb = calculate_plugins_memory(enabled_plugins)
        
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
        except Exception:
            pass
    
    players_ram_mb, player_details = calculate_players_memory(max_players, view_distance)
    
    print(f"\nPlayer allocation details:")
    print(f" - Estimated players: {player_details['estimated_players']}")
    print(f" - View distance: {player_details['view_distance']}")
    print(f" - Multiplier: {player_details['memory_multiplier']}")
    print(f" - Total allocation: {players_ram_mb:.1f} MB")

    total_allocated_mb = base_ram_mb + plugins_ram_mb + players_ram_mb
    
    print(f"\nMemory allocation breakdown:")
    print(f" - Base: {base_ram_mb} MB")
    print(f" - Plugins: {plugins_ram_mb} MB")
    print(f" - Players: {players_ram_mb:.1f} MB")
    print(f" - Total: {total_allocated_mb:.1f} MB")

    total_allocated_mb = validate_memory_allocation(total_mem_mb, total_allocated_mb, is_container)

    final_ram_mb = int(total_allocated_mb)

    final_ram_mb = int(total_allocated_mb)
    print(f"\nFinal allocated RAM: {final_ram_mb} MB ({final_ram_mb/1024:.1f} GB)")

    device_id = get_device_id()
    
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
    
    print(f"\nAuto configuration saved to {CONFIG_FILE}")
    show_info()
    print("Auto initialization complete.\n")

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

def load_config():
    if not CONFIG_FILE.exists():
        print(f"\nError: Configuration file not found at {CONFIG_FILE}")
        print("Please run with --init to create a new configuration\n")
        sys.exit(1)
    
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    
    if "SERVER" not in config:
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
        print("Usage: --save <version>")
        return
    
    if not create_lock(["--save", version]):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        config = load_config()
        current_version = config.get("version", "unknown")
    except:
        current_version = "unknown"
        print("Warning: Could not load config, using default version 'unknown'")
    
    target_dir = BUNDLES_DIR / version
    target_dir.mkdir(parents=True, exist_ok=True)
    zip_path = target_dir / "server.zip"
    
    print(f"\nSaving current version ({current_version}) as {version}...")
    
    temp_dir = BASE_DIR / "temp_save"
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
    temp_dir.mkdir(exist_ok=True)
    
    exclude_list = get_exclude_list()
    
    try:
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                continue
            dest = temp_dir / item.name
            
            if item.is_dir():
                if hasattr(shutil, 'copytree') and hasattr(shutil.copytree, '__code__'):
                    import inspect
                    sig = inspect.signature(shutil.copytree)
                    if 'dirs_exist_ok' in sig.parameters:
                        shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
                    else:
                        if dest.exists():
                            shutil.rmtree(dest)
                        shutil.copytree(item, dest, symlinks=True)
                else:
                    if dest.exists():
                        shutil.rmtree(dest)
                    shutil.copytree(item, dest, symlinks=True)
            else:
                shutil.copy2(item, dest)
        
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, temp_dir)
                    zipf.write(file_path, arcname)
        
        print(f"Version {version} saved successfully to {zip_path}\n")
        
    except Exception as e:
        print(f"Error saving version: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
        remove_lock()

def backup_version():
    if not create_lock(["--backup"]):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        config = load_config()
        version = config.get("version", "unknown")
    except:
        print("Error: Could not load configuration to determine current version\n")
        remove_lock()
        return
    
    target_dir = BUNDLES_DIR / version
    target_dir.mkdir(parents=True, exist_ok=True)
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    zip_name = f"{version}_{timestamp}.zip"
    zip_path = target_dir / zip_name
    
    print(f"\nCreating backup of current version ({version})...")
    
    temp_dir = BASE_DIR / "temp_backup"
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
    temp_dir.mkdir(exist_ok=True)
    
    exclude_list = get_exclude_list()
    
    try:
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                continue
            dest = temp_dir / item.name
            
            if item.is_dir():
                if hasattr(shutil, 'copytree') and hasattr(shutil.copytree, '__code__'):
                    import inspect
                    sig = inspect.signature(shutil.copytree)
                    if 'dirs_exist_ok' in sig.parameters:
                        shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
                    else:
                        if dest.exists():
                            shutil.rmtree(dest)
                        shutil.copytree(item, dest, symlinks=True)
                else:
                    if dest.exists():
                        shutil.rmtree(dest)
                    shutil.copytree(item, dest, symlinks=True)
            else:
                shutil.copy2(item, dest)
        
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, temp_dir)
                    zipf.write(file_path, arcname)
        
        print(f"Backup created successfully: {zip_path}\n")
        
    except Exception as e:
        print(f"Error creating backup: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
        remove_lock()

def delete_version(version):
    if not version:
        print("Usage: --delete <version>")
        return
    
    if not create_lock(["--delete", version]):
        print("\nError: Could not create task lock\n")
        return
    
    target_dir = BUNDLES_DIR / version
    
    if not target_dir.exists():
        print("")
        print(f"Version {version} does not exist")
        print("")
        remove_lock()
        return
    
    confirm = input(f"\nAre you sure you want to delete version '{version}'? (Y/N): ")
    if confirm != "Y":
        print("Deletion canceled\n")
        remove_lock()
        return
    
    try:
        shutil.rmtree(target_dir)
        print(f"Version {version} deleted successfully\n")
    except Exception as e:
        print(f"Error deleting version: {e}\n")
    finally:
        remove_lock()

def change_version(target_version):
    if not target_version:
        print("Usage: --change <version>")
        return
    
    if not create_lock(["--change", target_version]):
        print("\nError: Could not create task lock\n")
        return
    
    if not CONFIG_FILE.exists():
        print("\nConfiguration file not found! Run with --init first.\n")
        remove_lock()
        return
    
    try:
        config = configparser.ConfigParser()
        config.read(CONFIG_FILE)
        
        if "SERVER" not in config:
            print("\nWarning: Configuration file missing [SERVER] section. Creating default...\n")
            config["SERVER"] = {}
        
        current_version = config["SERVER"].get("version", "unknown")
        
        save_version(current_version)
        
        zip_path = BUNDLES_DIR / target_version / "server.zip"
        
        if not zip_path.exists():
            print(f"Version {target_version} not found")
            print("")
            remove_lock()
            return
        
        print(f"Switching to version {target_version}...")
        
        exclude_list = get_exclude_list()
        
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                continue
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()
        
        with zipfile.ZipFile(zip_path, "r") as zipf:
            zipf.extractall(BASE_DIR)
        
        if not CONFIG_FILE.exists():
            print("\nWarning: No config file found in target version. Creating default...\n")
            CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
            config["SERVER"] = {"version": target_version}
        else:
            config = configparser.ConfigParser()
            config.read(CONFIG_FILE)
            
            if "SERVER" not in config:
                config["SERVER"] = {}
            
            config["SERVER"]["version"] = target_version
        
        with open(CONFIG_FILE, "w") as f:
            config.write(f)
        
        print(f"Successfully switched to version {target_version}")
        show_info()
        
    except Exception as e:
        print(f"Error switching version: {e}\n")
        import traceback
        traceback.print_exc()
    finally:
        remove_lock()

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
    if not create_lock(command):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        logs_dir = BASE_DIR / "logs"
        
        if not logs_dir.exists() or not any(logs_dir.iterdir()):
            print("")
            print("No log files found to dump.")
            print("")
            return
        
        search_terms = sys.argv[2:] if len(sys.argv) > 2 else []
        
        if search_terms:
            print("\n" + "=" * 45)
            print("          Log Search Utility")
            print("=" * 45)
            print(f"Searching for: {', '.join(search_terms)} (case-insensitive)")
            
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = BASE_DIR / f"logs_search_{timestamp}.zip"
            
            temp_dir = BASE_DIR / f"temp_search_{timestamp}"
            temp_dir.mkdir(parents=True, exist_ok=True)
            
            try:
                files_scanned = 0
                files_matched = 0
                total_matched_lines = 0
                
                for log_file in logs_dir.rglob("*"):
                    if not log_file.is_file():
                        continue
                    
                    files_scanned += 1
                    file_matched_lines = 0
                    file_content = []
                    
                    try:
                        if log_file.suffix == '.gz':
                            with gzip.open(log_file, 'rt', encoding='utf-8', errors='ignore') as f:
                                for line_num, line in enumerate(f, 1):
                                    line_lower = line.lower()
                                    if any(term.lower() in line_lower for term in search_terms):
                                        file_matched_lines += 1
                                        file_content.append(f"Line {line_num}: {line.rstrip()}")
                        else:
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
                            
                            print(f"Found {file_matched_lines} matches in: {rel_path}")
                            
                    except Exception as e:
                        print(f"Error processing {log_file}: {e}")
                        continue
                
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
                
                if files_matched > 0:
                    with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
                        for file_path in temp_dir.rglob("*"):
                            if file_path.is_file():
                                arcname = file_path.relative_to(temp_dir)
                                zipf.write(file_path, arcname)
                    
                    file_size = os.path.getsize(output_file)
                    
                    print("\n" + "=" * 45)
                    print(f"Dumped {files_matched} log files.")
                    print(f"Found {total_matched_lines} matching lines in {files_matched} files.")
                    print(f"\nResult saved to: {output_file.name}")
                    print(f"File size: {file_size} bytes (~{file_size // (1024*1024)} MB)")
                    print("=" * 45)
                    
                    confirm = input("\nDo you want to delete the original log files? (Y/N): ").strip().upper()
                    if confirm == "Y":
                        deleted_count = 0
                        freed_space = 0
                        for log_file in logs_dir.rglob("*"):
                            if log_file.is_file():
                                try:
                                    file_size = log_file.stat().st_size
                                    log_file.unlink()
                                    deleted_count += 1
                                    freed_space += file_size
                                except Exception as e:
                                    print(f"Error deleting {log_file}: {e}")
                        
                        print(f"Deleted {deleted_count} log files, freed {freed_space} bytes.")
                
                else:
                    print("\nNo matching content found in any log files.")
                
                print("")
                
            except Exception as e:
                print(f"Error creating log search: {e}")
                import traceback
                traceback.print_exc()
            finally:
                if temp_dir.exists():
                    shutil.rmtree(temp_dir, ignore_errors=True)
        
        else:
            print("\n" + "=" * 45)
            print("          Log Dump Utility")
            print("=" * 45)
            
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = BASE_DIR / f"logs_dump_{timestamp}.zip"
            
            print(f"\nCreating complete log dump...")
            
            try:
                temp_dir = BASE_DIR / f"temp_logs_{timestamp}"
                temp_dir.mkdir(parents=True, exist_ok=True)
                
                file_count = 0
                for root, _, files in os.walk(logs_dir):
                    for file in files:
                        src_path = os.path.join(root, file)
                        rel_path = os.path.relpath(src_path, BASE_DIR)
                        dest_path = temp_dir / rel_path
                        dest_path.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src_path, dest_path)
                        file_count += 1
                
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
                
                with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
                    for root, _, files in os.walk(temp_dir):
                        for file in files:
                            file_path = os.path.join(root, file)
                            arcname = os.path.relpath(file_path, temp_dir)
                            zipf.write(file_path, arcname)
                
                shutil.rmtree(temp_dir, ignore_errors=True)
                
                file_size = os.path.getsize(output_file)
                print("\n" + "=" * 45)
                print(f"Dumped {file_count} log files.")
                print(f"Result saved to: {output_file.name}")
                print(f"File size: {file_size} bytes (~{file_size // (1024*1024)} MB)")
                print("=" * 45)
                
                confirm = input("\nDo you want to delete the original log files? (Y/N): ").strip().upper()
                if confirm == "Y":
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
                            except Exception as e:
                                print(f"Error deleting {file_path}: {e}")
                    
                    print(f"Deleted {deleted_count} log files, freed {freed_space} bytes.")
                
                print("")
                
            except Exception as e:
                print(f"Error creating log dump: {e}\n")
                import traceback
                traceback.print_exc()
                if temp_dir.exists():
                    shutil.rmtree(temp_dir, ignore_errors=True)
    
    finally:
        remove_lock()

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

def start_server():
    config_check_result = check_config_file()
    if config_check_result == "missing_or_corrupted":
        print("\nError: Configuration file is missing or corrupted!")
        print("Please run with --init to create a new configuration first.\n")
        return
    
    elif config_check_result == "critical_missing":
        print("\nError: Critical configuration parameters are missing!")
        print("Required parameters: version, max_ram, java_path")
        print("Please run with --init to fix the configuration first.\n")
        return
    
    elif config_check_result == "optional_missing":
        print("\nWarning: Some optional configuration parameters are missing.")
        print("The server will start, but some features may not work properly.")
        print("Consider running --init to complete the configuration.\n")
    
    port_ok, java_ok, permissions_ok = check_server_requirements()
    
    if not all([port_ok, java_ok, permissions_ok]):
        print("\nServer requirements check failed. Please fix the issues above.\n")
        return
    
    show_info()
    
    if not check_and_accept_eula():
        print("\nFailed to accept EULA. Server cannot start without accepting Mojang's EULA.")
        print("Please manually check and accept the EULA in eula.txt\n")
        return
    
    config = load_config()
    
    (BASE_DIR / "logs").mkdir(exist_ok=True)
    (BASE_DIR / "worlds").mkdir(exist_ok=True)
    (BASE_DIR / "config").mkdir(exist_ok=True)
    
    java_path = config["java_path"]
    max_ram_mb = config["max_ram"]
    additional_params = config.get("additional_parameters", "")
    
    if not Path(java_path).exists():
        print(f"Error: Java executable not found at {java_path}\n")
        sys.exit(1)
    
    if not SERVER_JAR.exists():
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
    
    print("")
    print("=" * 50)
    print("Starting Minecraft server...")
    print("")
    print("Command:", " ".join(command))
    print("=" * 50)
    print("")
    
    try:
        process = subprocess.Popen(
            command,
            cwd=BASE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
        
        for line in process.stdout:
            print(line, end="")
        
        process.wait()
        print("\nServer stopped.\n")
        
    except KeyboardInterrupt:
        print("\nServer shutdown requested by user.\n")
    except Exception as e:
        print(f"Error starting server: {e}\n")

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
    if not create_lock(["--rollback"]):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        config = load_config()
        current_version = config.get("version", "unknown")
    except:
        print("Error: Could not load configuration to determine current version\n")
        remove_lock()
        return
    
    backup_dir = BUNDLES_DIR / current_version
    
    if not backup_dir.exists():
        print(f"\nNo backups found for version {current_version}")
        print("")
        remove_lock()
        return
    
    backup_files = list(backup_dir.glob("*.zip"))
    if not backup_files:
        print(f"\nNo backup files found for version {current_version}")
        print("")
        remove_lock()
        return
    
    backup_files.sort(key=os.path.getmtime, reverse=True)
    
    print("\nAvailable Backups:")
    print("======================")
    
    backup_list = []
    for i, backup_file in enumerate(backup_files, 1):
        friendly_name = format_backup_name(backup_file.name, current_version)
        backup_list.append((backup_file, friendly_name))
        print(f"{i}. {friendly_name}")
    
    print("======================")
    
    try:
        selection = input("\nPlease select one to rollback: ").strip()
        if not selection:
            print("No selection made.\n")
            remove_lock()
            return
        
        index = int(selection) - 1
        if index < 0 or index >= len(backup_list):
            print("Invalid selection.\n")
            remove_lock()
            return
        
        selected_file, friendly_name = backup_list[index]
        print(f"\nSelected file: {selected_file.name}")
        print("Rolling back now, please wait...")
        
        temp_dir = BASE_DIR / "temp_rollback"
        if temp_dir.exists():
            shutil.rmtree(temp_dir)
        temp_dir.mkdir(parents=True, exist_ok=True)
        
        with zipfile.ZipFile(selected_file, "r") as zipf:
            zipf.extractall(temp_dir)
        
        if not temp_dir.exists() or not any(temp_dir.iterdir()):
            print("Error: Failed to extract backup file or backup is empty\n")
            if temp_dir.exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
            remove_lock()
            return
        
        exclude_list = get_exclude_list()
        
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                continue
            if item.is_dir():
                shutil.rmtree(item)
            else:
                try:
                    item.unlink()
                except:
                    pass
        
        for item in temp_dir.iterdir():
            dest = BASE_DIR / item.name
            if item.is_dir():
                if dest.exists():
                    shutil.rmtree(dest)
                shutil.copytree(item, dest, symlinks=True)
            else:
                shutil.copy2(item, dest)
        
        shutil.rmtree(temp_dir, ignore_errors=True)
        temp_dir = BASE_DIR / "temp_save"
        shutil.rmtree(temp_dir, ignore_errors=True)
        
        print("Server rollbacked successfully\n")
        
    except ValueError:
        print("Invalid input. Please enter a number.\n")
    except Exception as e:
        print(f"Error during rollback: {e}")
        import traceback
        traceback.print_exc()
        if temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
    finally:
        remove_lock()

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
    command = ["--upgrade"]
    if force:
        command.append("force")
    if not create_lock(command):
        print("\nError: Could not create task lock\n")
        return
    
    try:
        print("\n" + "=" * 50)
        print("               Server Core Upgrade")
        print("=" * 50)
        
        if force:
            print("\nForce mode: Showing all available versions regardless of compatibility.\n")
        
        try:
            config = load_config()
            current_version = config.get("version", "unknown")
        except:
            print("Error: Could not determine current server version.")
            print("Please ensure the server is properly configured.\n")
            return
        
        print(f"Current server version: {current_version}")
        
        try:
            current_major = '.'.join(current_version.split('.')[:2])
        except:
            print("Error: Could not parse current version format.")
            return
        
        backup_choice = input("\nDo you want to create a backup before upgrading? (Y/N): ").strip().upper()
        if backup_choice == "Y":
            print("Creating backup...")
            backup_version()
        
        available_versions = []
        if BUNDLES_DIR.exists():
            for version_dir in BUNDLES_DIR.iterdir():
                if version_dir.is_dir():
                    core_zip = version_dir / "core.zip"
                    if core_zip.exists():
                        version_name = version_dir.name
                        if force:
                            available_versions.append(version_name)
                        else:
                            try:
                                version_major = '.'.join(version_name.split('.')[:2])
                                if (compare_versions(version_name, current_version) >= 0 and 
                                    version_major == current_major):
                                    available_versions.append(version_name)
                            except:
                                continue
        
        if not available_versions:
            if force:
                print(f"\nNo versions found in bundles directory.")
            else:
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
                    elif compare_versions(version, current_version) > 0:
                        status = "↑ NEWER"
                    elif compare_versions(version, current_version) == 0:
                        status = "= CURRENT"
                    else:
                        status = "↓ OLDER"
                except:
                    status = "? UNKNOWN"
            else:
                status = "↑ NEWER" if compare_versions(version, current_version) > 0 else "= CURRENT"
            
            print(f"{i}. {version} {status}")
        print("=" * 30)
        
        try:
            selection = input("\nSelect a version to upgrade to (number): ").strip()
            if not selection:
                print("No selection made.\n")
                return
            
            index = int(selection) - 1
            if index < 0 or index >= len(sorted_versions):
                print("Invalid selection.")
                return
            
            selected_version = sorted_versions[index]
            print(f"Selected version: {selected_version}")
            
            if force:
                try:
                    selected_major = '.'.join(selected_version.split('.')[:2])
                    if selected_major != current_major:
                        print(f"\nWARNING: Major version mismatch!")
                        print(f"Current: {current_version} (major {current_major})")
                        print(f"Selected: {selected_version} (major {selected_major})")
                        print("This upgrade may cause world corruption or plugin incompatibility!")
                        confirm = input("\nAre you sure you want to continue? (Y/N): ").strip().upper()
                        if confirm != "Y":
                            print("Upgrade canceled.\n")
                            return
                    elif compare_versions(selected_version, current_version) < 0:
                        print(f"\nWARNING: Downgrading from {current_version} to {selected_version}")
                        print("This may cause data loss or compatibility issues!")
                        confirm = input("\nAre you sure you want to continue? (Y/N): ").strip().upper()
                        if confirm != "Y":
                            print("Upgrade canceled.\n")
                            return
                except:
                    pass
            
            if selected_version == current_version:
                print("Selected version is the same as current version.")
                reinstall = input("Do you want to reinstall the current version? (Y/N): ").strip().upper()
                if reinstall != "Y":
                    print("Upgrade canceled.\n")
                    return
            
            if check_for_updates(selected_version):
                update_choice = input("\nNewer build available. Download now? (Y/N): ").strip().upper()
                if update_choice == "Y":
                    download_version(selected_version)
            
            show_version_info(selected_version)
            
            confirm = input(f"\nAre you sure you want to upgrade from {current_version} to {selected_version}? (Y/N): ").strip().upper()
            if confirm != "Y":
                print("Upgrade canceled.\n")
                return
            
            print("\nUpgrading server core...")
            
            core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
            
            if not core_zip_path.exists():
                print(f"Error: Core package not found for version {selected_version}")
                return
            
            temp_jar_dir = BASE_DIR / "temp_jar"
            if temp_jar_dir.exists():
                shutil.rmtree(temp_jar_dir)
            temp_jar_dir.mkdir()
            
            try:
                with zipfile.ZipFile(core_zip_path, 'r') as zipf:
                    zipf.extractall(temp_jar_dir)
                
                core_jar_temp = temp_jar_dir / "core.jar"
                if not core_jar_temp.exists():
                    print("Error: core.jar not found in the package.")
                    return
                
                if SERVER_JAR.exists():
                    backup_jar = BASE_DIR / "core.jar.bak"
                    shutil.copy2(SERVER_JAR, backup_jar)
                    print("Backed up current core.jar")
                
                shutil.copy2(core_jar_temp, SERVER_JAR)
                print("\nCore upgraded successfully.")
                
                config = configparser.ConfigParser()
                config.read(CONFIG_FILE)
                if "SERVER" in config:
                    config["SERVER"]["version"] = selected_version
                    with open(CONFIG_FILE, "w") as f:
                        config.write(f)
                    print(f"Updated configuration to version {selected_version}")
                
            except Exception as e:
                print(f"Error during core upgrade: {e}")
                return
            finally:
                if temp_jar_dir.exists():
                    shutil.rmtree(temp_jar_dir)
            
            plugin_choice = input("\nDo you want to disable all plugins for data safety? (Y/N): ").strip().upper()
            if plugin_choice == "Y":
                if disable_all_plugins():
                    print("All plugins have been disabled.")
                else:
                    print("Failed to disable some plugins.")
            else:
                print("Plugins left unchanged.")
            
            print("\nServer upgrade completed successfully!")
            print("Please review your plugin compatibility before starting the server.\n")
            
        except ValueError:
            print("Invalid input. Please enter a number.\n")
        except Exception as e:
            print(f"Error during upgrade process: {e}\n")
    
    finally:
        remove_lock()

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
    print("\n" + "=" * 50)
    print("                Self Update Check")
    print("=" * 50)
    
    print(f"\nCurrent script version: {SCRIPT_VERSION}")
    
    if force:
        print("\nForce mode: Bypassing version check, will download latest version directly.")
        confirm = input("\nDo you want to download the latest version from GitHub? (Y/N): ").strip().upper()
        if confirm == "Y":
            return download_latest_version()
        else:
            print("Download canceled.\n")
            return False
    
    print("Checking for updates...\n")
    
    update_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/update.json"
    
    try:
        with urllib.request.urlopen(update_url, timeout=10) as response:
            update_info = json.loads(response.read().decode())
        
        latest_version = update_info.get("latest_version")
        expected_md5 = update_info.get("md5")
        release_date = update_info.get("date", "Unknown")
        
        if not latest_version or not expected_md5:
            print("Error: Invalid update information format.\n")
            return False
        
        print(f"Latest version available: {latest_version} (Released: {release_date})")
        
        if compare_script_versions(SCRIPT_VERSION, latest_version) >= 0:
            print("You are already running the latest version.")
            print('You can use "--version force" to download the latest version.\n')
            return True
        
        print(f"\nNew version {latest_version} is available!")
        confirm = input("Do you want to download and update? (Y/N): ").strip().upper()
        if confirm != "Y":
            print("Update canceled.")
            return False

        return download_latest_version()
        
    except urllib.error.URLError as e:
        print(f"Network error: Could not check for updates - {e}\n")
        return False
    except Exception as e:
        print(f"Error checking for updates: {e}\n")
        return False

def download_latest_version():
    script_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/start.sh"
    update_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/update.json"
    
    print(f"\nDownloading latest version from: {script_url}")
    
    try:
        with urllib.request.urlopen(update_url, timeout=10) as response:
            update_info = json.loads(response.read().decode())
        
        expected_md5 = update_info.get("md5")
        latest_version = update_info.get("latest_version", "Unknown")
        
        if not expected_md5:
            print("Warning: Could not verify file integrity - no MD5 hash available.")
        
        with urllib.request.urlopen(script_url, timeout=30) as response:
            script_content = response.read()
        
        if expected_md5:
            print("Verifying file integrity...")
            file_hash = hashlib.md5()
            file_hash.update(script_content)
            actual_md5 = file_hash.hexdigest()
            
            if actual_md5 != expected_md5:
                print(f"MD5 verification failed!")
                print(f"Expected: {expected_md5}")
                print(f"Got: {actual_md5}")
                print("\nThe downloaded file may be corrupted or tampered with.")
                print("Update aborted for security reasons.")
                return False
            print("MD5 verification passed.\n")
        
        current_script = Path(__file__).resolve()
        
        backup_script = current_script.with_name(current_script.name + '.bak')
        new_script = current_script.with_name(current_script.name + '.new')
        
        try:
            shutil.copy2(current_script, backup_script)
            print(f"Backup created: {backup_script}")
        except Exception as e:
            print(f"Warning: Could not create backup: {e}")
        
        with open(new_script, 'wb') as f:
            f.write(script_content)
        
        try:
            if platform.system() != "Windows":
                os.chmod(new_script, 0o755)
        except Exception as e:
            print(f"Warning: Could not set executable permissions: {e}")
        
        try:
            if platform.system() == "Windows":
                os.remove(current_script)
                shutil.move(new_script, current_script)
            else:
                os.replace(new_script, current_script)
            
            print("\nUpdate completed successfully!")
            print(f"Script has been updated to version {latest_version}.")
            print("Please run the script again to use the new version.")
            print("")
            
            return True
            
        except Exception as e:
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
        print(f"Error during update process: {e}\n")
        new_script = Path(__file__).resolve().with_name(current_script.name + '.new')
        if new_script.exists():
            try:
                new_script.unlink()
            except:
                pass
        return False

def show_help():
    print("=" * 51)
    print("      Minecraft Server Management Tool (v5.2)")
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
    print("  (no command)      Start the server")
    print("  --init            Initialize new server configuration")
    print("  --info            Show current server configuration")
    print("  --list            List all available versions")
    print("  --plugins         Show installed plugins and toggle them")
    print("  --save <ver>      Save current version to bundles")
    print("  --backup          Create timestamped backup of current version")
    print("  --worlds          Manage worlds with multiple options")
    print("  --get <ver>       Fetch a Purpur server info and download")
    print("  --new             Save current server and create a new one")
    print("  --rollback        Rollback to a previous backup")
    print("  --delete <ver>    Delete specified version from bundles")
    print("  --change <ver>    Switch to specified version")
    print("  --upgrade         Upgrade server core to compatible version")
    print("  --cleanup         Clean up server files to free up space")
    print("  --dump            Create a compressed dump of log files")
    print("  --settings        Edit server properties and settings")
    print("  --players         Manage banned players, IPs, and whitelist")
    print("  --version         Check for script updates and update if available")
    print("  --license         Show the open source license for this tool")
    print("  --help            Show this help message")
    print("")

clear_screen()

def main():
    if not check_environment_change():
        return
    
    pending_command = handle_pending_task()
    if pending_command:
        sys.argv = [sys.argv[0]] + pending_command
    
    BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
    
    if len(sys.argv) == 1:
        start_server()
    elif sys.argv[1] == "--init":
        if len(sys.argv) > 2 and sys.argv[2].lower() == "auto":
            init_config_auto()
        else:
            init_config()
    elif sys.argv[1] == "--info":
        show_info()
    elif sys.argv[1] == "--list":
        list_versions()
    elif sys.argv[1] == "--save" and len(sys.argv) > 2:
        save_version(sys.argv[2])
    elif sys.argv[1] == "--backup":
        backup_version()
    elif sys.argv[1] == "--delete" and len(sys.argv) > 2:
        delete_version(sys.argv[2])
    elif sys.argv[1] == "--change" and len(sys.argv) > 2:
        change_version(sys.argv[2])
    elif sys.argv[1] == "--cleanup":
        cleanup_files()
    elif sys.argv[1] == "--dump":
        dump_logs()
    elif sys.argv[1] == "--plugins":
        manage_plugins_with_dependencies()
    elif sys.argv[1] == "--rollback":
        rollback_version()
    elif sys.argv[1] == "--get":
        if len(sys.argv) > 2:
            download_version(sys.argv[2])
        else:
            download_version()
    elif sys.argv[1] == "--worlds":
        manage_worlds()
    elif sys.argv[1] == "--new":
        create_new_server()
    elif sys.argv[1] == "--upgrade":
        if len(sys.argv) > 2 and sys.argv[2].lower() == "force":
            upgrade_server(force=True)
        else:
            upgrade_server(force=False)
    elif sys.argv[1] == "--version":
        if len(sys.argv) > 2 and sys.argv[2].lower() == "force":
            check_self_update(force=True)
        else:
            check_self_update(force=False)
    elif sys.argv[1] == "--settings":
        edit_server_settings()
    elif sys.argv[1] == "--license":
        show_license()
    elif sys.argv[1] == "--players":
        manage_player_lists()
    elif sys.argv[1] == "--help":
        show_help()
    else:
        print("\nInvalid command or arguments")
        print(f"Use '{SCRIPT_NAME} --help' for usage information\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
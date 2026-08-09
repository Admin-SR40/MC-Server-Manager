#!/usr/bin/env python3

#     __  _________   _____                              __  ___                                 
#    /  |/  / ____/  / ___/___  ______   _____  _____   /  |/  /___ _____  ____ _____ ____  _____
#   / /|_/ / /       \__ \/ _ \/ ___/ | / / _ \/ ___/  / /|_/ / __ `/ __ \/ __ `/ __ `/ _ \/ ___/
#  / /  / / /___    ___/ /  __/ /   | |/ /  __/ /     / /  / / /_/ / / / / /_/ / /_/ /  __/ /    
# /_/  /_/\____/   /____/\___/_/    |___/\___/_/     /_/  /_/\__,_/_/ /_/\__,_/\__, /\___/_/     
#                                                                            /____/             
#
# Welcome!
#
# The script is open-source and available at:
#   https://github.com/Admin-SR40/MC-Server-Manager
#
# You can visit the wiki page to learn more about the script:
#   https://deepwiki.com/Admin-SR40/MC-Server-Manager
#
# To run this script, use:
#   Windows: python start.sh [options]
#   Linux/Mac: ./start.sh [options]
#
# Encountered an issue or need help?
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
import urllib.error
import fnmatch
import hashlib
import socket
import time
import logging
import threading
import importlib.util
from collections import deque
import traceback

if os.name == "posix":
    try:
        import pty
        import select
        import termios
    except ImportError:
        pty = None
        select = None
        termios = None
else:
    pty = None
    select = None
    termios = None
from pathlib import Path

SCRIPT_VERSION = "9.0"
SERVER_START_TIME = None
SERVER_END_TIME = None
USER_AGENT = "MCSM/" + SCRIPT_VERSION
BASE_DIR = Path(os.getcwd())
CONFIG_FILE = BASE_DIR / "config" / "version.cfg"
MODULES_CONFIG_FILE = BASE_DIR / "config" / "modules.cfg"
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
UPDATE_URL = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/update.json"
MODULES_DIR = None
MODULES_JSON = None
_lock_depth = 0
_loaded_modules = {}
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


# ── Utility functions ──────────────────────────────────────────────

def print_banner(title, width=50):
    """Print a centered banner with '=' separators."""
    print()
    print("=" * width)
    print(title.center(width))
    print("=" * width)

def confirm_action(prompt, default_no=True):
    """Ask a Y/N question, return True if user confirms."""
    default_hint = " (Y/N): " if default_no else " (y/N): "
    while True:
        choice = input(prompt + default_hint).strip().upper()
        if choice == 'Y':
            return True
        if choice == 'N':
            return False
        print("Please enter Y or N.")

def log_and_print(msg, level="info"):
    """Log a message and print it to console."""
    if level == "error":
        logger.error(msg)
    elif level == "warning":
        logger.warning(msg)
    else:
        logger.info(msg)
    print(msg)

def safe_rmtree(path):
    """Safely remove a directory tree, ignoring errors."""
    p = Path(path) if not isinstance(path, Path) else path
    if p.exists():
        shutil.rmtree(p, ignore_errors=True)

def _unlock_with_logging(op_name):
    """Remove task lock with standard logging."""
    logger.info(f"Removing task lock for {op_name} operation")
    if remove_lock():
        logger.info("Task lock removed successfully")
    else:
        logger.error(f"Failed to remove task lock for {op_name} operation")

# ───────────────────────────────────────────────────────────────────
def setup_logger():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("mc-manager")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    formatter = logging.Formatter(
        fmt="%(asctime)s %(levelname)s > %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S"
    )
    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    if LOG_FILE.exists() and LOG_FILE.stat().st_size > 128 * 1024:
        try:
            file_handler.close()
            logger.removeHandler(file_handler)
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H-%M-%S")
            archive_filename = f"{timestamp}.manager.log.gz"
            archive_path = LOG_DIR / archive_filename
            with open(LOG_FILE, 'rb') as f_in:
                with gzip.open(archive_path, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)
            with open(LOG_FILE, 'w') as f:
                f.truncate(0)
            new_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
            new_handler.setLevel(logging.INFO)
            new_handler.setFormatter(formatter)
            logger.addHandler(new_handler)
            logger.info(f"Log file rotated: {archive_filename} (original size: {LOG_FILE.stat().st_size} bytes)")
        except Exception as e:
            try:
                logger.addHandler(file_handler)
            except Exception:
                pass
            logger.warning(f"Warning: Failed to rotate log file: {e}")
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
        is_android = os.path.exists("/system/build.prop")
        if is_android:
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

def create_lock(command):
    global _lock_depth
    logger.info(f"Attempting to create lock for command: {' '.join(command)}")
    if _lock_depth > 0:
        _lock_depth += 1
        logger.info(f"Lock already held (depth {_lock_depth}), nesting new command")
        return True
    try:
        with open(LOCK_FILE, 'w', encoding='utf-8') as f:
            f.write(f"Command: {' '.join(command)}\n")
            f.write(f"Timestamp: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"PID: {os.getpid()}\n")
        _lock_depth = 1
        logger.info(f"Lock created successfully at {LOCK_FILE}")
        logger.info(f"Lock details - Command: {' '.join(command)}, PID: {os.getpid()}")
        return True        
    except Exception as e:
        logger.error(f"Error creating lock file: {e}")
        print(f"\nError creating lock file: {e}\n")
        return False

def remove_lock():
    global _lock_depth
    if _lock_depth > 0:
        _lock_depth -= 1
        if _lock_depth > 0:
            logger.info(f"Nested lock released (remaining depth: {_lock_depth})")
            return True
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

def clear_screen():
    if platform.system() == "Windows":
        os.system("cls")
    else:
        os.system("clear")

def load_config():
    global _config_cache, _config_mtime
    if not CONFIG_FILE.exists():
        logger.error("Configuration file not found")
        print(f"\nError: Configuration file not found at {CONFIG_FILE}")
        print("Please run with --init to create a new configuration\n")
        sys.exit(1)
    current_mtime = CONFIG_FILE.stat().st_mtime
    if _config_cache and _config_mtime == current_mtime:
        return dict(_config_cache)
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    if "SERVER" not in config:
        logger.error("Invalid configuration format")
        print("Error: Invalid configuration format")
        sys.exit(1)
    _config_cache = dict(config["SERVER"])
    _config_mtime = current_mtime
    return dict(_config_cache)

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

def _run_server_pty(command):
    """Run Minecraft server with PTY pseudo-terminal (Unix only)."""
    master_fd, slave_fd = pty.openpty()
    process = subprocess.Popen(
        command, cwd=BASE_DIR,
        stdin=sys.stdin, stdout=slave_fd, stderr=slave_fd,
        close_fds=True
    )
    os.close(slave_fd)
    logger.info(f"Server process started with PID: {process.pid} (PTY mode)")
    server_ready = False
    out_buffer = b""
    try:
        while process.poll() is None:
            r, _, _ = select.select([master_fd], [], [], 0.5)
            if r:
                try:
                    data = os.read(master_fd, 4096)
                except OSError as e:
                    if e.errno == 5:  # EIO — slave closed
                        break
                    raise
                if not data:
                    break
                if server_ready:
                    os.write(sys.stdout.fileno(), data)
                else:
                    out_buffer += data
                    while b"\n" in out_buffer:
                        line, out_buffer = out_buffer.split(b"\n", 1)
                        line += b"\n"
                        if b"Done" in line and b"For help" in line:
                            server_ready = True
                        text = line.decode("utf-8", errors="replace")
                        if "sun.misc.Unsafe" not in text and "MemUtilUnsafe" not in text:
                            os.write(sys.stdout.fileno(), line)
                    if server_ready and out_buffer:
                        os.write(sys.stdout.fileno(), out_buffer)
                        out_buffer = b""
        while True:
            r, _, _ = select.select([master_fd], [], [], 0.5)
            if not r:
                break
            try:
                data = os.read(master_fd, 4096)
            except OSError as e:
                if e.errno == 5:  # EIO — slave closed
                    break
                raise
            if not data:
                break
            if server_ready:
                os.write(sys.stdout.fileno(), data)
            else:
                out_buffer += data
                while b"\n" in out_buffer:
                    line, out_buffer = out_buffer.split(b"\n", 1)
                    line += b"\n"
                    if b"sun.misc.Unsafe" not in line and b"MemUtilUnsafe" not in line:
                        os.write(sys.stdout.fileno(), line)
                if out_buffer:
                    os.write(sys.stdout.fileno(), out_buffer)
    finally:
        os.close(master_fd)
    process.wait()
    return process


def _run_server_pipe(command):
    """Run Minecraft server with pipe I/O (Windows fallback)."""
    process = subprocess.Popen(
        command, cwd=BASE_DIR,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, encoding="utf-8", errors="replace"
    )
    logger.info(f"Server process started with PID: {process.pid} (pipe mode)")
    def forward_stdin():
        try:
            for line in sys.stdin:
                process.stdin.write(line)
                process.stdin.flush()
        except (OSError, ValueError):
            pass
    stdin_thread = threading.Thread(target=forward_stdin, daemon=True)
    stdin_thread.start()
    for line in process.stdout:
        if "sun.misc.Unsafe" not in line and "MemUtilUnsafe" not in line and "Advanced terminal features" not in line:
            print(line, end="")
    try:
        process.stdin.close()
    except (OSError, ValueError):
        pass
    process.wait()
    return process


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
        if platform.system() != "Windows" and termios is not None:
            process = _run_server_pty(command)
        else:
            process = _run_server_pipe(command)
        SERVER_END_TIME = time.time()
        uptime_seconds, uptime_str, _ = get_uptime()
        logger.info(f"Server process ended with return code: {process.returncode}, uptime: {uptime_str}")
        if uptime_seconds >= 60:
            print(f"\nServer uptime: {uptime_str} (or {int(uptime_seconds)} seconds)")
        else:
            print(f"\nServer uptime: {uptime_str}")
        if process.returncode != 0:
            logger.warning(f"Server crashed with exit code: {process.returncode}")
            crash_mod = get_module("crash")
            if crash_mod:
                crash_mod.handle_server_crash(process, uptime_str)
            else:
                print("\nCrash analysis module is not installed.")
                print('Use "--install crash" to enable crash reports.\n')
        else:
            crash_mod = get_module("crash")
            if crash_mod and crash_mod.check_logs_for_errors():
                logger.info("Server stopped normally but errors found in logs")
                if crash_mod.ask_user_for_crash_analysis():
                    logger.info("User requested crash analysis for normal exit with errors")
                    crash_mod.analyze_server_crash(0, uptime_str)
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
        crash_mod = get_module("crash")
        if crash_mod and crash_mod.check_logs_for_errors():
            logger.info("Errors found in logs after user interrupt")
            if crash_mod.ask_user_for_interrupt_analysis():
                logger.info("User requested interrupt analysis")
                crash_mod.analyze_server_crash(-1, uptime_str)
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
            crash_mod = get_module("crash")
            if crash_mod:
                crash_mod.handle_server_crash(process, uptime_str)
            else:
                print("\nCrash analysis module is not installed.")
                print('Use "--install crash" to enable crash reports.\n')

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
    try:
        update_info = get_update_info()
    except Exception as e:
        logger.error(f"Could not fetch update information: {e}")
        print(f"Error: Could not check for updates - {e}\n")
        return False
    latest_version = update_info.get("latest_version", "Unknown")
    release_date = update_info.get("date", "Unknown")
    print(f"Latest version available: {latest_version} (Released: {release_date})")
    core_update = force or (
        latest_version != "Unknown" and compare_script_versions(SCRIPT_VERSION, latest_version) < 0
    )
    if core_update:
        if not force:
            print(f"\nNew version {latest_version} is available!")
        else:
            print("\nForce mode: core update check bypassed.")
        confirm = input("Do you want to download and update the core script? (Y/N): ").strip().upper()
        if confirm == "Y":
            logger.info("User confirmed core update")
            download_latest_version()
        else:
            logger.info("User canceled core update")
            print("Core update canceled.\n")
    else:
        print("Core script is up to date.")
    update_installed_modules(update_info, force=force)
    return True

def download_latest_version():
    logger.info("Starting download of latest version")
    current_script = Path(__file__).resolve()
    script_url = os.environ.get(
        "MCSM_SCRIPT_URL",
        "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/start.sh"
    )
    print(f"\nDownloading latest version from: {script_url}")
    try:
        update_info = get_update_info()
        expected_md5 = update_info.get("md5")
        latest_version = update_info.get("latest_version", "Unknown")
        if not expected_md5:
            logger.warning("No MD5 hash available for verification")
            print("Warning: Could not verify file integrity - no MD5 hash available.")
        logger.info(f"Starting download of version {latest_version}")
        print("\nDownload started...")
        start_time = time.time()
        request = urllib.request.Request(script_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
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
            actual_md5 = hashlib.md5(script_content).hexdigest()
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
                print(f" 1. Delete the current script: {current_script}")
                print(f" 2. Rename '{new_script}' to '{current_script.name}'")
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
        new_script = current_script.with_name(current_script.name + '.new')
        if new_script.exists():
            try:
                new_script.unlink()
                logger.info("Cleaned up temporary new script file")
            except:
                logger.warning("Could not clean up temporary new script file")
        return False


# ── Module system ─────────────────────────────────────────────────

def get_modules_dir():
    env_dir = os.environ.get("MCSM_MODULES_DIR")
    if env_dir:
        return Path(env_dir).expanduser().resolve()
    if MODULES_CONFIG_FILE.exists():
        try:
            cfg = configparser.ConfigParser()
            cfg.read(MODULES_CONFIG_FILE, encoding="utf-8")
            if cfg.has_option("MODULES", "dir"):
                value = cfg.get("MODULES", "dir").strip()
                if value:
                    return Path(value).expanduser().resolve()
        except Exception as e:
            logger.warning(f"Could not read modules config: {e}")
    return None

def set_modules_dir(path):
    MODULES_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    cfg = configparser.ConfigParser()
    if MODULES_CONFIG_FILE.exists():
        try:
            cfg.read(MODULES_CONFIG_FILE, encoding="utf-8")
        except Exception:
            pass
    if not cfg.has_section("MODULES"):
        cfg.add_section("MODULES")
    cfg.set("MODULES", "dir", str(path))
    with open(MODULES_CONFIG_FILE, "w", encoding="utf-8") as f:
        cfg.write(f)
    logger.info(f"Modules directory configured: {path}")
    print(f"Modules directory set to: {path}")

def resolve_modules_dir():
    global MODULES_DIR, MODULES_JSON
    MODULES_DIR = get_modules_dir()
    MODULES_JSON = MODULES_DIR / "modules.json" if MODULES_DIR else None

def choose_modules_dir():
    print("\nChoose where to store installed modules:")
    print(" 1. ~/.cache/MC-Server-Manager (shared across servers)")
    print(" 2. ./bundles/modules (this server only)")
    print(" 3. Custom path")
    while True:
        choice = input("\nYour choice (1-3): ").strip()
        if choice == "1":
            return Path.home() / ".cache" / "MC-Server-Manager"
        elif choice == "2":
            return BASE_DIR / "bundles" / "modules"
        elif choice == "3":
            custom = input("Enter custom path: ").strip()
            if custom:
                return Path(custom).expanduser().resolve()
            print("Path cannot be empty.")
        else:
            print("Invalid choice. Please enter 1, 2, or 3.")

def is_modules_environment_installed():
    if not MODULES_DIR or not MODULES_DIR.exists():
        return False
    if MODULES_JSON.exists():
        return True
    return any(MODULES_DIR.glob("*.py"))

def read_modules_json():
    if not MODULES_JSON or not MODULES_JSON.exists():
        return {}
    try:
        with open(MODULES_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        logger.warning(f"Could not read modules.json: {e}")
        return {}

def write_modules_json(registry):
    if not MODULES_DIR:
        return False
    try:
        MODULES_DIR.mkdir(parents=True, exist_ok=True)
        with open(MODULES_JSON, "w", encoding="utf-8") as f:
            json.dump(registry, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        logger.error(f"Could not write modules.json: {e}")
        print(f"Error: Could not save module registry: {e}\n")
        return False

def get_update_info():
    url = os.environ.get("MCSM_UPDATE_URL", UPDATE_URL)
    logger.info(f"Fetching update info from: {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode())

def download_module(name, info):
    url = info.get("url")
    expected_md5 = info.get("md5")
    if not url:
        logger.error(f"No download URL for module: {name}")
        print(f"Error: No download URL for module '{name}'\n")
        return False
    if not MODULES_DIR:
        print("Error: Modules directory is not configured.\n")
        return False
    try:
        MODULES_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(f"Could not create modules directory {MODULES_DIR}: {e}")
        print(f"Error: Could not create modules directory {MODULES_DIR}: {e}\n")
        return False
    temp_dir = MODULES_DIR / ".tmp"
    try:
        temp_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(f"Could not create temporary directory {temp_dir}: {e}")
        print(f"Error: Could not create temporary directory {temp_dir}: {e}\n")
        return False
    temp_file = temp_dir / f"{name}.py"
    print(f"\nDownloading module '{name}'...")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        start_time = time.time()
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read()
        elapsed_time = time.time() - start_time
        actual_md5 = hashlib.md5(content).hexdigest()
        if expected_md5 and actual_md5 != expected_md5:
            logger.error(f"MD5 verification failed for module {name} (expected: {expected_md5}, got: {actual_md5})")
            print(f"MD5 verification failed for '{name}'!")
            print(f"Expected: {expected_md5}")
            print(f"Got: {actual_md5}")
            print("The downloaded file may be corrupted or tampered with.\n")
            return False
        try:
            compile(content, f"{name}.py", "exec")
        except SyntaxError as e:
            logger.error(f"Module {name} failed syntax check: {e}")
            print(f"Error: Module '{name}' failed syntax check: {e}\n")
            return False
        temp_file.write_bytes(content)
        os.replace(temp_file, MODULES_DIR / f"{name}.py")
        download_speed = len(content) / elapsed_time / 1024 if elapsed_time > 0 else 0
        print(f"Installed '{name}' (version {info.get('version', 'unknown')}, {len(content)} bytes, {download_speed:.2f} KB/s)")
        logger.info(f"Module {name} installed successfully (version {info.get('version', 'unknown')})")
        return True
    except urllib.error.URLError as e:
        logger.error(f"Network error downloading module {name}: {e}")
        print(f"Error: Could not download module '{name}' - {e}\n")
        return False
    except Exception as e:
        logger.error(f"Error downloading module {name}: {e}")
        print(f"Error downloading module '{name}': {e}\n")
        return False
    finally:
        if temp_file.exists():
            try:
                temp_file.unlink()
            except Exception:
                pass

def install_modules_from_info(update_info, names, interactive=True):
    modules = update_info.get("modules", {})
    installed = read_modules_json()
    registry = dict(installed)
    to_install = []
    skipped = set()
    def resolve(name):
        if name in skipped or name in to_install or name in installed:
            return True
        info = modules.get(name)
        if not info:
            print(f"Unknown module: {name}")
            skipped.add(name)
            return False
        missing_deps = [dep for dep in info.get("requires", []) if dep not in installed and dep not in to_install]
        if missing_deps:
            print(f"\nModule '{name}' requires: {', '.join(missing_deps)}")
            for dep in missing_deps:
                if interactive and not confirm_action(f"Install required module '{dep}' too?", default_no=True):
                    print(f"Skipping '{name}' because required module '{dep}' was not installed.\n")
                    skipped.add(name)
                    return False
                if not resolve(dep):
                    return False
        to_install.append(name)
        return True
    for name in names:
        resolve(name)
    if not to_install:
        print("Nothing to install.\n")
        return False
    ok = False
    for name in to_install:
        info = modules[name]
        current = registry.get(name)
        if isinstance(current, dict) and current.get("version") == info.get("version") and current.get("md5") == info.get("md5"):
            print(f" - {name}: already installed (version {info.get('version')})")
            ok = True
            continue
        if download_module(name, info):
            registry[name] = {
                "version": info.get("version"),
                "md5": info.get("md5"),
                "installed_at": datetime.datetime.now().isoformat()
            }
            ok = True
    if registry != installed:
        write_modules_json(registry)
    return ok

def select_modules_interactive(modules):
    names = sorted(modules.keys())
    print("\nAvailable modules:")
    print("=" * 52)
    for i, name in enumerate(names, 1):
        info = modules[name]
        requires = f" (requires: {', '.join(info.get('requires', []))})" if info.get("requires") else ""
        print(f" {i:2d}. {name:<12} - {info.get('description', '')}{requires}")
    print("=" * 52)
    print("Enter numbers (e.g. '1 2 3'), 'all' for everything, or Enter to cancel.")
    choice = input("\nYour selection: ").strip().lower()
    if not choice:
        return []
    if choice == "all":
        return names
    selected = []
    for part in choice.split():
        if not part.isdigit():
            continue
        idx = int(part) - 1
        if 0 <= idx < len(names) and names[idx] not in selected:
            selected.append(names[idx])
    return selected

def run_install_flow(args=None, first_run=False):
    args = args or []
    global MODULES_DIR, MODULES_JSON
    if not MODULES_DIR:
        path = choose_modules_dir()
        if not path:
            print("Installation canceled.\n")
            return False
        set_modules_dir(path)
        MODULES_DIR = path
        MODULES_JSON = path / "modules.json"
    try:
        MODULES_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(f"Could not create modules directory {MODULES_DIR}: {e}")
        print(f"\nError: Could not create modules directory {MODULES_DIR}")
        print(f"{e}\n")
        return False
    try:
        update_info = get_update_info()
    except Exception as e:
        logger.error(f"Could not fetch module list: {e}")
        print(f"\nError: Could not fetch module list: {e}")
        print("Please check your internet connection and try again.\n")
        return False
    modules = update_info.get("modules", {})
    if not modules:
        print("No modules are available in update.json.\n")
        return False
    if first_run:
        print("\nFirst run detected - please choose which modules to install.")
    if args:
        targets = []
        for arg in args:
            if arg.lower() == "all":
                targets = list(modules.keys())
                break
            targets.append(arg)
        unknown = [target for target in targets if target not in modules]
        if unknown:
            print(f"Unknown module(s): {', '.join(unknown)}")
            print(f"Available modules: {', '.join(sorted(modules))}\n")
        targets = [target for target in targets if target in modules]
        if not targets:
            return False
        return install_modules_from_info(update_info, targets)
    selected = select_modules_interactive(modules)
    if not selected:
        print("No modules selected. Installation canceled.\n")
        return False
    return install_modules_from_info(update_info, selected)

def update_installed_modules(update_info, force=False):
    print("\nChecking installed modules...")
    installed = read_modules_json()
    if not installed:
        print("No modules installed. Nothing to update.\n")
        return
    updates = []
    cloud_modules = update_info.get("modules", {})
    for name, local in sorted(installed.items()):
        cloud = cloud_modules.get(name)
        local_version = local.get("version") if isinstance(local, dict) else local
        local_md5 = local.get("md5") if isinstance(local, dict) else ""
        if not cloud:
            print(f" - {name}: no longer listed in update.json")
            continue
        if force or local_version != cloud.get("version") or local_md5 != cloud.get("md5"):
            updates.append((name, cloud))
    if not updates:
        print("All installed modules are up to date.\n")
        return
    print("\nUpdates available for installed modules:")
    for name, cloud in updates:
        local = installed.get(name, {})
        local_version = local.get("version") if isinstance(local, dict) else "?"
        print(f" - {name}: {local_version} -> {cloud.get('version')}")
    confirm = input("\nUpdate these modules now? (Y/N): ").strip().upper()
    if confirm != "Y":
        print("Module updates canceled.\n")
        return
    registry = dict(installed)
    for name, cloud in updates:
        if download_module(name, cloud):
            registry[name] = {
                "version": cloud.get("version"),
                "md5": cloud.get("md5"),
                "installed_at": datetime.datetime.now().isoformat()
            }
    write_modules_json(registry)
    print("")

def get_installed_module_names():
    names = []
    if MODULES_DIR and MODULES_DIR.exists():
        names = [path.stem for path in MODULES_DIR.glob("*.py")]
    registry = read_modules_json()
    for name in registry:
        if name not in names:
            names.append(name)
    return sorted(set(names))

def load_module(name):
    if not MODULES_DIR:
        return None
    path = MODULES_DIR / f"{name}.py"
    if not path.exists():
        return None
    if name in _loaded_modules:
        return _loaded_modules[name]
    try:
        spec = importlib.util.spec_from_file_location(f"mcsm_module_{name}", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if hasattr(module, "bind"):
            module.bind(ctx)
        version = "unknown"
        if hasattr(module, "MODULE"):
            version = module.MODULE.get("version", "unknown")
        logger.info(f"Loaded module: {name} (version {version})")
        _loaded_modules[name] = module
        return module
    except Exception as e:
        logger.error(f"Failed to load module '{name}': {e}", exc_info=True)
        print(f"Error: Failed to load module '{name}': {e}")
        print(f"Try reinstalling it with: --install {name}\n")
        return None

class CoreContext:
    def __init__(self):
        self.SCRIPT_VERSION = SCRIPT_VERSION
        self.BASE_DIR = BASE_DIR
        self.CONFIG_FILE = CONFIG_FILE
        self.BUNDLES_DIR = BUNDLES_DIR
        self.SCRIPT_NAME = SCRIPT_NAME
        self.SERVER_JAR = SERVER_JAR
        self.PLUGINS_DIR = PLUGINS_DIR
        self.WORLDS_DIR = WORLDS_DIR
        self.SERVER_PROPERTIES = SERVER_PROPERTIES
        self.EULA_FILE = EULA_FILE
        self.LOCK_FILE = LOCK_FILE
        self.LOG_DIR = LOG_DIR
        self.LOG_FILE = LOG_FILE
        self.logger = logger
        self.print_banner = print_banner
        self.confirm_action = confirm_action
        self.log_and_print = log_and_print
        self.safe_rmtree = safe_rmtree
        self.unlock_with_logging = _unlock_with_logging
        self.format_file_size = format_file_size
        self.load_config = load_config
        self.create_lock = create_lock
        self.remove_lock = remove_lock
        self.check_lock = check_lock
        self.is_process_running = is_process_running
        self.get_exclude_list = get_exclude_list
        self.get_device_id = get_device_id
        self.show_info = show_info
        self.get_uptime = get_uptime
        self.compare_versions = compare_versions
        self.USER_AGENT = USER_AGENT
    def get_module(self, name):
        return load_module(name)

MODULE_COMMANDS = {
    "--init": "init",
    "--standardize": "init",
    "--get": "version",
    "--list": "version",
    "--new": "version",
    "--change": "version",
    "--upgrade": "version",
    "--delete": "version",
    "--save": "backup",
    "--backup": "backup",
    "--rollback": "backup",
    "--plugins": "plugins",
    "--worlds": "worlds",
    "--players": "players",
    "--settings": "settings",
    "--cleanup": "maintenance",
    "--dump": "maintenance",
}

def show_help():
    print("=" * 51)
    print(f"      Minecraft Server Management Tool (v{SCRIPT_VERSION})")
    print("=" * 51)
    print("")
    print("A modular command-line tool for managing")
    print("Minecraft server versions, backups, plugins and")
    print("other configurations with ease.")
    print("")
    print("Usage:")
    print(f"  {SCRIPT_NAME} [command] [options]")
    print("")
    print("Core Commands:")
    print("  (no command)           Start the server")
    print("  --install [module|all] Install or update modules")
    print("  --info                 Show current server configuration")
    print("  --version [force]      Check for script and module updates")
    print("  --license              Show the open source license")
    print("  --help                 Show this help message")
    print("")
    installed = get_installed_module_names()
    if installed:
        print("Installed Module Commands:")
        print("-" * 51)
        for name in installed:
            module = load_module(name)
            if not module or not hasattr(module, "MODULE"):
                continue
            commands = module.MODULE.get("commands", {})
            for command, description in commands.items():
                print(f"  {command:<22} {description}")
        print("-" * 51)
        print("")
    else:
        print("No modules installed.")
        print('Use "--install" to choose modules, or "--install all" to install everything.')
        print("")
    try:
        update_info = get_update_info()
        available = update_info.get("modules", {})
        uninstalled = [name for name in sorted(available) if name not in installed]
        if uninstalled:
            print("Not Installed (available via --install):")
            print("=" * 51)
            for name in uninstalled:
                info = available[name]
                print(f"  {name:<12} - {info.get('description', '')}")
            print("")
            print('Tip: "--install all" installs all modules.')
    except Exception as e:
        print('Run "--install" to view and install available modules.')
    print("")

def main():
    global logger, ctx
    logger = setup_logger()
    ctx = CoreContext()
    logger.info(f"Starting {SCRIPT_NAME} version {SCRIPT_VERSION}")
    clear_screen()
    args = sys.argv[1:]
    resolve_modules_dir()
    core_only_commands = ("--help", "--license", "--install", "--version")
    is_core_only = bool(args) and args[0] in core_only_commands
    if args and args[0] == "--install":
        run_install_flow(args[1:])
        return
    if not is_core_only and not is_modules_environment_installed():
        logger.info("No modules installed, entering first-run install flow")
        print("\n" + "=" * 60)
        print("            FIRST RUN - MODULE SETUP")
        print("=" * 60)
        run_install_flow(first_run=True)
        if not is_modules_environment_installed():
            print("\nNo modules installed. Run '--install' to set up modules.\n")
            return
    try:
        logger.info("Checking environment...")
        if not check_environment_change():
            logger.warning("Environment check failed or user chose to exit")
            return
        pending_command = handle_pending_task()
        if pending_command:
            logger.info(f"Resuming pending command: {' '.join(pending_command)}")
            sys.argv = [sys.argv[0]] + pending_command
            args = pending_command
        BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
        logger.info(f"Working directory: {BASE_DIR}")
        logger.info(f"User executed: {' '.join(sys.argv)}")
        if not args:
            logger.info("Starting server")
            start_server()
        elif args[0] == "--info":
            logger.info("Showing server configuration info")
            show_info()
        elif args[0] == "--version":
            force = len(args) > 1 and args[1].lower() == "force"
            logger.info(f"Checking for updates (force: {force})")
            check_self_update(force=force)
        elif args[0] == "--license":
            logger.info("Showing license information")
            show_license()
        elif args[0] == "--help":
            logger.info("Showing help")
            show_help()
        elif args[0] in MODULE_COMMANDS:
            module_name = MODULE_COMMANDS[args[0]]
            logger.info(f"Routing command to module: {module_name}")
            module = load_module(module_name)
            if module and hasattr(module, "dispatch"):
                module.dispatch(args, ctx)
            else:
                print(f"Module '{module_name}' is not installed.")
                print(f'Install it with: --install {module_name}\n')
                sys.exit(1)
        else:
            logger.warning(f"Invalid command: {' '.join(args)}")
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

#!/usr/bin/env python3
# init module for MC-Server-Manager
# Server initialization, Java/memory detection and structure standardization.

import os
import sys
import re
import glob
import json
import time
import shutil
import platform
import subprocess
import configparser
import zipfile
from pathlib import Path

MODULE = {
    "name": "init",
    "version": "1.0",
    "description": "Server initialization and structure standardization",
    "requires": [],
    "commands": {
        "--init": "cmd.init",
        "--init auto": "cmd.init.auto",
        "--standardize": "cmd.standardize",
    },
}

BASE_DIR = None
CONFIG_FILE = None
SERVER_JAR = None
SERVER_PROPERTIES = None
logger = None
create_lock = None
remove_lock = None
get_device_id = None
show_info = None
compare_versions = None
truncate_text = None
t = None
center_text = None


def bind(ctx):
    global BASE_DIR, CONFIG_FILE, SERVER_JAR, SERVER_PROPERTIES, logger
    global create_lock, remove_lock, get_device_id, show_info, compare_versions, truncate_text, t, center_text
    BASE_DIR = ctx.BASE_DIR
    CONFIG_FILE = ctx.CONFIG_FILE
    SERVER_JAR = ctx.SERVER_JAR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    get_device_id = ctx.get_device_id
    show_info = ctx.show_info
    compare_versions = ctx.compare_versions
    truncate_text = ctx.truncate_text
    t = ctx.t
    center_text = ctx.center_text


def dispatch(args, ctx):
    if not args:
        return
    if args[0] == "--standardize":
        standardize_server_structure()
    elif args[0] == "--init":
        if len(args) > 1 and args[1].lower() == "auto":
            init_config_auto()
        else:
            init_config()


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
        logger.warning(f"Could not determine total memory: {e}")
        print(f" - Warning: Could not determine total memory: {e}")
        return 4 * 1024 * 1024 * 1024


def is_running_in_container():
    if os.path.exists('/.dockerenv'):
        logger.info("Container detected (/.dockerenv)")
        return True
    try:
        if os.path.exists('/proc/1/cgroup'):
            with open('/proc/1/cgroup', 'r') as f:
                content = f.read()
                if 'docker' in content or 'kubepods' in content:
                    logger.info("Container detected (/proc/1/cgroup)")
                    return True
    except Exception as e:
        logger.debug(f"Could not read /proc/1/cgroup: {e}")
    container_env_vars = ['KUBERNETES_SERVICE_HOST', 'CONTAINER_ID', 'DOCKER_CONTAINER']
    detected = any(var in os.environ for var in container_env_vars)
    if detected:
        logger.info("Container detected (environment variables)")
    return detected


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
        except Exception as e:
            logger.debug(f"Could not read cgroup v2 memory limit: {e}")
    cgroup_v1_path = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
    if os.path.exists(cgroup_v1_path):
        try:
            with open(cgroup_v1_path, 'r') as f:
                limit = int(f.read().strip())
                if limit > 0 and limit < 2**63:
                    return limit
        except Exception as e:
            logger.debug(f"Could not read cgroup v1 memory limit: {e}")
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
            except Exception as e:
                logger.debug(f"Could not parse container memory env var {env_var}: {e}")
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
            print(t("init.plugin_analyze_error", name=plugin_path.name, error=e))
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
        print(t("init.memory_warning", allocated=allocated_mb, max=max_allowed))
        if is_container:
            safe_allocation = min(allocated_mb, total_mem_mb * 0.7)
            print(t("init.container_adjusted", value=safe_allocation))
            return safe_allocation
        else:
            print(t("init.adjusted_limit", value=max_allowed))
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
        logger.info("core.jar already exists, skipping core detection")
        print(t("init.core_exists"))
        return True
    jar_files = list(BASE_DIR.glob("*.jar"))
    if not jar_files:
        logger.info("No JAR files found in current directory")
        print(t("init.no_jars"))
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
                        logger.info(f"Found valid server core: {jar_file.name} (Version: {version_id})")
                        print(t("init.found_core", name=jar_file.name, version=version_id))
        except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as e:
            logger.warning(f"Skipping {jar_file.name}: Not a valid server core ({e})")
            print(t("init.skipping_core", name=jar_file.name, error=e))
            continue
        except Exception as e:
            logger.error(f"Error checking {jar_file.name}: {e}")
            print(t("init.core_error", name=jar_file.name, error=e))
            continue
    if not valid_cores:
        logger.warning("No valid server cores found in JAR files")
        print(t("init.no_valid_cores"))
        return False
    if len(valid_cores) == 1:
        core = valid_cores[0]
        logger.info(f"Using the only valid server core: {core['name']}")
        print(t("init.using_only_core", name=core['name']))
        shutil.copy2(core['path'], SERVER_JAR)
        logger.info(f"Copied {core['name']} to core.jar")
        print(t("init.copied_core", name=core['name']))
        return True
    logger.info(f"Found multiple valid server cores: {', '.join(core['name'] for core in valid_cores)}")
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
            except Exception as e:
                logger.warning(f"Could not compare version '{core['version']}': {e}")
                if not highest_core:
                    highest_core = core
        if highest_core:
            print(t("init.auto_selected", name=highest_core['name'], version=highest_core['version']))
            shutil.copy2(highest_core['path'], SERVER_JAR)
            print(t("init.copied_core", name=highest_core['name']))
            return True
        else:
            print(t("init.auto_select_error"))
            return False
    else:
        print("\n" + t("init.multiple_cores"))
        for i, core in enumerate(cores, 1):
            print(f" {i}. {core['name']} (Version: {core['version']})")
        while True:
            try:
                choice = input("\n" + t("init.which_core_blank") + " ").strip()
                if not choice:
                    highest_core = None
                    highest_version = ""
                    for core in cores:
                        try:
                            if compare_versions(core['version'], highest_version) > 0:
                                highest_core = core
                                highest_version = core['version']
                        except Exception as e:
                            logger.warning(f"Could not compare version '{core['version']}': {e}")
                            if not highest_core:
                                highest_core = core
                    if highest_core:
                        print(t("init.selected_newest", name=highest_core['name'], version=highest_core['version']))
                        shutil.copy2(highest_core['path'], SERVER_JAR)
                        print(t("init.copied_core", name=highest_core['name']))
                        return True
                    else:
                        print(t("init.newest_error"))
                        return False
                index = int(choice) - 1
                if 0 <= index < len(cores):
                    selected_core = cores[index]
                    print(t("init.selected_core", name=selected_core['name'], version=selected_core['version']))
                    shutil.copy2(selected_core['path'], SERVER_JAR)
                    print(t("init.copied_core", name=selected_core['name']))
                    return True
                else:
                    print(t("init.enter_number_between", max=len(cores)))
            except ValueError:
                print(t("init.valid_number_blank"))
            except Exception as e:
                print(t("init.select_core_error", error=e))
                return False


def init_config(prefill_version=None):
    logger.info("Starting manual server initialization")
    print("=" * 50)
    print(center_text(t("init.title"), 50))
    print("=" * 50)
    if CONFIG_FILE.exists():
        logger.warning("Configuration file already exists, will be overwritten")
        print("\n" + t("init.config_exists"))
        print(t("init.config_will_replace"))
        confirm = input("\n" + t("init.config_continue") + " (y/N): ").strip().upper() or "N"
        if confirm != "Y":
            logger.info("User cancelled initialization, existing configuration preserved")
            print("\n" + t("init.config_preserved") + "\n")
            return
    logger.info("Checking for server core files...")
    print("\n" + t("init.checking_cores") + "...")
    core_result = detect_server_cores()
    if core_result is True:
        logger.info("Server core already exists as core.jar")
        pass
    elif isinstance(core_result, list) and len(core_result) > 0:
        logger.info(f"Found {len(core_result)} server core(s)")
        if not select_server_core(core_result, auto_mode=False):
            logger.error("Failed to select server core in manual initialization")
            print(t("init.select_failed"))
            return
        else:
            logger.info("Successfully selected server core")
    elif core_result is False:
        logger.error("No valid server cores found for manual initialization")
        print(t("init.no_valid_core_manual"))
        print(t("init.jar_hint"))
        return
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser()
    version = prefill_version
    if prefill_version:
        logger.info(f"Using prefill version: {version}")
        print("\n" + t("init.using_version", version=version))
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
            print("\n" + t("init.detected_version", version=detected_version))
            use_detected = input(t("init.use_detected") + " (Y/n): ").strip().upper() or "Y"
            if use_detected == "Y":
                version = detected_version
                logger.info("User accepted detected version")
            else:
                logger.info("User declined detected version, will prompt for version")
                while True:
                    version = input("\n" + t("init.enter_version") + " ").strip()
                    if re.match(r"^\d+\.\d+(\.\d+)?$", version):
                        logger.info(f"User entered version: {version}")
                        break
                    logger.warning(f"Invalid version format entered: {version}")
                    print(t("init.invalid_version"))
        else:
            logger.warning("Could not detect version from core.jar")
            while True:
                version = input("\n" + t("init.enter_version") + " ").strip()
                if re.match(r"^\d+\.\d+(\.\d+)?$", version):
                    logger.info(f"User entered version: {version}")
                    break
                logger.warning(f"Invalid version format entered: {version}")
                print(t("init.invalid_version"))
    while True:
        ram_input = input("\n" + t("init.enter_ram") + " ").strip()
        if ram_input.isdigit():
            ram_value = int(ram_input)
            if ram_value < 256:
                max_ram = ram_value * 1024
                logger.info(f"Converted {ram_value} GB to {max_ram} MB")
                print(t("init.converted_gb", gb=ram_value, mb=max_ram))
            else:
                max_ram = ram_value
            if max_ram < 512:
                logger.warning(f"Low RAM allocation requested: {max_ram} MB")
                print(t("init.low_ram_warning"))
                confirm = input(t("init.continue_anyway") + " (y/N): ").strip().upper() or "N"
                if confirm == "Y":
                    logger.info("User confirmed low RAM allocation")
                    break
                else:
                    logger.info("User cancelled low RAM allocation")
            else:
                break
        else:
            logger.warning(f"Invalid RAM input: {ram_input}")
            print(t("init.invalid_ram"))
    logger.info(f"RAM allocation set to: {max_ram} MB")
    print("\n" + t("init.allocated_ram", mb=max_ram, gb=max_ram/1024))
    print("\n" + t("init.additional_exclude"))
    print(t("init.exclude_hint"))
    additional_exclude = input(t("init.enter_exclusions") + " ").strip()
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
            print(t("init.no_java") + "\n")
            sys.exit(1)
        logger.info(f"Found {len(java_installations)} Java installations")
        print("\n" + format_java_table(java_installations))
        while True:
            try:
                choice = input("\n" + t("init.select_java", max=len(java_installations)) + " ").strip()
                if choice == "0":
                    logger.info("User chose custom Java path")
                    custom_path = input("\n" + t("init.enter_java_home") + " ").strip()
                    if not custom_path:
                        logger.warning("No custom Java path entered")
                        print(t("init.no_path"))
                        continue
                    logger.info(f"Validating custom Java path: {custom_path}")
                    print(t("init.validating_java") + "...")
                    validated_path = validate_java_path(custom_path)
                    if validated_path:
                        java_path = validated_path
                        logger.info(f"Custom Java path validated successfully: {java_path}")
                        print(t("init.validated"))
                        break
                    else:
                        logger.warning(f"Invalid custom Java path: {custom_path}")
                        print(t("init.invalid_java"))
                        print(t("init.java_hint2"))
                        continue
                else:
                    choice_num = int(choice)
                    if 1 <= choice_num <= len(java_installations):
                        java_path = java_installations[choice_num-1]['path']
                        logger.info(f"Selected Java installation: {java_path}")
                        break
                    logger.warning(f"Invalid Java selection: {choice}")
                    print(t("init.invalid_selection"))
            except ValueError:
                logger.error("Invalid input for Java selection")
                print(t("init.enter_number"))
    print("\n" + t("init.additional_params"))
    print(t("init.params_hint"))
    additional_params = input(t("init.enter_params") + " ").strip()
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
        print("\n" + t("init.config_saved", path=CONFIG_FILE))
        show_info()
    except Exception as e:
        logger.error(f"Failed to save configuration: {e}")
        print(t("init.save_error", error=e) + "\n")


def init_config_auto(prefill_version=None):
    logger.info("Starting automatic server initialization")
    start_time = time.time()
    print("=" * 50)
    print(center_text(t("init.title_auto"), 50))
    print("=" * 50)
    if CONFIG_FILE.exists():
        logger.info("Configuration file already exists, will be overwritten")
        print("\n" + t("init.auto_overwrite") + "...")
    logger.info("Checking for server core files...")
    print("\n" + t("init.checking_cores") + "...")
    core_result = detect_server_cores()
    if core_result is True:
        logger.info("Server core already exists as core.jar")
        pass
    elif isinstance(core_result, list) and len(core_result) > 0:
        logger.info(f"Found {len(core_result)} server core(s), auto-selecting...")
        if not select_server_core(core_result, auto_mode=True):
            logger.error("Failed to auto-select server core")
            print(t("init.auto_select_failed"))
            return
        else:
            logger.info("Successfully auto-selected server core")
    elif core_result is False:
        logger.error("No valid server cores found")
        print(t("init.no_valid_core_manual"))
        print(t("init.jar_hint"))
        print(t("init.auto_jar_hint"))
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
        print("\n" + t("init.using_detected", version=version))
    else:
        logger.warning(f"Could not detect version from core.jar, using: {version}")
        print("\n" + t("init.cannot_detect", version=version))
    print(t("init.required_java", java=java_required))
    logger.info(f"Finding Java installations (required: Java {java_required})")
    java_installations = find_java_installations()
    available_versions = [int(j['version']) for j in java_installations if j['version'].isdigit()]
    java_path = None
    if not available_versions:
        logger.warning("No Java installations found!")
        print("\n" + t("init.no_java_auto") + "!")
        custom = input(t("init.custom_java_ask") + " ").strip().upper() or "N"
        if custom == "Y":
            while True:
                custom_path = input(t("init.enter_java_home") + " ").strip()
                validated = validate_java_path(custom_path)
                if validated:
                    java_path = validated
                    logger.info(f"Using custom Java path: {java_path}")
                    break
                else:
                    logger.warning(f"Invalid Java path: {custom_path}")
                    print(t("init.invalid_path_auto"))
        else:
            logger.error("No Java available, exiting auto initialization")
            print(t("init.exiting_auto"))
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
            print(t("init.no_suitable_java", version=test_ver))
            print(t("init.exiting_auto"))
            return
    logger.info("Detecting available memory...")
    print("\n" + t("init.detecting_memory") + "...")
    total_mem_bytes = get_total_memory()
    total_mem_gb = total_mem_bytes / (1024 ** 3)
    total_mem_mb = total_mem_gb * 1024
    is_container = is_running_in_container()
    if is_container:
        logger.info("Running in container environment")
        print(t("init.running_container"))
    logger.info(f"Total available memory: {total_mem_mb:.0f} MB ({total_mem_gb:.1f} GB)")
    print(t("init.total_memory", mb=total_mem_mb, gb=total_mem_gb))
    if total_mem_mb < 512:
        logger.error(f"Insufficient memory: {total_mem_mb:.0f} MB (< 512 MB)")
        print("\n" + t("init.low_memory_error"))
        print(t("init.low_memory_hint"))
        print(t("init.manual_init_hint"))
        return
    if total_mem_mb <= 8192:
        base_ram_mb = (29 * total_mem_mb + 8192) / 60
        base_ram_mb = round(base_ram_mb)
    else:
        base_ram_mb = 4096
    logger.info(f"Base allocation calculated: {base_ram_mb} MB")
    print(t("init.base_allocation", mb=base_ram_mb))
    plugins_ram_mb = 0
    plugins_dir = BASE_DIR / "plugins"
    if plugins_dir.exists():
        enabled_plugins = list(plugins_dir.glob("*.jar"))
        disabled_plugins = list(plugins_dir.glob("*.jar.disabled"))
        total_plugins = len(enabled_plugins) + len(disabled_plugins)
        enabled_count = len(enabled_plugins)
        logger.info(f"Found {enabled_count} enabled plugins out of {total_plugins} total")
        print("\n" + t("init.analyzing_plugins", count=enabled_count))
        plugins_ram_mb = calculate_plugins_memory(enabled_plugins)
        logger.info(f"Plugins memory allocation: {plugins_ram_mb} MB")
        print(t("init.plugins_allocation", mb=plugins_ram_mb))
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
    print("\n" + t("init.player_details"))
    print(t("init.estimated_players", count=player_details['estimated_players']))
    print(t("init.view_distance", distance=player_details['view_distance']))
    print(t("init.multiplier", multiplier=player_details['memory_multiplier']))
    print(t("init.players_allocation", mb=players_ram_mb))
    total_allocated_mb = base_ram_mb + plugins_ram_mb + players_ram_mb
    logger.info(f"Total memory allocation before validation: {total_allocated_mb:.1f} MB")
    print("\n" + t("init.breakdown"))
    print(t("init.base", mb=base_ram_mb))
    print(t("init.plugins", mb=plugins_ram_mb))
    print(t("init.players", mb=players_ram_mb))
    print(t("init.total", mb=total_allocated_mb))
    total_allocated_mb = validate_memory_allocation(total_mem_mb, total_allocated_mb, is_container)
    final_ram_mb = int(total_allocated_mb)
    logger.info(f"Final allocated RAM after validation: {final_ram_mb} MB")
    print("\n" + t("init.final_ram", mb=final_ram_mb, gb=final_ram_mb/1024))
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
    print("\n" + t("init.auto_saved", path=CONFIG_FILE))
    show_info()
    elapsed_time = time.time() - start_time
    logger.info(f"Auto initialization completed in {elapsed_time:.2f}s")
    print(t("init.auto_completed", time=f"{elapsed_time:.2f}") + "!\n")


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
                except Exception as e:
                    logger.debug(f"Java version probe failed for {real_path}: {e}")
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
                    except Exception as e:
                        logger.debug(f"Java version probe failed for PATH entry {path}: {e}")
                        continue
    except Exception as e:
        logger.warning(f"Could not search PATH for Java: {e}")
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
                except Exception as e:
                    logger.debug(f"Java version probe failed for JAVA_HOME {java_path}: {e}")
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
    logger.info(f"Found {len(unique_installations)} Java installation(s)")
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

_config_cache = {}
_config_mtime = 0


def standardize_server_structure():
    if not create_lock(["--standardize"]):
        print("\n" + t("init.lock_busy") + "\n")
        logger.warning("Failed to acquire task lock, another task running")
        return
    try:
        print("\n" + "=" * 43)
        print(center_text(t("init.standardize_title"), 43))
        print("=" * 43)
        print("\n" + t("init.standardize_desc1"))
        print(t("init.standardize_desc2"))
        choice = input(t("init.standardize_confirm") + " (y/N): ").strip().upper() or "N"
        logger.info(f"User confirmation input: {choice}")
        if choice != "Y":
            print("\n" + t("init.standardize_cancelled") + "\n")
            logger.info("User cancelled standardization")
            remove_lock()
            return
        logger.info("User confirmed standardization")
        start_time = time.time()
        config_files = [
            "bukkit.yml",
            "commands.yml",
            "purpur.yml",
            "server.properties",
            "spigot.yml",
            "paper-global.yml",
            "paper-world-defaults.yml",
        ]
        config_dir = BASE_DIR / "config"
        moved_any_config = False
        print("\n" + t("init.moving_config") + "...")
        logger.info("Starting config file standardization")
        config_dir.mkdir(exist_ok=True)
        logger.info("Ensured config directory exists")
        for filename in config_files:
            src = BASE_DIR / filename
            dst = config_dir / filename
            if src.exists():
                try:
                    shutil.move(str(src), str(dst))
                    print(t("init.moved", name=filename))
                    logger.info(f"Moved config file: {filename}")
                    moved_any_config = True
                except Exception as e:
                    print(t("init.move_failed", name=filename, error=e))
                    logger.warning(f"Failed to move config file {filename}: {e}")
        if not moved_any_config:
            print(t("init.no_config_moved"))
            logger.info("No config files required moving")
        worlds_dir = BASE_DIR / "worlds"
        world_candidates = [
            d for d in BASE_DIR.iterdir()
            if d.is_dir()
            and d.name.startswith("world")
            and d.name != "worlds"
        ]
        print("\n" + t("init.moving_worlds") + "...")
        logger.info("Starting world directory standardization")
        if world_candidates:
            worlds_dir.mkdir(exist_ok=True)
            logger.info("Ensured worlds directory exists")
            for world in world_candidates:
                try:
                    shutil.move(str(world), str(worlds_dir / world.name))
                    print(t("init.moved_world", name=world.name))
                    logger.info(f"Moved world directory: {world.name}")
                except Exception as e:
                    print(t("init.move_world_failed", name=world.name, error=e))
                    logger.warning(f"Failed to move world directory {world.name}: {e}")
        else:
            print(t("init.no_worlds_found"))
            logger.info("No world directories detected")
        bundles_dir = BASE_DIR / "bundles"
        if not bundles_dir.exists():
            bundles_dir.mkdir()
            print("\n" + t("init.created_bundles"))
            logger.info("Created bundles directory")
        else:
            logger.info("Bundles directory already exists")
        print("\n" + t("init.detecting_cores") + "...\n")
        logger.info("Detecting server core jar files")
        jar_files = [
            f for f in BASE_DIR.iterdir()
            if f.is_file() and f.suffix == ".jar"
        ]
        if not jar_files:
            print(t("init.no_jar_files"))
            logger.warning("No jar files detected in base directory")
        elif len(jar_files) == 1:
            jar = jar_files[0]
            logger.info(f"Single jar detected: {jar.name}")

            if jar.name != "core.jar":
                jar.rename(BASE_DIR / "core.jar")
                print(t("init.renamed_core", name=jar.name))
                logger.info(f"Renamed jar {jar.name} to core.jar")
            else:
                print(t("init.core_exists_short"))
                logger.info("core.jar already exists, no rename needed")
        else:
            print(t("init.multiple_jars"))
            logger.warning("Multiple jar files detected")
            for idx, jar in enumerate(jar_files, 1):
                print(f" [{idx}] {jar.name}")
                logger.info(f"Jar candidate [{idx}]: {jar.name}")
            while True:
                sel = input(
                    "\n" + t("init.which_core", max=len(jar_files)) + " "
                ).strip()
                logger.info(f"User jar selection input: {sel}")
                if not sel.isdigit():
                    print(t("init.invalid_input"))
                    logger.warning("User provided non-numeric jar selection")
                    continue
                sel = int(sel)
                if 1 <= sel <= len(jar_files):
                    selected = jar_files[sel - 1]
                    logger.info(f"User selected jar: {selected.name}")
                    break
                print(t("init.selection_out_of_range"))
                logger.warning("User jar selection out of range")
            target = BASE_DIR / "core.jar"
            try:
                if target.exists():
                    target.unlink()
                    logger.info("Existing core.jar removed before rename")
                selected.rename(target)
                print(t("init.renamed_core", name=selected.name))
                logger.info(f"Renamed jar {selected.name} to core.jar")
            except Exception as e:
                print(t("init.rename_failed", error=e))
                logger.error(f"Failed to rename selected jar {selected.name}: {e}")
        elapsed = time.time() - start_time
        print("\n" + t("init.standardize_completed", time=f"{elapsed:.2f}") + "\n")
        logger.info(f"Standardize completed successfully in {elapsed:.2f}s")
        print(t("init.you_should_init"))
        print(" 1. " + t("version.init_manual"))
        print(" 2. " + t("version.init_auto"))
        print(" 3. " + t("version.init_exit") + "\n")
        while True:
            next_choice = input(t("init.your_choice") + " ").strip()
            logger.info(f"Post-standardize init choice: {next_choice}")
            if next_choice == "1":
                logger.info("User chose manual initialization")
                remove_lock()
                init_config()
                return
            elif next_choice == "2":
                logger.info("User chose auto initialization")
                remove_lock()
                init_config_auto()
                return
            elif next_choice == "3":
                print("\n" + t("init.exiting_no_init") + "\n")
                logger.info("User exited without initialization")
                remove_lock()
                return
            else:
                print(t("init.invalid_choice"))
                logger.warning("Invalid init choice input")
    finally:
        logger.info("Task lock released, standardize process ended")

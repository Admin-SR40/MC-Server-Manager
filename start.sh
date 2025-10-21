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
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    print("\nError: PyYAML is not installed.\nPlease install it with: pip install PyYAML\n")
    sys.exit(1)

SCRIPT_VERSION = "3.1"

BASE_DIR = Path(os.getcwd())
CONFIG_FILE = BASE_DIR / "config" / "version.cfg"
BUNDLES_DIR = BASE_DIR / "bundles"
SCRIPT_NAME = Path(__file__).name
SERVER_JAR = BASE_DIR / "core.jar"
PLUGINS_DIR = BASE_DIR / "plugins"
WORLDS_DIR = BASE_DIR / "worlds"
SERVER_PROPERTIES = BASE_DIR / "config" / "server.properties"
EULA_FILE = BASE_DIR / "eula.txt"

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
        import socket
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
    table.append("                 - Plugins Management -")
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
    vendor_width = 10
    
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

def reset_worlds():
    print("\n" + "=" * 50)
    print("         World Reset Utility")
    print("=" * 50)
    
    world_folders = []
    if WORLDS_DIR.exists():
        world_folders = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
    
    if not world_folders:
        print("\nNo world folders found. Proceeding to seed configuration...\n")
        configure_world_seed()
        return
    
    print("\nExisting World Folders:")
    print("=" * 30)
    print("0. Delete ALL world folders")
    for i, world_folder in enumerate(world_folders, 1):
        world_size = sum(f.stat().st_size for f in world_folder.rglob('*') if f.is_file())
        print(f"{i}. {world_folder.name} ({world_size // (1024*1024)} MB)")
    print("=" * 30)
    
    try:
        selection = input("\nSelect world folders to delete (space-separated numbers, 0 for all): ").strip()
        if not selection:
            print("No selection made. Operation canceled.\n")
            return
        
        selected_indices = []
        for num_str in selection.split():
            try:
                num = int(num_str)
                if 0 <= num <= len(world_folders):
                    selected_indices.append(num)
                else:
                    print(f"Invalid number: {num}")
                    return
            except ValueError:
                print(f"Invalid input: {num_str}")
                return
        
        if 0 in selected_indices:
            confirm = input("\nAre you sure you want to delete ALL world folders?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm == "Y":
                for world_folder in world_folders:
                    try:
                        shutil.rmtree(world_folder)
                        print(f"Deleted: {world_folder.name}")
                    except Exception as e:
                        print(f"Error deleting {world_folder.name}: {e}")
                
                print("\nAll world folders deleted successfully.\n")
                configure_world_seed()
            else:
                print("Operation canceled.\n")
        else:
            deleted_count = 0
            for idx in selected_indices:
                world_folder = world_folders[idx-1]
                try:
                    shutil.rmtree(world_folder)
                    print(f"Deleted: {world_folder.name}")
                    deleted_count += 1
                except Exception as e:
                    print(f"Error deleting {world_folder.name}: {e}")
            
            print(f"\n{deleted_count} world folder(s) deleted successfully.")
            
            remaining_folders = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
            if remaining_folders:
                print("\nNote: Some world folders still exist.")
                print("To configure world seed, you must delete ALL world folders to avoid conflicts.")
                print("Run --reset again and select option 0 to delete all worlds.\n")
            else:
                print("\nAll world folders removed. Proceeding to seed configuration...\n")
                configure_world_seed()
                
    except KeyboardInterrupt:
        print("\nOperation canceled by user.\n")
        return
    except Exception as e:
        print(f"Error during world reset: {e}\n")
        return

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
    print("\n" + "=" * 50)
    print("         New Server Creation")
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
        print("")
        return
    
    print("\nAvailable Versions:")
    print("=" * 30)
    
    sorted_versions = sorted(
        available_versions, 
        key=lambda v: [int(n) for n in v.split('.')], 
        reverse=True
    )
    
    for i, version in enumerate(sorted_versions, 1):
        print(f"{i}. {version}")
    print("=" * 30)
    
    try:
        selection = input("\nPlease select a version to create (number): ").strip()
        if not selection:
            print("No selection made.\n")
            return
        
        index = int(selection) - 1
        if index < 0 or index >= len(sorted_versions):
            print("Invalid selection.")
            return
        
        selected_version = sorted_versions[index]
        print(f"Selected version: {selected_version}")
    except ValueError:
        print("Invalid input. Please enter a number.")
        return
    
    if check_for_updates(selected_version):
        confirm = input("\nWould you like to update to the latest build before creating the server? (Y/N): ").strip().upper()
        if confirm == "Y":
            download_version(selected_version)
    
    show_version_info(selected_version)
    
    server_files_exist = any(
        item.name not in BASE_EXCLUDE_LIST and 
        not item.name.startswith('.') and
        item.name != 'bundles'
        for item in BASE_DIR.iterdir()
    )
    
    if server_files_exist:
        confirm = input("\nDo you want to save the current server before creating a new one? (Y/N): ").strip().upper()
        if confirm == "Y":
            backup_version()
    
    core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
    
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
        
        info_file = BASE_DIR / "info.txt"
        if info_file.exists():
            info_file.unlink()
            
    except Exception as e:
        print(f"Error extracting core: {e}\n")
        return
    
    print("\nStarting server initialization...\n")
    init_config(prefill_version=selected_version)
    
    print("New server created successfully!")
    print("")

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
                for major, minors in sorted(version_groups.items(), reverse=True):
                    print(f"[{major}]: {', '.join(sorted(minors, reverse=True))}")
                print("=" * 50)
                print("")
                
        except Exception as e:
            print(f"Error fetching available versions: {e}\n")
            return
    else:
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
    
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    
    config = configparser.ConfigParser()
    
    if prefill_version:
        version = prefill_version
        print(f"\nUsing version: {version}")
    else:
        while True:
            version = input("\nEnter Minecraft server version (e.g., 1.21.5): ").strip()
            if re.match(r"^\d+\.\d+\.\d+$", version):
                break
            print("Invalid version format. Use format like 1.21.5")
    
    while True:
        max_ram = input("\nSet maximum RAM in GB (e.g., 4): ").strip()
        if max_ram.isdigit() and int(max_ram) > 0:
            max_ram = int(max_ram)
            break
        print("Invalid RAM size. Must be integer greater than 0")
    
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
    
    config["SERVER"] = {
        "version": version,
        "max_ram": str(max_ram),
        "java_path": java_path,
    }
    
    if additional_exclude:
        config["SERVER"]["additional_list"] = additional_exclude
    
    if additional_params:
        config["SERVER"]["additional_parameters"] = additional_params
    
    with open(CONFIG_FILE, "w") as f:
        config.write(f)
    
    print(f"\nConfiguration saved to {CONFIG_FILE}")
    show_info()

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
                vendor = "Eclipse Temurin"
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
        max_ram = config.get("max_ram", "Unknown")
        java_path = config.get("java_path", "Not set")
        additional_list = config.get("additional_list", "None")
        additional_params = config.get("additional_parameters", "None")
        
        print("\nServer Configuration:")
        print("=" * 50)
        print(f"Minecraft Version: {version}")
        print(f"Max RAM: {max_ram} GB")
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
            status = f"✓ ({len(zip_files)} backups)"
        else:
            status = "✗ (no backups)"
        print(f"- {version} {status}")
    print("=" * 30)

    print("\nExclusion List:")
    print("=" * 30)
    for i, item in enumerate(exclude_list, 1):
        print(f"{i}. {item}")
    print("=" * 30)
    print("")

def save_version(version):
    if not version:
        print("Usage: --save <version>")
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

def backup_version():
    try:
        config = load_config()
        version = config.get("version", "unknown")
    except:
        print("Error: Could not load configuration to determine current version\n")
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
        
    shutil.rmtree(temp_dir, ignore_errors=True)

def delete_version(version):
    if not version:
        print("Usage: --delete <version>")
        return
    
    target_dir = BUNDLES_DIR / version
    
    if not target_dir.exists():
        print("")
        print(f"Version {version} does not exist")
        print("")
        return
    
    confirm = input(f"\nAre you sure you want to delete version '{version}'? (Y/N): ")
    if confirm != "Y":
        print("Deletion canceled\n")
        return
    
    try:
        shutil.rmtree(target_dir)
        print(f"Version {version} deleted successfully\n")
    except Exception as e:
        print(f"Error deleting version: {e}\n")

def change_version(target_version):
    if not target_version:
        print("Usage: --change <version>")
        return
    
    if not CONFIG_FILE.exists():
        print("\nConfiguration file not found! Run with --init first.\n")
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

def cleanup_files():
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

def dump_logs():
    logs_dir = BASE_DIR / "logs"
    
    if not logs_dir.exists() or not any(logs_dir.iterdir()):
        print("")
        print("No log files found to dump.")
        print("")
        return
    
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = BASE_DIR / f"logs_dump_{timestamp}.log.gz"
    
    print(f"\nCreating log dump...")
    
    try:
        temp_dir = BASE_DIR / f"temp_logs_{timestamp}"
        temp_dir.mkdir(parents=True, exist_ok=True)
        
        for root, _, files in os.walk(logs_dir):
            for file in files:
                src_path = os.path.join(root, file)
                rel_path = os.path.relpath(src_path, BASE_DIR)
                dest_path = temp_dir / rel_path
                dest_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_path, dest_path)
        
        with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(temp_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    arcname = os.path.relpath(file_path, temp_dir)
                    zipf.write(file_path, arcname)
        
        shutil.rmtree(temp_dir, ignore_errors=True)
        
        file_size = os.path.getsize(output_file)
        print(f"Log dump created successfully: {output_file} ({file_size} bytes, ~{file_size // (1024*1024)} MB)")
        
        confirm = input("\nDo you want to delete the original log files? (Y/N): ")
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
                        print(f"Error deleting {file_path}: {e}\n")
            
            print(f"Deleted {deleted_count} log files, freed {freed_space} bytes.")
        
        print("")
        
    except Exception as e:
        print(f"Error creating log dump: {e}\n")
        import traceback
        traceback.print_exc()
        if temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)

def start_server():
    
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
    max_ram = config["max_ram"]
    additional_params = config.get("additional_parameters", "")
    
    if not Path(java_path).exists():
        print(f"Error: Java executable not found at {java_path}\n")
        sys.exit(1)
    
    if not SERVER_JAR.exists():
        print(f"Error: Server JAR not found at {SERVER_JAR}\n")
        sys.exit(1)
    
    command = [
        java_path,
        f"-Xmx{max_ram}G",
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
    try:
        config = load_config()
        current_version = config.get("version", "unknown")
    except:
        print("Error: Could not load configuration to determine current version\n")
        return
    
    backup_dir = BUNDLES_DIR / current_version
    
    if not backup_dir.exists():
        print(f"\nNo backups found for version {current_version}")
        print("")
        return
    
    backup_files = list(backup_dir.glob("*.zip"))
    if not backup_files:
        print(f"\nNo backup files found for version {current_version}")
        print("")
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
            return
        
        index = int(selection) - 1
        if index < 0 or index >= len(backup_list):
            print("Invalid selection.\n")
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
    print("\n" + "=" * 50)
    print("         Server Core Upgrade")
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
                backup_jar = BASE_DIR / "core.jar.backup"
                shutil.copy2(SERVER_JAR, backup_jar)
                print("Backed up current core.jar")
            
            shutil.copy2(core_jar_temp, SERVER_JAR)
            print("Core upgraded successfully.")
            
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
        backup_script = current_script.with_suffix('.sh.backup')
        new_script = current_script.with_suffix('.sh.new')
        
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
        new_script = Path(__file__).resolve().with_suffix('.sh.new')
        if new_script.exists():
            try:
                new_script.unlink()
            except:
                pass
        return False

def show_help():
    print("=" * 50)
    print("     Minecraft Server Management Tool (v3.1)")
    print("=" * 50)
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
    print("  --reset           Reset worlds and set seed for new worlds")
    print("  --get <ver>       Fetch a Purpur server info and download")
    print("  --new             Save current server and create a new one")
    print("  --rollback        Rollback to a previous backup")
    print("  --delete <ver>    Delete specified version from bundles")
    print("  --change <ver>    Switch to specified version")
    print("  --upgrade         Upgrade server core to compatible version")
    print("  --cleanup         Clean up server files to free up space")
    print("  --dump            Create a compressed dump of log files")
    print("  --version         Check for script updates and update if available")
    print("  --help            Show this help message")
    print("")

clear_screen()

def main():
    
    BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
    
    if len(sys.argv) == 1:
        start_server()
    elif sys.argv[1] == "--init":
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
    elif sys.argv[1] == "--reset":
        reset_worlds()
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
    elif sys.argv[1] == "--help":
        show_help()
    else:
        print("\nInvalid command or arguments")
        print(f"Use '{SCRIPT_NAME} --help' for usage information\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
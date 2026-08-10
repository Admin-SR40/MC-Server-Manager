#!/usr/bin/env python3
# version module for MC-Server-Manager
# Purpur version management: download, switch, create and upgrade servers.

import os
import sys
import re
import json
import time
import shutil
import fnmatch
import zipfile
import hashlib
import logging
import traceback
import configparser
import datetime
import urllib.request
import urllib.error
import socket

MODULE = {
    "name": "version",
    "version": "1.0",
    "description": "Purpur version download, switch and upgrade",
    "requires": ["backup", "init"],
    "commands": {
        "--get [ver]": "Fetch Purpur server info and download",
        "--list": "List all available versions",
        "--new": "Save current server and create a new one",
        "--change <ver>": "Switch to specified version",
        "--upgrade [force/ver]": "Upgrade server core to compatible version",
        "--delete <ver>": "Delete specified version from bundles",
    },
}

BASE_DIR = None
CONFIG_FILE = None
BUNDLES_DIR = None
SERVER_JAR = None
logger = None
create_lock = None
remove_lock = None
load_config = None
get_exclude_list = None
format_file_size = None
_unlock_with_logging = None
compare_versions = None
show_info = None
USER_AGENT = None
_ctx = None


def bind(ctx):
    global BASE_DIR, CONFIG_FILE, BUNDLES_DIR, SERVER_JAR, logger
    global create_lock, remove_lock, load_config, get_exclude_list
    global format_file_size, _unlock_with_logging, compare_versions, show_info, USER_AGENT, _ctx
    BASE_DIR = ctx.BASE_DIR
    CONFIG_FILE = ctx.CONFIG_FILE
    BUNDLES_DIR = ctx.BUNDLES_DIR
    SERVER_JAR = ctx.SERVER_JAR
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    load_config = ctx.load_config
    get_exclude_list = ctx.get_exclude_list
    format_file_size = ctx.format_file_size
    _unlock_with_logging = ctx.unlock_with_logging
    compare_versions = ctx.compare_versions
    show_info = ctx.show_info
    USER_AGENT = ctx.USER_AGENT
    _ctx = ctx


def _require_module(ctx, name):
    module = ctx.get_module(name)
    if module is None:
        print(f"\nRequired module '{name}' is not installed.")
        print(f'Use "--install {name}" to install it.\n')
    return module


def dispatch(args, ctx):
    if not args:
        return
    command = args[0]
    if command == "--get":
        if len(args) > 1:
            download_version(args[1])
        else:
            download_version()
    elif command == "--list":
        list_versions()
    elif command == "--new":
        create_new_server()
    elif command == "--change" and len(args) > 1:
        change_version(args[1])
    elif command == "--upgrade":
        if len(args) > 1:
            second_arg = args[1].lower()
            if second_arg == "force":
                upgrade_server(force=True)
            else:
                upgrade_server(target_version=args[1])
        else:
            upgrade_server()
    elif command == "--delete" and len(args) > 1:
        delete_version(args[1])


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
        if CONFIG_FILE.exists():
            try:
                config = load_config()
                current_version = config.get("version", "unknown")
                logger.info(f"Current server version: {current_version}")
            except Exception as e:
                logger.error(f"Error loading configuration: {e}")
                current_version = "unknown"
                print("Warning: Could not load config, using default version 'unknown'")
        else:
            current_version = "unknown"
            logger.info("No existing configuration found, starting fresh setup")
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
            print(f" {i}. {version}")
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
            if CONFIG_FILE.exists():
                backup_mod = _require_module(_ctx, "backup")
                if backup_mod is None:
                    print("Cannot create a new server without the backup module.")
                    return
                print("\nSaving current server state...")
                backup_mod.save_version(current_version)
        except ValueError as e:
            logger.error(f"Invalid input for version selection: {e}")
            print("Invalid input. Please enter a number.")
            return
        if check_for_updates(selected_version):
            logger.info(f"Update available for version {selected_version}")
            confirm = input("\nUpdate to latest build before creating? (y/N): ").strip().upper() or "N"
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
        if _ctx:
            _ctx.preserve_modules_config()
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns")
        items_removed = 0
        items_skipped = 0
        for item in BASE_DIR.iterdir():
            if any(fnmatch.fnmatch(item.name, pattern) for pattern in exclude_list):
                items_skipped += 1
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item, ignore_errors=True)
                else:
                    item.unlink()
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
        print(" 1. Enter --init")
        print(" 2. Enter --init auto")
        print(" 3. Exit without initialization")
        while True:
            choice = input("\nYour choice (1-3): ").strip()
            logger.info(f"User initialization choice: {choice}")
            if choice == "1":
                logger.info("User chose manual initialization")
                print("Running manual initialization...")
                init_mod = _require_module(_ctx, "init")
                if init_mod:
                    init_mod.init_config(prefill_version=selected_version)
                else:
                    print("Required module 'init' is not installed.")
                    print('Use "--install init" to install it.\n')
                break
            elif choice == "2":
                logger.info("User chose auto initialization")
                print("Running auto initialization...")
                init_mod = _require_module(_ctx, "init")
                if init_mod:
                    init_mod.init_config_auto(prefill_version=selected_version)
                else:
                    print("Required module 'init' is not installed.")
                    print('Use "--install init" to install it.\n')
                break
            elif choice == "3":
                logger.info("User chose to exit without initialization")
                print("Server created but not initialized.")
                print("Please run --init or --init auto to configure the server.\n")
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
        if _ctx:
            _ctx.restore_modules_config()
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
    api_base = os.environ.get("MCSM_PURPUR_API", "https://api.purpurmc.org/v2/purpur")
    api_url = f"{api_base}/{version}"
    try:
        logger.info(f"Making API request to: {api_url}")
        request = urllib.request.Request(api_url)
        request.add_header("User-Agent", USER_AGENT)
        start_time = time.time()
        with urllib.request.urlopen(request, timeout=10) as response:
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
            build_url = f"{api_base}/{version}/{build}"
            request = urllib.request.Request(build_url)
            request.add_header("User-Agent", USER_AGENT)
            start_time = time.time()
            with urllib.request.urlopen(request, timeout=5) as build_response:
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
    logger.info(f"Showing version info for {version}")
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    if not core_zip_path.exists():
        logger.warning(f"No core.zip found for version {version}")
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
                logger.warning(f"No info.txt found for version {version}")
                print(f"No info.txt found for version {version}")
    except Exception as e:
        logger.error(f"Error reading version info for {version}: {e}")
        print(f"Error reading version info: {e}")


def _list_remote_versions():
    """Fetch and display available Purpur server versions."""
    logger.info("Fetching available versions list from PurpurMC API")
    try:
        start_time = time.time()
        api_base = os.environ.get("MCSM_PURPUR_API", "https://api.purpurmc.org/v2/purpur")
        request = urllib.request.Request(api_base)
        request.add_header("User-Agent", USER_AGENT)
        with urllib.request.urlopen(request, timeout=10) as response:
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
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching available versions: {e.reason}")
        print(f"Error: Could not connect to server - {e.reason}\n")
    except socket.timeout:
        logger.error("Timeout fetching available versions")
        print("Error: Connection timeout while fetching version list\n")
    except Exception as e:
        logger.error(f"Unexpected error fetching versions: {type(e).__name__}: {e}")
        print(f"Error fetching available versions: {e}\n")


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
            _list_remote_versions()
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
                api_base = os.environ.get("MCSM_PURPUR_API", "https://api.purpurmc.org/v2/purpur")
                api_url = f"{api_base}/{version}"
                request = urllib.request.Request(api_url)
                request.add_header("User-Agent", USER_AGENT)
                start_time = time.time()
                with urllib.request.urlopen(request, timeout=10) as response:
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
                        build_url = f"{api_base}/{version}/{build}"
                        logger.info(f"Querying build info: {build_url}")
                        request = urllib.request.Request(build_url)
                        request.add_header("User-Agent", USER_AGENT)
                        start_time = time.time()
                        with urllib.request.urlopen(request, timeout=10) as build_response:
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
                confirm = input("Do you want to download this version? (y/N): ").strip().upper() or "N"
                if confirm != "Y":
                    logger.info("User cancelled download")
                    print("Download canceled.\n")
                    return
                if zip_path.exists():
                    logger.warning(f"Version {version} already exists at {zip_path}")
                    confirm = input(f"Version {version} already exists. Overwrite? (y/N): ").strip().upper() or "N"
                    if confirm != "Y":
                        logger.info("User chose not to overwrite existing version")
                        print("Download canceled.\n")
                        return
                    else:
                        logger.info("User confirmed overwrite of existing version")
                download_url = f"{api_base}/{version}/{successful_build}/download"
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
                    request = urllib.request.Request(download_url)
                    request.add_header("User-Agent", USER_AGENT)
                    with urllib.request.urlopen(request) as download_response:
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


def list_versions():
    BUNDLES_DIR.mkdir(parents=True, exist_ok=True)
    versions = [
        d.name for d in BUNDLES_DIR.iterdir()
        if d.is_dir() and re.match(r"^\d+\.\d+(\.\d+)?$", d.name)
    ]
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
        
        confirm = input(f"\nAre you sure you want to delete version '{version}'? (y/N): ").strip().upper() or "N"
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
        _unlock_with_logging("delete")


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
        backup_mod = _require_module(_ctx, "backup")
        if backup_mod is None:
            print("Cannot switch versions without the backup module.")
            return
        backup_mod.save_version(current_version)
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
        if _ctx:
            _ctx.preserve_modules_config()
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
        traceback.print_exc()
    finally:
        if _ctx:
            _ctx.restore_modules_config()
        _unlock_with_logging("change_version")


def upgrade_server(target_version=None, force=False):
    logger.info(f"Starting upgrade_server function, target_version={target_version}, force={force}")
    command = ["--upgrade"]
    if target_version:
        command.append(target_version)
    elif force:
        command.append("force")
        logger.info("Force mode enabled")
    if not create_lock(command):
        logger.error("Failed to create lock for upgrade operation")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info("Initializing server upgrade interface")
        print("\n" + "=" * 50)
        print("               Server Core Upgrade")
        print("=" * 50)
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
        backup_choice = input("\nDo you want to create a backup before upgrading? (y/N): ").strip().upper() or "N"
        logger.info(f"User backup choice: {backup_choice}")
        if backup_choice == "Y":
            logger.info("User chose to create backup before upgrade")
            print("Creating backup...")
            backup_mod = _require_module(_ctx, "backup")
            if backup_mod:
                backup_mod.backup_version()
            else:
                print("Backup module is not installed; skipping backup.\n")
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
                        available_versions.append(version_name)
                        logger.info(f"Found version: {version_name}")
        if not available_versions:
            logger.warning("No versions found in bundles directory")
            print("\nNo versions found in bundles directory.")
            print('Use "--get <version>" to download a version first.\n')
            return
        if target_version:
            logger.info(f"Direct upgrade to version: {target_version}")
            if target_version not in available_versions:
                logger.error(f"Version {target_version} not found in bundles")
                print(f"\nVersion {target_version} not found.")
                print(f'Please download it first using: --get {target_version}\n')
                return
            selected_version = target_version
            print(f"Selected version: {selected_version}")
        else:
            filtered_versions = []
            try:
                current_major = '.'.join(current_version.split('.')[:2])
                logger.info(f"Current major version: {current_major}")
            except Exception as e:
                logger.error(f"Could not parse current version format '{current_version}': {e}")
                print("Error: Could not parse current version format.")
                return
            for ver in available_versions:
                try:
                    ver_major = '.'.join(ver.split('.')[:2])
                    if force:
                        filtered_versions.append(ver)
                        logger.info(f"Force mode: added version {ver}")
                    else:
                        if (compare_versions(ver, current_version) >= 0 and
                                ver_major == current_major):
                            filtered_versions.append(ver)
                            logger.info(f"Compatible version found: {ver}")
                except Exception as e:
                    logger.warning(f"Could not parse version {ver}: {e}")
                    continue
            if not filtered_versions:
                if force:
                    logger.warning("No versions found in bundles directory (force mode)")
                    print("\nNo versions found in bundles directory.")
                else:
                    logger.warning(f"No compatible versions found for upgrade from {current_version}")
                    print(f"\nNo compatible versions found for upgrade.")
                    print(f"Current version: {current_version}")
                    print(f"Looking for versions with major version {current_major} or higher.")
                    print('Use "--upgrade force" to show all available versions.\n')
                return
            sorted_versions = sorted(
                filtered_versions,
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
            for i, ver in enumerate(sorted_versions, 1):
                status = ""
                if force:
                    try:
                        ver_major = '.'.join(ver.split('.')[:2])
                        if ver_major != current_major:
                            status = "! INCOMPATIBLE"
                        elif compare_versions(ver, current_version) > 0:
                            status = "↑ NEWER"
                        elif compare_versions(ver, current_version) == 0:
                            status = "= CURRENT"
                        else:
                            status = "↓ OLDER"
                    except Exception as e:
                        logger.warning(f"Could not determine status for version {ver}: {e}")
                        status = "? UNKNOWN"
                else:
                    if compare_versions(ver, current_version) > 0:
                        status = "↑ NEWER"
                    else:
                        status = "= CURRENT"
                print(f" {i}. {ver} {status}")
                logger.info(f"Displayed version {ver}: {status}")
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
            except ValueError:
                logger.error("Invalid input in version selection - expected a number")
                print("Invalid input. Please enter a number.\n")
                return
            except Exception as e:
                logger.error(f"Error during version selection: {e}", exc_info=True)
                print(f"Error during version selection: {e}\n")
                return
            if force:
                try:
                    selected_major = '.'.join(selected_version.split('.')[:2])
                    if selected_major != current_major:
                        logger.warning(f"Major version mismatch: current={current_major}, selected={selected_major}")
                        print(f"\nWARNING: Major version mismatch!")
                        print(f"Current: {current_version} (major {current_major})")
                        print(f"Selected: {selected_version} (major {selected_major})")
                        print("This upgrade may cause world corruption or plugin incompatibility!")
                        confirm = input("\nAre you sure you want to continue? (y/N): ").strip().upper() or "N"
                        logger.info(f"User confirmation for major version mismatch: {confirm}")
                        if confirm != "Y":
                            logger.info("User cancelled upgrade due to major version mismatch")
                            print("Upgrade canceled.\n")
                            return
                    elif compare_versions(selected_version, current_version) < 0:
                        logger.warning(f"Downgrade detected: from {current_version} to {selected_version}")
                        print(f"\nWARNING: Downgrading from {current_version} to {selected_version}")
                        print("This may cause data loss or compatibility issues!")
                        confirm = input("\nAre you sure you want to continue? (y/N): ").strip().upper() or "N"
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
            reinstall = input("Do you want to reinstall the current version? (y/N): ").strip().upper() or "N"
            logger.info(f"User reinstall choice: {reinstall}")
            if reinstall != "Y":
                logger.info("User cancelled reinstall")
                print("Upgrade canceled.\n")
                return
        if check_for_updates(selected_version):
            logger.info(f"Update available for version {selected_version}")
            update_choice = input("\nNewer build available. Download now? (y/N): ").strip().upper() or "N"
            logger.info(f"User update choice: {update_choice}")
            if update_choice == "Y":
                logger.info("User chose to download newer build")
                print("Updating to latest build...")
                download_version(selected_version)
            else:
                logger.info("User skipped downloading newer build")
        show_version_info(selected_version)
        confirm = input(f"\nAre you sure you want to upgrade from {current_version} to {selected_version}? (y/N): ").strip().upper() or "N"
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
        plugins_mod = _ctx.get_module("plugins") if _ctx else None
        if plugins_mod:
            plugin_choice = input("\nDo you want to disable all plugins for data safety? (y/N): ").strip().upper() or "N"
            logger.info(f"User plugin disable choice: {plugin_choice}")
            if plugin_choice == "Y":
                if plugins_mod.disable_all_plugins():
                    logger.info("All plugins have been disabled")
                    print("All plugins have been disabled.")
                else:
                    logger.warning("Failed to disable some plugins")
                    print("Failed to disable some plugins.")
            else:
                logger.info("User chose to leave plugins unchanged")
                print("Plugins left unchanged.")
        else:
            print("\nPlugins module is not installed; skipping plugin disable step.")
            print('Use "--install plugins" to enable this option.\n')
        logger.info("Server upgrade completed successfully")
        print("\nServer upgrade completed successfully!")
        print("Please review your plugin compatibility before starting the server.\n")
    except KeyboardInterrupt:
        logger.warning("Upgrade operation interrupted by user")
        print("\nUpgrade interrupted by user.\n")
    except Exception as e:
        logger.error(f"Error during upgrade process: {e}", exc_info=True)
        print(f"Error during upgrade process: {e}\n")
    finally:
        _unlock_with_logging("upgrade")

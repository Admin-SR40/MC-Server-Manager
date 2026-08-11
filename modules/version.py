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
        "--get [ver]": "cmd.get",
        "--list": "cmd.list",
        "--new": "cmd.new",
        "--change <ver>": "cmd.change",
        "--upgrade [force/ver]": "cmd.upgrade",
        "--delete <ver>": "cmd.delete",
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
t = None
center_text = None


def bind(ctx):
    global BASE_DIR, CONFIG_FILE, BUNDLES_DIR, SERVER_JAR, logger
    global create_lock, remove_lock, load_config, get_exclude_list
    global format_file_size, _unlock_with_logging, compare_versions, show_info, USER_AGENT, _ctx, t, center_text
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
    t = ctx.t
    center_text = ctx.center_text


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
        print("\n" + t("version.lock_error") + "\n")
        return
    try:
        logger.info("Initializing new server creation interface")
        print("\n" + "=" * 50)
        print(center_text(t("version.new_title"), 50))
        print("=" * 50)
        if CONFIG_FILE.exists():
            try:
                config = load_config()
                current_version = config.get("version", "unknown")
                logger.info(f"Current server version: {current_version}")
            except Exception as e:
                logger.error(f"Error loading configuration: {e}")
                current_version = "unknown"
                print(t("version.config_warning"))
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
            print("\n" + t("version.no_versions"))
            print(t("version.download_hint") + "\n")
            return
        logger.info(f"Found {len(available_versions)} available versions")
        print("\n" + t("version.available_versions"))
        print("=" * 30)
        sorted_versions = sorted(available_versions, key=lambda v: [int(n) for n in v.split('.')], reverse=True)
        for i, version in enumerate(sorted_versions, 1):
            print(f" {i}. {version}")
            logger.info(f"Available version {i}: {version}")
        print("=" * 30)
        try:
            selection = input("\n" + t("version.select_create") + " ").strip()
            if not selection:
                logger.info("User cancelled version selection")
                print(t("version.no_selection"))
                return
            logger.info(f"User selected version index: {selection}")
            index = int(selection) - 1
            if not (0 <= index < len(sorted_versions)):
                logger.error(f"Invalid version selection: {selection}")
                print(t("version.invalid_selection"))
                return
            selected_version = sorted_versions[index]
            logger.info(f"Selected version: {selected_version}")
            print(t("version.selected_version", version=selected_version))
            if CONFIG_FILE.exists():
                backup_mod = _ctx.require_module("backup") if _ctx else None
                if backup_mod is None:
                    print(t("version.backup_module_missing"))
                    return
                print(t("version.save_state") + "...")
                backup_mod.save_version(current_version)
        except ValueError as e:
            logger.error(f"Invalid input for version selection: {e}")
            print(t("version.enter_number"))
            return
        if check_for_updates(selected_version):
            logger.info(f"Update available for version {selected_version}")
            confirm = input("\n" + t("version.update_build_ask") + " (y/N): ").strip().upper() or "N"
            if confirm == "Y":
                logger.info("User chose to update to latest build")
                print(t("version.updating_latest"))
                download_version(selected_version)
            else:
                logger.info("User skipped update")
        logger.info(f"Showing version info for {selected_version}")
        show_version_info(selected_version)
        core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
        if not core_zip_path.exists():
            logger.error(f"core.zip missing for version {selected_version}")
            print(t("version.core_missing", version=selected_version))
            return
        logger.info("Cleaning current directory for new server")
        print("\n" + t("version.creating_new"))
        if _ctx:
            _ctx.preserve_script_config()
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
            print(t("version.extracted_core", version=selected_version))
        except Exception as e:
            logger.error(f"Error extracting core: {e}")
            print(t("version.extract_error", error=e) + "\n")
            return
        logger.info("Presenting initialization options to user")
        print("\n" + t("version.init_options"))
        print(" 1. " + t("version.init_manual"))
        print(" 2. " + t("version.init_auto"))
        print(" 3. " + t("version.init_exit"))
        while True:
            choice = input("\n" + t("version.init_choice_prompt") + " ").strip()
            logger.info(f"User initialization choice: {choice}")
            if choice == "1":
                logger.info("User chose manual initialization")
                print(t("version.running_manual") + "...")
                init_mod = _ctx.require_module("init") if _ctx else None
                if init_mod:
                    init_mod.init_config(prefill_version=selected_version)
                else:
                    print(t("version.init_missing"))
                    print(t("version.init_install_hint") + "\n")
                break
            elif choice == "2":
                logger.info("User chose auto initialization")
                print(t("version.running_auto") + "...")
                init_mod = _ctx.require_module("init") if _ctx else None
                if init_mod:
                    init_mod.init_config_auto(prefill_version=selected_version)
                else:
                    print(t("version.init_missing"))
                    print(t("version.init_install_hint") + "\n")
                break
            elif choice == "3":
                logger.info("User chose to exit without initialization")
                print(t("version.not_initialized"))
                print(t("version.init_hint") + "\n")
                break
            else:
                logger.warning(f"Invalid initialization choice: {choice}")
                print(t("version.invalid_init_choice"))
        logger.info("New server creation process completed")
    except KeyboardInterrupt:
        logger.info("New server creation interrupted by user")
        print("\n" + t("version.cancelled") + "\n")
    except Exception as e:
        logger.error(f"Error in create_new_server(): {e}")
        print(t("version.create_error", error=e) + "\n")
    finally:
        if _ctx:
            _ctx.restore_script_config()
        if remove_lock():
            logger.info("New server creation lock released")
        else:
            logger.error("Failed to remove new server creation lock")


def check_for_updates(version):
    logger.info(f"Starting update check for version: {version}")
    print("\n" + t("version.checking_updates", version=version))
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    if not core_zip_path.exists():
        logger.warning(f"No local version found to check for updates: {core_zip_path}")
        print(t("version.no_local_version"))
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
        print(t("version.info_read_error", error=e))
        return False
    except Exception as e:
        logger.error(f"Error reading local version info: {e}")
        print(t("version.info_read_error", error=e))
        return False
    if local_build is None:
        logger.warning("Could not determine local build number")
        print(t("version.cannot_determine_build"))
        return False
    logger.info(f"Querying PurpurMC API for version {version}")
    api_base = os.environ.get("MCSM_PURPUR_API", "https://api.purpurmc.org/v2/purpur")
    api_url = f"{api_base}/{version}"
    try:
        latest_build, _ = _get_latest_successful_build(api_base, version)
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching version data - HTTP {e.code}: {e.reason}")
        print(t("version.http_error", code=e.code, reason=e.reason))
        print(t("version.cannot_check_updates") + "\n")
        return False
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching version data - {e.reason}")
        print(t("version.network_error", error=e.reason))
        print(t("version.network_hint") + "\n")
        return False
    except socket.timeout:
        logger.error("Connection timeout while fetching version data")
        print(t("version.timeout_check"))
        print(t("version.timeout_hint") + "\n")
        return False
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        print(t("version.parse_error"))
        print(t("version.invalid_data") + "\n")
        return False
    except Exception as e:
        logger.error(f"Unexpected error fetching version data: {type(e).__name__}: {e}")
        print(t("version.unexpected_error", error=e))
        print(t("version.continuing_local"))
        return False
    if latest_build is None:
        logger.warning(f"No successful builds found for version {version}")
        print(t("version.no_successful_builds"))
        return False
    logger.info(f"Local build: {local_build}, Latest successful build: {latest_build}")
    print(t("version.local_latest", local=local_build, latest=latest_build))
    if latest_build > local_build:
        logger.info(f"Update available! Build {local_build} -> {latest_build}")
        print(t("version.update_available"))
        return True
    else:
        logger.info(f"No updates found. Local build {local_build} is up-to-date or newer")
        print(t("version.no_updates"))
        return False


def show_version_info(version):
    logger.info(f"Showing version info for {version}")
    version_dir = BUNDLES_DIR / version
    core_zip_path = version_dir / "core.zip"
    if not core_zip_path.exists():
        logger.warning(f"No core.zip found for version {version}")
        print(t("version.no_core_zip", version=version))
        return
    try:
        with zipfile.ZipFile(core_zip_path, 'r') as zipf:
            if 'info.txt' in zipf.namelist():
                with zipf.open('info.txt') as info_file:
                    info_content = info_file.read().decode('utf-8')
                    print("\n" + t("version.version_info"))
                    print(info_content)
            else:
                logger.warning(f"No info.txt found for version {version}")
                print(t("version.no_info", version=version))
    except Exception as e:
        logger.error(f"Error reading version info for {version}: {e}")
        print(t("version.version_info_error", error=e))


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
            print("\n" + t("version.available_versions"))
            print("=" * 50)
            for major, minors in sorted(version_groups.items(), key=lambda x: tuple(map(int, x[0].split('.'))), reverse=True):
                sorted_minors = sorted(minors, key=lambda v: tuple(map(int, v.split('.'))), reverse=True)
                print(f"[{major}]: {', '.join(sorted_minors)}")
                logger.info(f"Major version {major}: {sorted_minors}")
            print("=" * 50)
            print("")
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching available versions: {e.code} - {e.reason}")
        print(t("version.fetch_error", error=f"{e.code} - {e.reason}") + "\n")
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching available versions: {e.reason}")
        print(t("version.connect_error", error=e.reason) + "\n")
    except socket.timeout:
        logger.error("Timeout fetching available versions")
        print(t("version.timeout_list") + "\n")
    except Exception as e:
        logger.error(f"Unexpected error fetching versions: {type(e).__name__}: {e}")
        print(t("version.fetch_error", error=e) + "\n")

def _fetch_json(url, timeout=10):
    request = urllib.request.Request(url)
    request.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())

def _get_latest_successful_build(api_base, version):
    """Return (build, build_data) for the newest SUCCESS build, else (None, None)."""
    version_data = _fetch_json(f"{api_base}/{version}")
    all_builds = version_data.get("builds", {}).get("all", [])
    if not all_builds:
        logger.warning(f"No builds found for version {version} in API response")
        return None, None
    logger.info(f"Found {len(all_builds)} builds for version {version}")
    for build in sorted(all_builds, key=int, reverse=True):
        logger.info(f"Checking build {build} for successful status...")
        try:
            build_data = _fetch_json(f"{api_base}/{version}/{build}", timeout=5)
            if build_data.get("result") == "SUCCESS":
                logger.info(f"Found successful build: {build}")
                return int(build), build_data
            logger.info(f"Build {build} result: {build_data.get('result', 'UNKNOWN')}")
        except urllib.error.HTTPError as e:
            logger.warning(f"HTTP error checking build {build}: {e.code} {e.reason}")
        except urllib.error.URLError as e:
            logger.warning(f"URL error checking build {build}: {e.reason}")
        except socket.timeout:
            logger.warning(f"Timeout checking build {build}")
        except Exception as e:
            logger.warning(f"Error checking build {build}: {type(e).__name__}: {e}")
    logger.warning(f"No successful builds found for version {version}")
    return None, None


def download_version(version=None):
    logger.info(f"Starting download_version function, version parameter: {version}")
    command = ["--get"]
    if version:
        command.append(version)
        logger.info(f"Full command: {' '.join(command)}")
    if not create_lock(command):
        logger.error("Failed to create lock for download operation")
        print("\n" + t("version.lock_error") + "\n")
        return
    try:
        if version is None:
            _list_remote_versions()
        else:
            logger.info(f"Processing specific version: {version}")
            if not re.match(r"^\d+\.\d+(\.\d+)?$", version):
                logger.error(f"Invalid version format: {version}")
                print(t("version.invalid_format_short", version=version))
                print(t("version.invalid_format"))
                return
            target_dir = BUNDLES_DIR / version
            zip_path = target_dir / "core.zip"
            logger.info(f"Target directory: {target_dir}")
            logger.info(f"Zip path: {zip_path}")
            print("\n" + t("version.fetching_info", version=version))
            try:
                logger.info(f"Querying version info from PurpurMC API: {version}")
                api_base = os.environ.get("MCSM_PURPUR_API", "https://api.purpurmc.org/v2/purpur")
                successful_build, build_data = _get_latest_successful_build(api_base, version)
                if successful_build is None:
                    logger.error(f"No successful builds found for version {version}")
                    print(t("version.no_success_build", version=version) + "\n")
                    return
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
                print("\n" + t("version.build_info"))
                print("=" * 50)
                print(t("version.author", author=author))
                print(t("version.date", date=build_date))
                print(t("version.md5", md5=md5_hash))
                print("")
                print(t("version.description"))
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
                confirm = input(t("version.download_confirm") + " (y/N): ").strip().upper() or "N"
                if confirm != "Y":
                    logger.info("User cancelled download")
                    print(t("version.download_canceled") + "\n")
                    return
                if zip_path.exists():
                    logger.warning(f"Version {version} already exists at {zip_path}")
                    confirm = input(t("version.overwrite_ask", version=version) + " (y/N): ").strip().upper() or "N"
                    if confirm != "Y":
                        logger.info("User chose not to overwrite existing version")
                        print(t("version.download_canceled") + "\n")
                        return
                    else:
                        logger.info("User confirmed overwrite of existing version")
                download_url = f"{api_base}/{version}/{successful_build}/download"
                logger.info(f"Starting download from: {download_url}")
                print("\n" + t("version.download_started", url=download_url) + "...")
                print(t("version.download_speed_hint"))
                print(t("version.ctrl_c_hint") + "\n")
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
                    print(t("version.download_completed", time=f"{elapsed_time:.2f}"))
                    print(t("version.download_speed", speed=download_speed))
                    expected_md5 = build_data.get("md5")
                    if expected_md5:
                        logger.info("Verifying file integrity with MD5...")
                        print(t("version.verifying") + "...")
                        with open(temp_jar, 'rb') as f:
                            file_hash = hashlib.md5()
                            while chunk := f.read(8192):
                                file_hash.update(chunk)
                            actual_md5 = file_hash.hexdigest()
                        if actual_md5 != expected_md5:
                            logger.error(f"MD5 verification failed! Expected: {expected_md5}, Got: {actual_md5}")
                            print(t("version.md5_failed") + "!")
                            print(t("version.md5_expected", md5=expected_md5))
                            print(t("version.md5_got", md5=actual_md5))
                            print("")
                            print(t("version.corrupted"))
                            print(t("version.deleted_security") + "\n")
                            temp_jar.unlink()
                            if zip_path.exists():
                                zip_path.unlink()
                            return
                        else:
                            logger.info("MD5 verification successful")
                            print(t("version.md5_ok") + "\n")
                    else:
                        logger.warning("No MD5 hash provided for verification")
                        print(t("version.no_md5_warning") + "\n")
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
                    print(t("version.downloaded", version=version, build=successful_build, path=zip_path) + "\n")
                except KeyboardInterrupt:
                    elapsed_time = time.time() - start_time
                    logger.warning(f"Download interrupted by user after {elapsed_time:.2f} seconds")
                    print("\n" + t("version.download_canceled") + f" ({elapsed_time:.2f}s)\n")
                    if temp_jar.exists():
                        temp_jar.unlink()
                        logger.info("Removed temporary JAR file")
                    if zip_path.exists():
                        zip_path.unlink()
                        logger.info("Removed incomplete ZIP file")
                    return
                except Exception as e:
                    logger.error(f"Error during download: {type(e).__name__}: {e}")
                    print(t("version.download_error", error=e) + "\n")
                    if temp_jar.exists():
                        temp_jar.unlink()
                    if zip_path.exists():
                        zip_path.unlink()
                    return
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    logger.error(f"Version {version} not found (404)")
                    print(t("version.version_not_found", version=version) + "\n")
                else:
                    logger.error(f"HTTP error for version {version}: {e.code} - {e.reason}")
                    print(t("version.http_error", code=e.code, reason=e.reason) + "\n")
            except urllib.error.URLError as e:
                logger.error(f"URL error for version {version}: {e.reason}")
                print(t("version.url_error", reason=e.reason) + "\n")
            except socket.timeout:
                logger.error(f"Timeout fetching version {version}")
                print(t("version.timeout", version=version) + "\n")
            except Exception as e:
                logger.error(f"Unexpected error downloading version {version}: {type(e).__name__}: {e}")
                print(t("version.download_version_error", version=version, error=e) + "\n")
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
        print("\n" + t("version.no_versions_installed") + "\n")
        return
    exclude_list = get_exclude_list()
    print("\n" + t("version.available_versions"))
    print("=" * 30)
    for version in sorted(versions, key=lambda v: [int(n) for n in v.split(".")]):
        zip_files = list((BUNDLES_DIR / version).glob("*.zip"))
        if zip_files:
            status = f"| ({len(zip_files)} backups)"
        else:
            status = "✗ (no backups)"
        print(f" - {version} {status}")
    print("=" * 30)
    print("\n" + t("version.exclusion_list"))
    print("=" * 30)
    for i, item in enumerate(exclude_list, 1):
        print(f" {i}. {item}")
    print("=" * 30)
    print("")


def delete_version(version):
    logger.info(f"Starting delete_version function for version: {version}")
    if not version:
        logger.error("No version specified in delete_version")
        print(t("version.usage_delete"))
        return
    if not create_lock(["--delete", version]):
        logger.error("Failed to create lock for delete operation")
        print("\n" + t("version.lock_error") + "\n")
        return
    try:
        target_dir = BUNDLES_DIR / version
        logger.info(f"Target directory to delete: {target_dir}")
        if not target_dir.exists():
            logger.warning(f"Version {version} does not exist at path: {target_dir}")
            print("")
            print(t("version.version_not_exist", version=version))
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
        
        confirm = input("\n" + t("version.delete_confirm", version=version) + " (y/N): ").strip().upper() or "N"
        logger.info(f"User confirmation prompt for deleting version {version}: {confirm}")
        if confirm != "Y":
            logger.info(f"User cancelled deletion of version {version}")
            print(t("version.deletion_canceled") + "\n")
            remove_lock()
            return
        logger.info(f"User confirmed deletion of version {version}")
        print("\n" + t("version.deleting_version", version=version) + "...")
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
            print(t("version.deleted_version", version=version) + "\n")
            
        except Exception as delete_error:
            logger.error(f"Error deleting version {version}: {delete_error}", exc_info=True)
            print(t("version.delete_error", error=delete_error) + "\n")
    except Exception as e:
        logger.error(f"Unexpected error in delete_version function: {e}", exc_info=True)
        print(t("version.delete_error", error=e) + "\n")
    finally:
        _unlock_with_logging("delete")


def change_version(target_version):
    logger.info(f"Starting change_version function for target version: {target_version}")
    if not target_version:
        logger.error("No target version specified in change_version")
        print(t("version.usage_change"))
        return
    if not create_lock(["--change", target_version]):
        logger.error("Failed to create lock for change version operation")
        print("\n" + t("version.lock_error") + "\n")
        return
    try:
        logger.info("Checking if configuration file exists")
        if not CONFIG_FILE.exists():
            logger.error("Configuration file not found for change version")
            print("\n" + t("version.config_not_found") + "\n")
            remove_lock()
            return
        logger.info("Reading configuration file")
        config = configparser.ConfigParser()
        config.read(CONFIG_FILE)
        if "SERVER" not in config:
            logger.warning("Configuration file missing [SERVER] section, creating default...")
            print("\n" + t("version.config_section_missing") + "\n")
            config["SERVER"] = {}
        current_version = config["SERVER"].get("version", "unknown")
        logger.info(f"Current server version: {current_version}, target version: {target_version}")
        logger.info(f"Saving current version {current_version} before switching")
        print(t("version.saving_current", version=current_version) + "...")
        backup_mod = _ctx.require_module("backup") if _ctx else None
        if backup_mod is None:
            print(t("version.backup_module_missing_change"))
            return
        backup_mod.save_version(current_version)
        zip_path = BUNDLES_DIR / target_version / "server.zip"
        logger.info(f"Looking for target version zip file at: {zip_path}")
        if not zip_path.exists():
            logger.error(f"Target version {target_version} not found at {zip_path}")
            print(t("version.target_not_found", version=target_version))
            print("")
            remove_lock()
            return
        logger.info(f"Target version found: {zip_path}")
        print(t("version.switching", version=target_version) + "...")
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns for cleanup")
        logger.info(f"Exclude patterns: {exclude_list}")
        logger.info("Starting cleanup of current directory")
        if _ctx:
            _ctx.preserve_script_config()
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
            print(t("version.switch_error", error=extract_error) + "\n")
            remove_lock()
            return
        logger.info("Updating configuration file with new version")
        if not CONFIG_FILE.exists():
            logger.warning("No config file found in target version, creating default...")
            print("\n" + t("version.target_config_missing") + "\n")
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
        print(t("version.switched", version=target_version))
        logger.info(f"Successfully switched from version {current_version} to {target_version}")
        show_info()
    except Exception as e:
        logger.error(f"Error switching version: {e}", exc_info=True)
        print(t("version.switch_error", error=e) + "\n")
        traceback.print_exc()
    finally:
        if _ctx:
            _ctx.restore_script_config()
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
        print("\n" + t("version.lock_error") + "\n")
        return
    try:
        logger.info("Initializing server upgrade interface")
        print("\n" + "=" * 50)
        print(center_text(t("version.upgrade_title"), 50))
        print("=" * 50)
        try:
            logger.info("Loading configuration to determine current version")
            config = load_config()
            current_version = config.get("version", "unknown")
            logger.info(f"Current server version from config: {current_version}")
        except Exception as e:
            logger.error(f"Failed to load configuration: {e}")
            print(t("version.current_unknown"))
            print(t("version.ensure_configured") + "\n")
            return
        print(t("version.current_version", version=current_version))
        backup_choice = input("\n" + t("version.backup_ask") + " (y/N): ").strip().upper() or "N"
        logger.info(f"User backup choice: {backup_choice}")
        if backup_choice == "Y":
            logger.info("User chose to create backup before upgrade")
            print(t("version.creating_backup") + "...")
            backup_mod = _ctx.require_module("backup") if _ctx else None
            if backup_mod:
                backup_mod.backup_version()
            else:
                print(t("version.backup_skipped") + "\n")
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
            print("\n" + t("version.no_versions_upgrade") + ".")
            print(t("version.download_first") + "\n")
            return
        if target_version:
            logger.info(f"Direct upgrade to version: {target_version}")
            if target_version not in available_versions:
                logger.error(f"Version {target_version} not found in bundles")
                print("\n" + t("version.target_not_found", version=target_version) + ".")
                print(t("version.download_first") + "\n")
                return
            selected_version = target_version
            print(t("version.selected_version", version=selected_version))
        else:
            filtered_versions = []
            try:
                current_major = '.'.join(current_version.split('.')[:2])
                logger.info(f"Current major version: {current_major}")
            except Exception as e:
                logger.error(f"Could not parse current version format '{current_version}': {e}")
                print(t("version.parse_current_error"))
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
                    print("\n" + t("version.no_versions_upgrade") + ".")
                else:
                    logger.warning(f"No compatible versions found for upgrade from {current_version}")
                    print("\n" + t("version.no_compatible"))
                    print(t("version.current_version_short", version=current_version))
                    print(t("version.looking_major", major=current_major))
                print(t("version.force_hint") + "\n")
                return
            sorted_versions = sorted(
                filtered_versions,
                key=lambda v: [int(n) for n in v.split('.')],
                reverse=True
            )
            logger.info(f"Sorted {len(sorted_versions)} versions for display")
            if force:
                print("\n" + t("version.all_available"))
            else:
                print("\n" + t("version.force_hint"))
                print(t("version.compatible_versions", major=current_major))
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
                selection = input("\n" + t("version.select_version") + " ").strip()
                logger.info(f"User selection input: '{selection}'")
                if not selection:
                    logger.info("User cancelled selection (empty input)")
                    print(t("version.no_selection_made") + "\n")
                    return
                index = int(selection) - 1
                if index < 0 or index >= len(sorted_versions):
                    logger.warning(f"Invalid selection index: {index}, valid range: 0-{len(sorted_versions)-1}")
                    print(t("version.invalid_selection_short"))
                    return
                selected_version = sorted_versions[index]
                logger.info(f"Selected version: {selected_version}")
                print(t("version.selected_version", version=selected_version))
            except ValueError:
                logger.error("Invalid input in version selection - expected a number")
                print(t("version.enter_number") + "\n")
                return
            except Exception as e:
                logger.error(f"Error during version selection: {e}", exc_info=True)
                print(t("version.selection_error", error=e) + "\n")
                return
            if force:
                try:
                    selected_major = '.'.join(selected_version.split('.')[:2])
                    if selected_major != current_major:
                        logger.warning(f"Major version mismatch: current={current_major}, selected={selected_major}")
                        print("\n" + t("version.major_mismatch_warning"))
                        print(t("version.current_major", version=current_version, major=current_major))
                        print(t("version.selected_major", version=selected_version, major=selected_major))
                        print(t("version.major_warning"))
                        confirm = input("\n" + t("version.continue_ask") + " (y/N): ").strip().upper() or "N"
                        logger.info(f"User confirmation for major version mismatch: {confirm}")
                        if confirm != "Y":
                            logger.info("User cancelled upgrade due to major version mismatch")
                            print(t("version.upgrade_canceled") + "\n")
                            return
                    elif compare_versions(selected_version, current_version) < 0:
                        logger.warning(f"Downgrade detected: from {current_version} to {selected_version}")
                        print("\n" + t("version.downgrade_header", current=current_version, selected=selected_version))
                        print(t("version.downgrade_warning"))
                        confirm = input("\n" + t("version.continue_ask") + " (y/N): ").strip().upper() or "N"
                        logger.info(f"User confirmation for downgrade: {confirm}")
                        if confirm != "Y":
                            logger.info("User cancelled downgrade")
                            print(t("version.upgrade_canceled") + "\n")
                            return
                except Exception as e:
                    logger.warning(f"Could not compare versions: {e}")
        if selected_version == current_version:
            logger.info("Selected version is same as current version")
            print(t("version.same_version"))
            reinstall = input(t("version.reinstall_ask") + " (y/N): ").strip().upper() or "N"
            logger.info(f"User reinstall choice: {reinstall}")
            if reinstall != "Y":
                logger.info("User cancelled reinstall")
                print(t("version.upgrade_canceled") + "\n")
                return
        if check_for_updates(selected_version):
            logger.info(f"Update available for version {selected_version}")
            update_choice = input("\n" + t("version.download_newer_ask") + " (y/N): ").strip().upper() or "N"
            logger.info(f"User update choice: {update_choice}")
            if update_choice == "Y":
                logger.info("User chose to download newer build")
                print(t("version.updating_latest"))
                download_version(selected_version)
            else:
                logger.info("User skipped downloading newer build")
        show_version_info(selected_version)
        confirm = input("\n" + t("version.upgrade_confirm", current=current_version, selected=selected_version) + " (y/N): ").strip().upper() or "N"
        logger.info(f"Final user confirmation for upgrade: {confirm}")
        if confirm != "Y":
            logger.info("User cancelled upgrade after final confirmation")
            print(t("version.upgrade_canceled") + "\n")
            return
        print("\n" + t("version.upgrading_core") + "...")
        core_zip_path = BUNDLES_DIR / selected_version / "core.zip"
        logger.info(f"Core ZIP path for selected version: {core_zip_path}")
        if not core_zip_path.exists():
            logger.error(f"Core package not found for version {selected_version}")
            print(t("version.core_package_error", version=selected_version))
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
                print(t("version.core_missing_package"))
                return
            logger.info("core.jar found in extracted package")
            if SERVER_JAR.exists():
                backup_jar = BASE_DIR / "core.jar.bak"
                shutil.copy2(SERVER_JAR, backup_jar)
                logger.info(f"Backed up current core.jar to: {backup_jar}")
                print(t("version.backed_up_core"))
            shutil.copy2(core_jar_temp, SERVER_JAR)
            logger.info(f"Copied new core.jar from {core_jar_temp} to {SERVER_JAR}")
            print("\n" + t("version.core_upgraded"))
            config = configparser.ConfigParser()
            config.read(CONFIG_FILE)
            if "SERVER" in config:
                config["SERVER"]["version"] = selected_version
                with open(CONFIG_FILE, "w") as f:
                    config.write(f)
                logger.info(f"Updated configuration to version {selected_version}")
                print(t("version.config_updated", version=selected_version))
            else:
                logger.warning("SERVER section not found in config, cannot update version")
        except Exception as e:
            logger.error(f"Error during core upgrade: {e}", exc_info=True)
            print(t("version.core_upgrade_error", error=e))
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
            plugin_choice = input("\n" + t("version.plugins_disable_ask") + " (y/N): ").strip().upper() or "N"
            logger.info(f"User plugin disable choice: {plugin_choice}")
            if plugin_choice == "Y":
                if plugins_mod.disable_all_plugins():
                    logger.info("All plugins have been disabled")
                    print(t("version.all_disabled"))
                else:
                    logger.warning("Failed to disable some plugins")
                    print(t("version.disable_failed"))
            else:
                logger.info("User chose to leave plugins unchanged")
                print(t("version.plugins_unchanged"))
        else:
            print("\n" + t("version.plugins_skipped"))
            print(t("version.plugins_hint") + "\n")
        logger.info("Server upgrade completed successfully")
        print("\n" + t("version.upgrade_completed") + "!")
        print(t("version.plugins_review") + "\n")
    except KeyboardInterrupt:
        logger.warning("Upgrade operation interrupted by user")
        print("\n" + t("version.upgrade_interrupted") + "\n")
    except Exception as e:
        logger.error(f"Error during upgrade process: {e}", exc_info=True)
        print(t("version.upgrade_error", error=e) + "\n")
    finally:
        _unlock_with_logging("upgrade")

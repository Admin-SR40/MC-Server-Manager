#!/usr/bin/env python3
# backup module for MC-Server-Manager
# Version snapshots, timestamped backups and rollback.

import os
import re
import shutil
import zipfile
import fnmatch
import datetime
import traceback

MODULE = {
    "name": "backup",
    "version": "1.0",
    "description": "Version snapshots, backups and rollback",
    "requires": [],
    "commands": {
        "--save <ver>": "Save current server as a named version",
        "--backup": "Create a timestamped backup",
        "--rollback": "Rollback to a previous backup",
    },
}

BASE_DIR = None
BUNDLES_DIR = None
CONFIG_FILE = None
logger = None
create_lock = None
remove_lock = None
load_config = None
get_exclude_list = None
format_file_size = None
safe_rmtree = None
_unlock_with_logging = None

def bind(ctx):
    global BASE_DIR, BUNDLES_DIR, CONFIG_FILE, logger
    global create_lock, remove_lock, load_config, get_exclude_list
    global format_file_size, safe_rmtree, _unlock_with_logging
    BASE_DIR = ctx.BASE_DIR
    BUNDLES_DIR = ctx.BUNDLES_DIR
    CONFIG_FILE = ctx.CONFIG_FILE
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    load_config = ctx.load_config
    get_exclude_list = ctx.get_exclude_list
    format_file_size = ctx.format_file_size
    safe_rmtree = ctx.safe_rmtree
    _unlock_with_logging = ctx.unlock_with_logging

def dispatch(args, ctx):
    if not args:
        return
    if args[0] == "--save" and len(args) > 1:
        save_version(args[1])
    elif args[0] == "--backup":
        backup_version()
    elif args[0] == "--rollback":
        rollback_version()

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
                    shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
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
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            logger.info(f"Cleaning up temporary directory: {temp_dir}")
            try:
                safe_rmtree(temp_dir)
                logger.info(f"Successfully removed temporary directory: {temp_dir}")
            except Exception as cleanup_error:
                logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        _unlock_with_logging("save_version")

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
                    shutil.copytree(item, dest, symlinks=True, dirs_exist_ok=True)
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
        traceback.print_exc()
    finally:
        if temp_dir.exists():
            logger.info(f"Cleaning up temporary directory: {temp_dir}")
            try:
                safe_rmtree(temp_dir)
                logger.info(f"Successfully removed temporary directory: {temp_dir}")
            except Exception as cleanup_error:
                logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        _unlock_with_logging("backup")

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
        logger.info(f"Backup {i}: {backup_file.name} ({format_file_size(file_size)}), friendly name: {friendly_name}")
        print(f" {i}. {friendly_name}")
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
                safe_rmtree(temp_dir)
                logger.info("Cleaned up temporary directory after error")
            remove_lock()
            return
        except Exception as e:
            logger.error(f"Error extracting backup file: {e}", exc_info=True)
            print(f"Error extracting backup file: {e}\n")
            if temp_dir.exists():
                safe_rmtree(temp_dir)
                logger.info("Cleaned up temporary directory after error")
            remove_lock()
            return
        if not temp_dir.exists() or not any(temp_dir.iterdir()):
            logger.error(f"Extraction failed or produced empty directory: {temp_dir}")
            print("Error: Failed to extract backup file or backup is empty\n")
            if temp_dir.exists():
                safe_rmtree(temp_dir)
                logger.info("Cleaned up empty temporary directory")
            remove_lock()
            return
        logger.info("Checking extracted content...")
        extracted_items = list(temp_dir.iterdir())
        logger.info(f"Found {len(extracted_items)} items in temporary directory")
        exclude_list = get_exclude_list()
        logger.info(f"Using exclude list with {len(exclude_list)} patterns")
        logger.info(f"Exclude patterns: {exclude_list}")
        logger.info("Starting cleanup of current directory before rollback")
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
        logger.info("Copying extracted files to current directory")
        copied_count = 0
        for item in temp_dir.iterdir():
            dest = BASE_DIR / item.name
            try:
                if item.is_dir():
                    if dest.exists():
                        shutil.rmtree(dest)
                        logger.info(f"Removed existing directory: {dest.name}")
                    shutil.copytree(item, dest, symlinks=True)
                else:
                    shutil.copy2(item, dest)
                copied_count += 1
            except Exception as copy_error:
                logger.error(f"Failed to copy {item.name}: {copy_error}")
        logger.info(f"File copy completed: {copied_count} items copied")
        logger.info("Cleaning up temporary directory")
        try:
            safe_rmtree(temp_dir)
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
                safe_rmtree(temp_dir)
                logger.info("Cleaned up temporary directory after user interrupt")
            except Exception as e:
                logger.error(f"Failed to clean up temporary directory after interrupt: {e}")
    except Exception as e:
        logger.error(f"Error during rollback: {e}", exc_info=True)
        print(f"Error during rollback: {e}")
        traceback.print_exc()
        temp_dir = BASE_DIR / "temp_rollback"
        if temp_dir.exists():
            try:
                safe_rmtree(temp_dir)
                logger.info("Cleaned up temporary directory after error")
            except Exception as cleanup_error:
                logger.error(f"Failed to clean up temporary directory after error: {cleanup_error}")
    finally:
        _unlock_with_logging("rollback")

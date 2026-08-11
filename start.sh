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
import unicodedata
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
SCRIPT_CONFIG_FILE = BASE_DIR / "config" / "script.cfg"
BUNDLES_DIR = BASE_DIR / "bundles"
LANG_DIR = BUNDLES_DIR / "lang"
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
CURRENT_LANG = "en"
LANG_DATA = {}
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

DEFAULT_STRINGS = {
    # Core commands / help
    "core.help.title": "Minecraft Server Management Tool (v{version})",
    "core.help.desc": "A modular command-line tool for managing Minecraft server versions, backups, plugins and other configurations.",
    "core.help.usage": "Usage:",
    "core.help.core": "Core Commands:",
    "core.help.start": "Start the server",
    "core.help.install": "Install or update modules",
    "core.help.info": "Show current server configuration",
    "core.help.version": "Check for script, module and language updates",
    "core.help.lang": "Show or change language",
    "core.help.license": "Show the open source license",
    "core.help.help": "Show this help message",
    "core.help.installed": "Installed Module Commands:",
    "core.help.no_modules": "No modules installed.",
    "core.help.install_hint": 'Use "--install" to choose modules, or "--install all" to install everything.',
    "core.help.not_installed": "Not Installed (available via --install):",
    "core.help.tip_all": 'Tip: "--install all" installs all modules.',
    "core.help.install_available": 'Run "--install" to view and install available modules.',
    # First run / language
    "core.lang.title": "LANGUAGE SELECTION",
    "core.lang.choose": "Choose a language:",
    "core.lang.english": "English (default)",
    "core.lang.downloading": "Downloading language pack '{code}'...",
    "core.lang.download_fail": "Could not download language pack '{code}': {error}",
    "core.lang.set": "Language set to {display}.",
    "core.lang.current": "Current language: {display} ({code})",
    "core.lang.available": "Available languages:",
    "core.lang.unknown": "Unknown language: {code}",
    "core.lang.installed_files": "Language files in bundles/lang/:",
    "core.lang.invalid_choice": "Invalid choice. Please try again.",
    "core.confirm.invalid_yn": "Please enter Y or N.",
    "core.first_run.title": "FIRST RUN - MODULE SETUP",
    "core.first_run.desc1": "This is the first time the script has been used in this directory.",
    "core.first_run.desc2": "No modules are installed yet, so most commands cannot be used.",
    "core.first_run.desc3": "The core script only supports:",
    "core.first_run.desc4": " - starting the server",
    "core.first_run.desc5": " - --info / --license / --help / --version / --lang",
    "core.first_run.desc6": " - installing modules (this flow)",
    "core.first_run.desc7": "After installing modules you get: server initialization, version control, backups, plugins, worlds, crash analysis, players, settings and maintenance.",
    "core.first_run.desc8": "Modules are downloaded from GitHub and verified with MD5 checks.",
    "core.first_run.desc9": 'You can also run \'./start.sh --install all\' later to install everything.',
    # Install flow
    "core.install.canceled": "Installation canceled.",
    "core.install.no_modules": "No modules installed. Run '--install' to set up modules.",
    "core.install.choose_dir": "Choose where to store installed modules:",
    "core.install.dir_shared": "~/.cache/MC-Server-Manager (shared across servers)",
    "core.install.dir_server": "./bundles/modules (this server only)",
    "core.install.dir_custom": "Custom path",
    "core.install.dir_set": "Modules directory set to: {path}",
    "core.install.available": "Available modules:",
    "core.install.select_prompt": "Enter numbers (e.g. '1 2 3'), 'all' for everything, or Enter to cancel.",
    "core.install.selection": "Your selection:",
    "core.install.downloading": "Downloading module '{name}'...",
    "core.install.installed": "Installed '{name}' (version {version}, {size} bytes, {speed:.2f} KB/s)",
    "core.install.already": " - {name}: already installed (version {version})",
    "core.install.all_already": "All selected modules are already installed.",
    "core.install.skipped_deps": "Installation skipped: required dependencies were not confirmed.",
    "core.install.nothing": "Nothing to install.",
    "core.install.finished": "Module installation finished: {installed} installed, {skipped} skipped/failed",
    "core.install.dep_ask": "Install required module '{dep}' too?",
    "core.install.dep_skip": "Skipping '{name}' because required module '{dep}' was not installed.",
    "core.install.dep_required": "Module '{name}' requires: {deps}",
    "core.install.unknown": "Unknown module: {name}",
    "core.install.fetch_fail": "Could not fetch module list: {error}",
    "core.install.network_hint": "Please check your internet connection and try again.",
    "core.install.dir_fail": "Could not create modules directory {path}",
    "core.install.temp_dir_fail": "Could not create temporary directory {path}",
    "core.install.path_empty": "Path cannot be empty.",
    "core.install.your_choice_123": "Your choice (1-3):",
    "core.install.enter_custom_path": "Enter custom path:",
    "core.install.invalid_choice_123": "Invalid choice. Please enter 1, 2, or 3.",
    "core.install.no_modules_available": "No modules are available in update.json.",
    "core.install.no_selection": "No modules selected. Installation canceled.",
    "core.install.modules_dir_error": "Error: Modules directory is not configured.",
    "core.install.no_url": "Error: No download URL for module '{name}'",
    "core.install.md5_failed": "MD5 verification failed for '{name}'!",
    "core.install.md5_expected": "Expected: {md5}",
    "core.install.md5_got": "Got: {md5}",
    "core.install.corrupted": "The downloaded file may be corrupted or tampered with.",
    "core.install.syntax_error": "Error: Module '{name}' failed syntax check: {error}",
    "core.install.download_error": "Error downloading module '{name}': {error}",
    # Module / command errors
    "core.module.missing": "Module '{name}' is not installed.",
    "core.module.install_hint": "Install it with: --install {name}",
    "core.module.required_missing": "Required module '{name}' is not installed.",
    "core.invalid_command": "Invalid command or arguments",
    "core.invalid_use_help": "Use '{script} --help' for usage information",
    "core.unexpected_error": "An unexpected error occurred: {error}",
    "core.check_log": "Check the log file for more details: {log}",
    "core.interrupted": "Script interrupted by user",
    "core.env.exiting": "Exiting script...",
    "core.env.no_device_title": "ENVIRONMENT CHECK - NO DEVICE DATA",
    "core.env.no_device_msg1": "No device identification data found in configuration.",
    "core.env.no_device_msg2": "This might be the first run or the configuration was created with an older version of the script.",
    "core.env.no_device_msg3": "It is recommended to run --init or --init auto to ensure proper environment detection in the future.",
    "core.env.continue_anyway": "Continue anyway? (Y/N)",
    "core.env.limited_title": "LIMITED ENVIRONMENT DETECTION",
    "core.env.limited_msg1": "Note: Running on a system with limited device identification.",
    "core.env.limited_msg2": "Environment change detection is disabled for this session.",
    "core.env.limited_msg3": "If you're experiencing issues, consider running --init again to refresh the configuration.",
    "core.env.continuing": "Continuing with normal operation...",
    "core.env.changed_title": "ENVIRONMENT CHANGE DETECTED",
    "core.env.changed_msg1": "Warning: The running environment has changed!",
    "core.env.changed_msg2": "This script was previously run on a different machine or the system configuration has been modified.",
    "core.env.changed_msg3": "This could indicate:",
    "core.env.changed_item1": " - Running on a different computer",
    "core.env.changed_item2": " - Virtual machine migration",
    "core.env.changed_item3": " - Network/hardware changes",
    "core.env.changed_item4": " - System reinstallation",
    "core.env.changed_msg4": "It is strongly recommended to reconfigure the server for the new environment to avoid potential issues.",
    "core.env.options": "Available options:",
    "core.env.opt_backup_manual": " 1. Backup current configuration and run --init",
    "core.env.opt_backup_auto": " 2. Backup current configuration and run --init auto",
    "core.env.opt_ignore": " 3. Ignore the warning and continue",
    "core.env.opt_exit": " 4. Exit without making any changes",
    "core.env.enter_choice": "Enter your choice (1-4):",
    "core.env.invalid_choice": "Invalid choice. Please enter 1, 2, 3, or 4.",
    "core.env.backed_up": "Configuration backed up to: {path}",
    "core.env.backup_failed": "Warning: Could not backup configuration: {error}",
    "core.env.manual_init": "Running manual initialization...",
    "core.env.auto_init": "Running auto initialization...",
    "core.env.completed": "Environment configuration completed successfully!",
    "core.env.run_again": "Please run the script again to start the server.",
    "core.env.fallback": "Falling back to normal operation...",
    "core.env.device_updated": "Device ID updated to current environment.",
    "core.env.device_warning": "Warning: Could not generate stable device ID: {error}",
    "core.env.check_error": "Error during environment check: {error}",
    "core.env.handle_error": "Error during environment change handling: {error}",
    "core.env.update_error": "Error updating device ID: {error}",
    "core.lock.create_error": "Error creating lock file: {error}",
    "core.lock.remove_error": "Error removing lock file: {error}",
    "core.lock.read_error": "Error reading lock file: {error}",
    "core.compare_error": "Error comparing versions: {error}",
    "core.install.registry_error": "Error: Could not save module registry: {error}",
    "core.install.dir_create_error": "Error: Could not create modules directory {path}",
    "core.install.fetch_error": "Error: Could not fetch module list: {error}",
    "core.install.unknown_modules": "Unknown module(s): {names}",
    "core.install.available_modules": "Available modules: {names}",
    "core.module.load_error": "Error: Failed to load module '{name}': {error}",
    "core.module.reinstall_hint": "Try reinstalling it with: --install {name}",
    "core.pending.duplicate_title": "DUPLICATE INSTANCE DETECTED",
    "core.pending.another_running": "Another instance of the script is already running:",
    "core.pending.wait": "Please wait for the current operation to complete.",
    "core.pending.options": "You have the following options:",
    "core.pending.quit": " Q - Quit this instance",
    "core.pending.force": " F - Force clear the lock and continue",
    "core.pending.force_warn": "Forcing may cause data corruption if the other instance is actively modifying server files!",
    "core.pending.force_confirm": "Are you sure? This may cause DATA CORRUPTION! (y/N)",
    "core.pending.q_f_prompt": "Enter your choice (Q/F):",
    "core.pending.q_f": "Please enter Q or F.",
    "core.pending.pending_title": "PENDING TASK DETECTED",
    "core.pending.interrupted": "Previous command was interrupted:",
    "core.pending.prompt": "Enter your choice (Y/N/Q):",
    "core.pending.ynq": "Please enter Y, N, or Q.",
    "core.pending.multiple": "You cannot run multiple instances simultaneously.",
    "core.pending.terminated": "The script was terminated unexpectedly during this operation.",
    "core.pending.y": "Y - Continue with the pending task",
    "core.pending.n": "N - Clear the pending task",
    "core.pending.q": "Q - Quit the script without making any changes",
    "core.pending.never_y": "You should NEVER choose 'Y' if you left the workspace unchecked!",
    "core.pending.resuming": "Resuming pending task...",
    "core.pending.clearing": "Clearing pending task...",
    "core.pending.exiting_no_changes": "Exiting script without any changes...",
    "core.pending.force_clearing": "Force clearing lock and continuing...",
    "core.eula.created": "EULA file not found. Created and accepted EULA automatically.",
    "core.eula.agree": "By using this server, you agree to Mojang's EULA (https://aka.ms/MinecraftEULA)",
    "core.eula.accepted": "EULA not accepted. Automatically accepted EULA.",
    "core.eula.error": "Error reading EULA file: {error}",
    "core.eula.update_error": "Error updating EULA file: {error}",
    "core.config.init_required": "Please run with --init to create a new configuration",
    "core.config.invalid_format": "Error: Invalid configuration format",
    "core.config.critical_missing": "Required parameters: version, max_ram, java_path",
    "core.config.fix_init": "Please run with --init to fix the configuration first.",
    "core.config.optional_missing": "The server will start, but some features may not work properly.",
    "core.config.complete_init": "Consider running --init to complete the configuration.",
    "core.config.manual_eula": "Please manually check and accept the EULA in eula.txt",
    "core.config.not_found_path": "Error: Configuration file not found at {path}",
    "core.config.missing_corrupted": "Error: Configuration file is missing or corrupted!",
    "core.config.critical_missing2": "Error: Critical configuration parameters are missing!",
    "core.config.optional_warning": "Warning: Some optional configuration parameters are missing.",
    "core.start.banner": "Starting Minecraft server...",
    "core.start.command": "Command:",
    "core.start.checking_requirements": "Checking server requirements...",
    "core.start.checking_issues": "Checking for potential issues that caused the interrupt...",
    "core.start.crash_hint": 'Use "--install crash" to enable crash reports.',
    "core.start.java_missing": "Error: Java executable not found at {path}",
    "core.start.jar_missing": "Error: Server JAR not found at {path}",
    "core.start.uptime": "Server uptime: {uptime}",
    "core.start.uptime_seconds": "Server uptime: {uptime} (or {seconds} seconds)",
    "core.start.start_error": "Error starting server: {error}",
    "core.start.requirements_failed": "Server requirements check failed. Please fix the issues above.",
    "core.start.eula_failed": "Failed to accept EULA. Server cannot start without accepting Mojang's EULA.",
    "core.start.shutdown": "Server shutdown requested by user (KeyboardInterrupt).",
    "core.start.stopped_normal": "Server stopped normally.",
    "core.start.stopped_warnings": "Server stopped normally (with warnings).",
    "core.start.interrupted": "Server interrupted by user.",
    "core.start.interrupted_clean": "Server interrupted by user (no issues detected in logs).",
    "core.start.crash_module_missing": "Crash analysis module is not installed.",
    "core.license.title": "License Information",
    "core.license.fetching": "Fetching license...",
    "core.license.current": "Current license:",
    "core.license.http_error": "Error: Could not fetch license - HTTP {code}",
    "core.license.http_hint": "The license file may not be available at the moment.",
    "core.license.network_error": "Error: Could not connect to server - {error}",
    "core.license.network_hint": "Please check your internet connection and try again.",
    "core.license.timeout": "Error: Connection timeout while fetching license",
    "core.license.timeout_hint": "The request took too long. Please check your internet connection and try again.",
    "core.license.error": "Error: Failed to retrieve license - {error}",
    "core.info.title": "Server Configuration:",
    "core.info.version": "Minecraft Version: {version}",
    "core.info.ram": "Max RAM: {ram}",
    "core.info.java": "Java Path: {path}",
    "core.info.exclusions": "Additional Exclusions: {list}",
    "core.info.params": "Additional Parameters: {params}",
    "core.info.error": "Error loading configuration: {error}",
    # Update check
    "core.update.title": "Self Update Check",
    "core.update.current": "Current script version: {version}",
    "core.update.latest": "Latest version available: {version} (Released: {date})",
    "core.update.core_uptodate": "Core script is up to date.",
    "core.update.core_new": "New version {version} is available!",
    "core.update.core_ask": "Do you want to download and update the core script? (y/N)",
    "core.update.modules_check": "Checking installed modules...",
    "core.update.modules_none": "No modules installed. Nothing to update.",
    "core.update.modules_uptodate": "All installed modules are up to date.",
    "core.update.modules_available": "Updates available for installed modules:",
    "core.update.modules_ask": "Update these modules now? (y/N)",
    "core.update.languages_check": "Checking language files...",
    "core.update.languages_none": "No language files installed. Nothing to update.",
    "core.update.languages_uptodate": "Language files are up to date.",
    "core.update.languages_available": "Updates available for language files:",
    "core.update.languages_ask": "Update language files now? (y/N)",
    "core.update.force_bypass": "Force mode: core update check bypassed.",
    "core.update.core_canceled": "Core update canceled.",
    "core.update.downloading_core": "Downloading latest version from: {url}",
    "core.update.download_started": "Download started...",
    "core.update.download_completed": "Download completed in {time} seconds.",
    "core.update.download_speed": "Download speed: {speed:.2f} KB/s",
    "core.update.verifying": "Verifying file integrity",
    "core.update.md5_failed": "MD5 verification failed",
    "core.update.expected": "Expected: {md5}",
    "core.update.got": "Got: {md5}",
    "core.update.corrupted": "The downloaded file may be corrupted or tampered with.",
    "core.update.aborted_security": "Update aborted for security reasons.",
    "core.update.md5_passed": "MD5 verification passed.",
    "core.update.backup_created": "Backup created: {path}",
    "core.update.backup_warning": "Warning: Could not create backup: {error}",
    "core.update.chmod_warning": "Warning: Could not set executable permissions: {error}",
    "core.update.update_completed": "Update completed successfully!",
    "core.update.updated_version": "Script has been updated to version {version}.",
    "core.update.run_again": "Please run the script again to use the new version.",
    "core.update.replace_failed": "Failed to replace the current script: {error}",
    "core.update.replace_hint": "This is usually due to file permission issues or the script being in use.",
    "core.update.manual_title": "Manual replacement required:",
    "core.update.manual_windows": "Please perform the following steps manually:",
    "core.update.manual_delete": " 1. Delete the current script: {path}",
    "core.update.manual_rename": " 2. Rename '{new}' to '{name}'",
    "core.update.manual_cmds": "Please run these commands manually:",
    "core.update.manual_rm": "  rm '{path}'",
    "core.update.manual_mv": "  mv '{new}' '{path}'",
    "core.update.manual_chmod": "  chmod +x '{path}'",
    "core.update.process_error": "Error during update process: {error}",
    "core.update.fetch_error": "Error: Could not check for updates - {error}",
    "core.update.modules_canceled": "Module updates canceled.",
    "core.update.languages_canceled": "Language updates canceled.",
    "core.update.removed_from_list": " - {name}: no longer listed in update.json",
    # Module command descriptions
    "cmd.init": "Initialize new server configuration",
    "cmd.init.auto": "Automatic configuration with intelligent defaults",
    "cmd.standardize": "Migrate an existing server into the managed structure",
    "cmd.get": "Fetch Purpur server info and download",
    "cmd.list": "List all available versions",
    "cmd.new": "Save current server and create a new one",
    "cmd.change": "Switch to specified version",
    "cmd.upgrade": "Upgrade server core to compatible version",
    "cmd.delete": "Delete specified version from bundles",
    "cmd.save": "Save current server as a named version",
    "cmd.backup": "Create a timestamped backup",
    "cmd.rollback": "Rollback to a previous backup",
    "cmd.plugins": "Manage plugins with dependency awareness",
    "cmd.plugins.analyze": "Analyze and display plugin dependency tree",
    "cmd.worlds": "Manage worlds (delete, backup, import, seed)",
    "cmd.players": "Manage banned players, IPs, and whitelist",
    "cmd.settings": "Edit server properties and settings",
    "cmd.cleanup": "Clean up server files to free up space",
    "cmd.dump": "Create a compressed dump of log files",
    "cmd.crash": "Crash detection and reports",
    # Settings module
    "settings.title": "Server Configuration Editor",
    "settings.error_not_found": "Error: server.properties file not found!",
    "settings.hint_start": "Please start the server at least once to generate the file.",
    "settings.read_error": "Error reading server.properties: {error}",
    "settings.table_title": "Server Configuration",
    "settings.col_setting": "Settings",
    "settings.col_value": "Value",
    "settings.empty": "(empty)",
    "settings.prompt_number": "Enter a number to edit settings (or press Enter to exit)",
    "settings.your_choice": "Your choice:",
    "settings.exiting": "Exiting configuration editor.",
    "settings.invalid_selection": "Invalid selection. Please choose a valid number.",
    "settings.editing": "Editing: {name}",
    "settings.description": "Description: {description}",
    "settings.current_value": "Current value: {value}",
    "settings.options": "Options:",
    "settings.enable": "Enable (true)",
    "settings.disable": "Disable (false)",
    "settings.select_option": "Select option (1/2):",
    "settings.cancelled": "Cancelled editing.",
    "settings.invalid_choice_12": "Invalid choice. Please enter 1 or 2.",
    "settings.set_to": " - {name} set to: {value}",
    "settings.valid_range": "Valid range: {min} - {max}",
    "settings.enter_value": "Enter new value:",
    "settings.value_out_of_range": "Value must be between {min} and {max}.",
    "settings.enter_number": "Please enter a valid number.",
    "settings.available_options": "Available options:",
    "settings.select_option_prompt": "Select option:",
    "settings.enter_new_value": "Enter new value:",
    "settings.enter_number_between": "Please enter a number between 1 and {max}",
    "settings.saved": "Configuration saved successfully!",
    "settings.save_error": "Error saving configuration: {error}",
    "settings.operation_cancelled": "Operation cancelled by user.",
    "settings.unexpected": "Unexpected error: {error}",
    "settings.simulation_also": " - simulation-distance also set to: {value}",
    "settings.name.online-mode": "Online Mode",
    "settings.name.white-list": "Whitelist",
    "settings.name.enable-command-block": "Command Blocks",
    "settings.name.allow-flight": "Allow Flight",
    "settings.name.hardcore": "Hardcore Mode",
    "settings.name.pvp": "PVP",
    "settings.name.server-port": "Server Port",
    "settings.name.op-permission-level": "OP Permission Level",
    "settings.name.function-permission-level": "Function Permission Level",
    "settings.name.max-players": "Max Players",
    "settings.name.view-distance": "View Distance",
    "settings.name.difficulty": "Difficulty",
    "settings.name.level-seed": "World Seed",
    "settings.name.motd": "MOTD",
    "settings.desc.online-mode": "Verify player authentication with Mojang",
    "settings.desc.white-list": "Enable whitelist to restrict server access",
    "settings.desc.enable-command-block": "Enable command blocks in the world",
    "settings.desc.allow-flight": "Allow players to fly in survival mode",
    "settings.desc.hardcore": "Enable hardcore mode (permanent death)",
    "settings.desc.pvp": "Allow player vs player combat",
    "settings.desc.server-port": "The port the server will listen on",
    "settings.desc.op-permission-level": "Permission level for server operators",
    "settings.desc.function-permission-level": "Permission level for functions",
    "settings.desc.max-players": "Maximum number of players allowed",
    "settings.desc.view-distance": "Maximum view distance in chunks",
    "settings.desc.difficulty": "Game difficulty level",
    "settings.desc.level-seed": "Seed for world generation",
    "settings.desc.motd": "Server description shown in server list",
    # Players module
    "players.title": "Player List Management",
    "players.select_list": "Select list to manage:",
    "players.opt_banned_players": "Banned Players (banned-players.json)",
    "players.opt_banned_ips": "Banned IPs (banned-ips.json)",
    "players.opt_whitelist": "Whitelist (whitelist.json)",
    "players.choose_prompt": "Enter your choice (1-3) or press Enter to exit:",
    "players.invalid_choice": "Invalid choice.",
    "players.available_ops": "Available operations:",
    "players.add_entry": "A - Add new entry",
    "players.delete_entry": "D - Delete existing entry",
    "players.op_prompt": "Enter operation (A/D) or press Enter to exit:",
    "players.no_entries": "No entries to delete.",
    "players.invalid_op": "Invalid operation.",
    "players.enter_number": "Invalid input. Please enter a number.",
    "players.empty_list": "{list} is empty. Nothing to delete.",
    "players.deleting_from": "Deleting from {list}",
    "players.delete_selection": "Enter the number(s) to delete (space-separated):",
    "players.op_cancelled": "Operation cancelled.",
    "players.no_valid_numbers": "No valid numbers selected.",
    "players.will_delete": "The following entries will be deleted:",
    "players.are_you_sure": "Are you sure? (y/N)",
    "players.deletion_cancelled": "Deletion cancelled.",
    "players.deleted_count": "Successfully deleted {count} entries from {list}!",
    "players.enter_numbers": "Invalid input. Please enter numbers separated by spaces.",
    "players.delete_error": "Error deleting from {list}: {error}",
    "players.adding_to": "Adding to {list}",
    "players.enter_ip": "Enter IP address to ban:",
    "players.invalid_ip": "Invalid IP address format. Please try again.",
    "players.ban_reason": "Enter ban reason (optional):",
    "players.default_reason": "Banned by an operator.",
    "players.offline_warning1": "WARNING: Server is in offline mode (online-mode=false).",
    "players.offline_warning2": "UUIDs for offline players are generated locally and may differ from other servers.",
    "players.offline_warning3": "This means the same username may have a different UUID on other servers.",
    "players.offline_ask": "Do you want to continue using offline UUIDs? (y/N)",
    "players.enter_username": "Enter player username:",
    "players.username_too_long": "Username too long (max 16 characters). Please try again.",
    "players.generated": "Generated: {name} -> {uuid}",
    "players.fetching_uuid": "Fetching UUID for {name}",
    "players.fetch_failed": "Error: Could not fetch UUID for '{name}'.",
    "players.check_username": "Please check the username and try again.",
    "players.found": "Found: {name} -> {uuid}",
    "players.internal_error": "Internal error: could not obtain valid player information.",
    "players.added_success": "Successfully added to {list}!",
    "players.save_error": "Error saving {list}: {error}",
    "players.table_banned_ips": "                          - Banned IPs -",
    "players.table_banned_players": "                        - Banned Players -",
    "players.table_whitelist": "                          - Whitelist -",
    "players.table_banned_ips_empty": "                          - Banned IPs -\n╔═════════════════════════════════════════════════════════════╗\n║                                                             ║\n║                      No banned IPs found.                   ║\n║                                                             ║\n╚═════════════════════════════════════════════════════════════╝",
    "players.table_banned_players_empty": "                        - Banned Players -\n╔════════════════════════════════════════════════════════════════╗\n║                                                                ║\n║                    No banned players found.                    ║\n║                                                                ║\n╚════════════════════════════════════════════════════════════════╝",
    "players.table_whitelist_empty": "                          - Whitelist -    \n╔════════════════════════════════════════════════════════════════╗\n║                                                                ║\n║                 No whitelisted players found.                  ║\n║                                                                ║\n╚════════════════════════════════════════════════════════════════╝",
    "players.col_ip": "IP Address",
    "players.col_reason": "Reason",
    "players.col_name": "Player Name",
    "players.col_uuid": "UUID",
    "players.properties_error": "Error reading server.properties: {error}",
    # Maintenance module
    "maintenance.lock_error": "Error: Could not create task lock",
    "maintenance.preparing": "Preparing to clean up server files",
    "maintenance.nothing_clean": "No files to clean up found.",
    "maintenance.will_delete": "The following files will be deleted:",
    "maintenance.total_free": "Total space to free: {size} bytes (~{mb} MB)",
    "maintenance.confirm_delete": "Are you sure you want to delete these files? (y/N)",
    "maintenance.canceled": "Cleanup canceled.",
    "maintenance.deleted": "Deleted: {path}",
    "maintenance.delete_error": "Error deleting {path}: {error}",
    "maintenance.completed": "Cleanup completed. Deleted {count} files, freed {size} bytes (~{mb} MB).",
    "maintenance.no_logs": "No log files found to dump.",
    "maintenance.search_title": "Log Search Utility",
    "maintenance.searching_for": "Searching for: {terms} (case-insensitive)",
    "maintenance.found_matches": "Found {count} matches in: {path}",
    "maintenance.process_error": "Error processing {path}: {error}",
    "maintenance.dumped_files": "Dumped {count} log files.",
    "maintenance.found_lines": "Found {lines} matching lines in {files} files.",
    "maintenance.result_saved": "Result saved to: {name}",
    "maintenance.file_size": "File size: {size} bytes (~{mb} MB)",
    "maintenance.delete_originals": "Do you want to delete the original log files? (y/N)",
    "maintenance.deleted_logs": "Deleted {count} log files, freed {size} bytes.",
    "maintenance.delete_log_error": "Error deleting {path}: {error}",
    "maintenance.no_match": "No matching content found in any log files.",
    "maintenance.dump_error": "Error creating log dump: {error}",
    "maintenance.dump_title": "Log Dump Utility",
    "maintenance.creating_dump": "Creating complete log dump",
    # Backup module
    "backup.usage_save": "Usage: --save <version>",
    "backup.lock_error": "Error: Could not create task lock",
    "backup.config_warning": "Warning: Could not load config, using default version 'unknown'",
    "backup.saving_as": "Saving current version ({current}) as {version}",
    "backup.saved": "Version {version} saved successfully to {path}",
    "backup.error_saving": "Error saving version: {error}",
    "backup.config_error": "Error: Could not load configuration to determine current version",
    "backup.creating_backup": "Creating backup of current version ({version})",
    "backup.backup_created": "Backup created successfully: {path}",
    "backup.error_backup": "Error creating backup: {error}",
    "backup.no_backups": "No backups found for version {version}",
    "backup.no_backup_files": "No backup files found for version {version}",
    "backup.available": "Available Backups:",
    "backup.no_selection": "No selection made.",
    "backup.invalid_selection": "Invalid selection.",
    "backup.selected": "Selected file: {name}",
    "backup.rolling": "Rolling back now, please wait",
    "backup.bad_zip": "Error: The backup file appears to be corrupted or not a valid ZIP archive",
    "backup.extract_error": "Error extracting backup file: {error}",
    "backup.empty_backup": "Error: Failed to extract backup file or backup is empty",
    "backup.rollback_success": "Server rollbacked successfully",
    "backup.invalid_input": "Invalid input. Please enter a number.",
    "backup.interrupted": "Rollback interrupted by user.",
    "backup.rollback_error": "Error during rollback: {error}",
    "backup.select_prompt": "Please select one to rollback:",
    # Worlds module
    "worlds.invalid_arg": "Invalid argument for --worlds: {mode}",
    "worlds.invalid_arg_hint": "Available arguments: import, delete, backup",
    "worlds.lock_error": "Error: Could not create task lock",
    "worlds.title": "World Management Utility",
    "worlds.read_error": "Error reading {name}: {error}",
    "worlds.table_title": "Existing Worlds",
    "worlds.col_worlds": "Worlds",
    "worlds.col_size": "Size",
    "worlds.col_status": "Status",
    "worlds.all": "All",
    "worlds.all_worlds": "All Worlds",
    "worlds.no_worlds": "No worlds found.",
    "worlds.none": "N/A",
    "worlds.no_delete": "No world folders found. Nothing to delete.",
    "worlds.no_backup": "No world folders found. Nothing to backup.",
    "worlds.operations": "Available operations:",
    "worlds.op_delete": "Delete worlds",
    "worlds.op_backup": "Backup worlds",
    "worlds.op_import": "Import worlds",
    "worlds.op_seed": "Configure world seed",
    "worlds.select_op": "Select operation (1-4):",
    "worlds.no_op": "No operation selected. Operation canceled.",
    "worlds.invalid_op": "Invalid operation selection.",
    "worlds.cancelled": "Operation canceled by user.",
    "worlds.op_error": "Error during world operation: {error}",
    "worlds.no_selection": "No selection made. Operation canceled.",
    "worlds.select_delete": "Select world folders to delete (space-separated numbers, 0 for all):",
    "worlds.invalid_number": "Invalid number: {num}",
    "worlds.invalid_input": "Invalid input: {value}",
    "worlds.confirm_delete_all": "Are you sure you want to delete ALL world folders?\nThis cannot be undone!",
    "worlds.confirm_delete": "Are you sure you want to delete these world(s)?\nThis cannot be undone!",
    "worlds.deleted": "Deleted: {name}",
    "worlds.delete_error": "Error deleting {name}: {error}",
    "worlds.all_deleted": "All world folders deleted successfully.",
    "worlds.deleted_count": "Deleted {count} worlds, freed {size}",
    "worlds.selected_delete": "You have selected the following world(s) to delete:",
    "worlds.deleted_selected": "Selected world(s) deleted successfully.",
    "worlds.deleted_selected_count": "Deleted {count} worlds, freed {size}",
    "worlds.after_delete_seed": "All world folders have been removed.\nDo you want to configure a new world seed now?",
    "worlds.skip_seed": "Skipped seed configuration.",
    "worlds.skip_seed_remain": "Some world folders remain. Skipping seed configuration.",
    "worlds.config_error_backup": "Error: Could not determine current server version for backup.",
    "worlds.select_backup": "Select world folders to backup (space-separated numbers, 0 for all):",
    "worlds.selected_all": "You have selected ALL worlds to backup:",
    "worlds.selected_list": "You have selected the following world(s) to backup:",
    "worlds.confirm_backup": "Proceed with backup?",
    "worlds.backup_path": "Creating backup: {path}",
    "worlds.warn_missing": "Warning: World folder {name} does not exist, skipping.",
    "worlds.adding": "Adding: {name}",
    "worlds.backup_success": "Backup created successfully: {path}",
    "worlds.file_size": "File size: {size}",
    "worlds.worlds_backed": "Worlds backed up: {count}",
    "worlds.backup_error": "Error creating backup: {error}",
    "worlds.import_title": "World Import Utility",
    "worlds.enter_zip": "Enter the path to the world backup ZIP file:",
    "worlds.file_not_found": "Error: File not found: {path}",
    "worlds.not_zip": "Error: File must be a ZIP archive.",
    "worlds.reading": "Reading archive: {name}",
    "worlds.no_valid_worlds": "Error: No valid worlds found in the archive.",
    "worlds.valid_hint": "A valid world must contain a level.dat file.",
    "worlds.found_worlds": "Found {count} world(s) in archive:",
    "worlds.existing_warning": "Warning: The following worlds already exist:",
    "worlds.replace_ask": "Replace existing worlds?",
    "worlds.import_canceled": "Import canceled.",
    "worlds.removed": "Removed existing world: {name}",
    "worlds.remove_error": "Error removing {name}: {error}",
    "worlds.extracting": "Extracting worlds.",
    "worlds.imported": " - Imported: {name} ({size})",
    "worlds.invalid_world": " - Invalid world (missing level.dat): {name}",
    "worlds.import_success": "Successfully imported {count} world(s).",
    "worlds.import_error": "Error importing world: {error}",
    "worlds.seed_not_found": "Server properties file not found. Creating default...",
    "worlds.seed_options": "To generate new worlds, there are 3 options for the seed:",
    "worlds.keep_seed": "Keep the current seed",
    "worlds.random_seed": "Use a random seed",
    "worlds.custom_seed": "Set a custom seed",
    "worlds.your_option": "Your option (1-3):",
    "worlds.keeping": "Keeping current seed",
    "worlds.random": "Using random seed",
    "worlds.enter_seed": "Enter your seed:",
    "worlds.seed_set": "Seed set to: {seed}",
    "worlds.seed_empty": "Seed cannot be empty. Please try again.",
    "worlds.seed_invalid": "Invalid option. Please choose 1, 2, or 3.",
    "worlds.seed_cancelled": "Operation canceled.",
    "worlds.seed_success": "Successfully configured world seed.",
    "worlds.seed_future": "New worlds will be generated with the specified seed when server starts.",
    "worlds.seed_error": "Error saving world seed configuration: {error}",
    # Plugins module
    "plugins.yaml_required": "Error: PyYAML is required by the plugins module.",
    "plugins.yaml_install": "Please install it with: pip install PyYAML",
    "plugins.dir_not_found": "Plugins directory not found",
    "plugins.none_found": "No plugins found",
    "plugins.table_title": "Plugins Management",
    "plugins.col_name": "Plugins",
    "plugins.col_version": "Version",
    "plugins.col_status": "Status",
    "plugins.enabled": "Enabled",
    "plugins.disabled": "Disabled",
    "plugins.toggle_ask": "Do you want to toggle these plugins?",
    "plugins.toggle_numbers": "Enter the numbers of the plugin you want to toggle (e.g., '1 2 3'):",
    "plugins.no_selection": "No plugins selected.",
    "plugins.no_valid_numbers": "No valid plugin numbers selected.",
    "plugins.enabled_one": "Enabled: {name}",
    "plugins.enable_error": "Error enabling {name}: {error}",
    "plugins.multiple_options": "You have multiple options:",
    "plugins.opt_manual": "Disable the dependent plugins first, then disable this one",
    "plugins.opt_force": "Force disable this plugin anyway (RISKY)",
    "plugins.opt_auto": "Disable the whole plugin chain for me (AUTOMATIC)",
    "plugins.disable_dependents_first": "Please disable the dependent plugins first:",
    "plugins.then_retry": "Then try disabling this plugin again.",
    "plugins.force_disabled": "Force disabled: {name}",
    "plugins.force_error": "Error force disabling {name}: {error}",
    "plugins.auto_disabled": "Automatically disabled the following plugins:",
    "plugins.soft_not_auto": "Note: The following plugins have soft dependencies and were NOT automatically disabled:",
    "plugins.may_lose": "These plugins may lose some functionality but should still work.",
    "plugins.cancelled_disable": "Cancelled disabling: {name}",
    "plugins.invalid_choice": "Invalid choice. Please enter 1, 2, 3, or C.",
    "plugins.disabled_one": "Disabled: {name}",
    "plugins.disable_error": "Error disabling {name}: {error}",
    "plugins.skipped": "Skipped: {name}",
    "plugins.states_changed": "Plugin states changed successfully",
    "plugins.invalid_input": "Invalid input. Please enter numbers separated by spaces.",
    "plugins.toggle_error": "Error toggling plugins: {error}",
    "plugins.queued": "Queued for disabling (hard dependency): {name}",
    "plugins.analyze_title": "Plugin Dependency Analysis",
    "plugins.soft_missing": "Plugin '{name}' requires following soft dependencies but not installed:",
    "plugins.soft_disabled": "Plugin '{name}' requires following soft dependencies but not enabled:",
    "plugins.hard_missing": "Plugin '{name}' requires following hard dependencies but not installed:",
    "plugins.hard_disabled": "Plugin '{name}' requires following hard dependencies but not enabled:",
    "plugins.all_satisfied": "All plugin dependencies are satisfied!",
    "plugins.no_issues": "No missing or disabled dependencies found.",
    "plugins.disabled_list": "Currently Disabled Plugins:",
    "plugins.ignore_soft": "You can ignore soft dependencies if not critical.",
    "plugins.never_ignore_hard": "You should never ignore missing hard dependencies",
    "plugins.statistics": "Statistics:",
    "plugins.total": "Total plugins: {count}",
    "plugins.enabled_count": "Enabled plugins: {count}",
    "plugins.disabled_count": "Disabled plugins: {count}",
    "plugins.hard_total": "Total hard dependencies: {count}",
    "plugins.soft_total": "Total soft dependencies: {count}",
    "plugins.dir_missing": "Plugins directory not found.",
    "plugins.no_plugins_disable": "No plugins found to disable.",
    "plugins.disable_error_file": "Error disabling {name}: {error}",
    "plugins.disabled_count_result": "Successfully disabled {count} plugins.",
    "plugins.choose_option": "Choose option (1/2/3) or 'C' to cancel:",
    "plugins.force_confirm": "Are you sure?\nThis may break other plugins or crash the server!",
    "plugins.disable_confirm": "Do you still want to disable {name}?",
    # Crash module
    "crash.potential": "POTENTIAL CRASH DETECTED FROM LOGS",
    "crash.detected": "CRASH DETECTED",
    "crash.exit_code": "Exit Code: {code}",
    "crash.uptime": "Server Uptime: {uptime}",
    "crash.uptime_seconds": "Server Uptime: {uptime} (or {seconds} seconds)",
    "crash.crash_time": "Crash Time: {time}",
    "crash.log_file": "Log File: {path}",
    "crash.report_file": "Report File: {path}",
    "crash.potential_note": "Note: This is a potential crash detected from log analysis.",
    "crash.potential_note2": "The server exited with code 0 but showed error indicators.",
    "crash.check_report": "Please check the crash report for details about the server crash.",
    "crash.completed": "Crash analysis completed in {time}s!",
    "crash.read_log_warning": "Warning: Could not read log file: {error}",
    "crash.dep_error": "Error analyzing dependencies for {name}: {error}",
    "crash.dep_analysis_error": "Error in plugin dependency analysis: {error}",
    "crash.write_report_error": "Error writing crash report: {error}",
    "crash.generate_report_error": "Error generating crash report: {error}",
    "crash.read_log_error": "Error reading log file: {error}",
    "crash.possible_title": "POSSIBLE CRASH DETECTED IN LOGS",
    "crash.possible_warning1": "Warning: The server exited normally (return code 0),",
    "crash.possible_warning2": "but potential crash/error indicators were found in the logs.",
    "crash.could_indicate": "This could indicate:",
    "crash.indicate_oom": " - Out of memory issues",
    "crash.indicate_plugin": " - Plugin conflicts or errors",
    "crash.indicate_world": " - World corruption",
    "crash.indicate_other": " - Other runtime problems",
    "crash.analyze_ask": "Do you want to analyze the logs for potential issues?",
    "crash.analyze_yes": " Y - Yes, analyze the logs and generate a crash report",
    "crash.analyze_no": " N - No, ignore the warnings and exit normally",
    "crash.analyze_no_interrupt": " N - No, this was an intentional interrupt",
    "crash.continuing": "Continuing without analysis",
    "crash.enter_yn": "Please enter Y or N.",
    "crash.interrupted_title": "SERVER INTERRUPTED - POTENTIAL ISSUES DETECTED",
    "crash.interrupt_time": "Interrupt Time: {time}",
    "crash.interrupt_warning1": "The server was interrupted by user (CTRL+C),",
    "crash.interrupt_warning2": "but potential issues were detected in the logs.",
    "crash.indicate_hang": " - Server was unresponsive and required force quit",
    "crash.indicate_memory": " - Memory issues causing server to hang",
    "crash.indicate_shutdown": " - Plugin conflicts preventing normal shutdown",
    "crash.indicate_world_load": " - World corruption or loading problems",
    "crash.enter_choice": "Enter your choice (y/N):",
    # Init module
    "init.title": "Minecraft Server Initialization",
    "init.title_auto": "Automatic Server Initialization",
    "init.standardize_title": "Server Structure Standardizer",
    "init.config_exists": "Configuration file already exists!",
    "init.config_will_replace": "This will replace your current configuration.",
    "init.config_preserved": "Operation canceled. Existing configuration preserved.",
    "init.checking_cores": "Checking for server core files",
    "init.core_exists": "core.jar already exists. Skipping core detection.",
    "init.no_jars": "No JAR files found in current directory.",
    "init.found_core": "Found valid server core: {name} (Version: {version})",
    "init.skipping_core": "Skipping {name}: Not a valid server core ({error})",
    "init.core_error": "Error checking {name}: {error}",
    "init.no_valid_cores": "No valid server cores found in JAR files.",
    "init.using_only_core": "Using the only valid server core: {name}",
    "init.copied_core": "Copied {name} to core.jar",
    "init.auto_selected": "Auto-selected highest version: {name} (Version: {version})",
    "init.auto_select_error": "Error: Could not auto-select a server core.",
    "init.multiple_cores": "Detected multiple server cores in current directory:",
    "init.selected_newest": "Selected newest version: {name} (Version: {version})",
    "init.newest_error": "Error: Could not determine newest version.",
    "init.selected_core": "Selected: {name} (Version: {version})",
    "init.enter_number_between": "Please enter a number between 1 and {max}",
    "init.valid_number_blank": "Please enter a valid number or leave blank for newest.",
    "init.select_core_error": "Error selecting server core: {error}",
    "init.select_failed": "Failed to select server core. Please check your JAR files.",
    "init.no_valid_core_manual": "No valid server cores found.",
    "init.jar_hint": "Please make sure you have server JAR files in the current directory.",
    "init.auto_jar_hint": "The JAR files should contain a version.json file to be recognized as server cores.",
    "init.using_version": "Using version: {version}",
    "init.detected_version": "Detected server version: {version}",
    "init.invalid_version": "Invalid version format. Use format like 1.21.5 or 1.21",
    "init.converted_gb": "Converted {gb} GB to {mb} MB",
    "init.low_ram_warning": "Warning: Allocating less than 512MB may cause server instability!",
    "init.invalid_ram": "Invalid RAM size. Must be a positive integer",
    "init.allocated_ram": "Allocated RAM: {mb} MB ({gb:.1f} GB)",
    "init.additional_exclude": "You can add additional files/directories to exclude from backups.",
    "init.exclude_hint": "These will be added to the base exclusion list.",
    "init.no_java": "Error: No Java installations found! Please install Java first.",
    "init.no_path": "No path entered. Please try again.",
    "init.validating_java": "Validating Java",
    "init.validated": "Validated successfully.",
    "init.invalid_java": "Invalid Java path or Java not found. Please check the path and try again.",
    "init.java_hint2": "Make sure the path points to a valid Java installation.",
    "init.invalid_selection": "Invalid selection.",
    "init.enter_number": "Please enter a number.",
    "init.additional_params": "You can add additional server parameters (e.g., -nogui, --force-upgrade, etc.)",
    "init.params_hint": "These will be appended after the default parameters.",
    "init.config_saved": "Configuration saved to {path}",
    "init.save_error": "Error saving configuration: {error}",
    "init.auto_overwrite": "Configuration file already exists. Overwriting",
    "init.auto_select_failed": "Failed to auto-select server core.",
    "init.using_detected": "Using detected version from core.jar: {version}",
    "init.cannot_detect": "Could not detect version from core.jar, using: {version}",
    "init.required_java": "Required Java version: {java}",
    "init.no_java_auto": "No Java installations found",
    "init.invalid_path_auto": "Invalid path. Try again.",
    "init.exiting_auto": "Exiting auto initialization.",
    "init.no_suitable_java": "No suitable Java version found up to Java {version}.",
    "init.detecting_memory": "Detecting available memory",
    "init.running_container": " - Running in container environment",
    "init.total_memory": "Total available memory: {mb:.0f} MB ({gb:.1f} GB)",
    "init.low_memory_error": "ERROR: Available memory is less than 512MB.",
    "init.low_memory_hint": "The server will likely crash due to insufficient memory.",
    "init.manual_init_hint": "Please use manual initialization (--init) to allocate memory carefully.",
    "init.base_allocation": "Base allocation: {mb} MB",
    "init.analyzing_plugins": "Analyzing {count} enabled plugins:",
    "init.plugins_allocation": "Total plugins allocation: {mb} MB",
    "init.player_details": "Player allocation details:",
    "init.estimated_players": " - Estimated players: {count}",
    "init.view_distance": " - View distance: {distance}",
    "init.multiplier": " - Multiplier: {multiplier}",
    "init.players_allocation": " - Total allocation: {mb:.1f} MB",
    "init.breakdown": "Memory allocation breakdown:",
    "init.base": " - Base: {mb} MB",
    "init.plugins": " - Plugins: {mb} MB",
    "init.players": " - Players: {mb:.1f} MB",
    "init.total": " - Total: {mb:.1f} MB",
    "init.final_ram": "Final allocated RAM: {mb} MB ({gb:.1f} GB)",
    "init.auto_saved": "Auto configuration saved to {path}",
    "init.auto_completed": "Auto initialization completed in {time}s",
    "init.lock_busy": "Error: Another task is currently running.",
    "init.standardize_desc1": "This action will standardize your server files to make it managable by the manager.",
    "init.standardize_desc2": "You should backup your files before this action, the standardizer is only designed for normal Minecraft server file structure.",
    "init.standardize_cancelled": "Operation cancelled.",
    "init.moving_config": "Moving config files",
    "init.moved": " - Moved {name}",
    "init.move_failed": " - Failed to move {name}: {error}",
    "init.no_config_moved": " - No config files needed moving",
    "init.moving_worlds": "Moving worlds",
    "init.moved_world": " - Moved {name}",
    "init.move_world_failed": " - Failed to move {name}: {error}",
    "init.no_worlds_found": " - No worlds found",
    "init.created_bundles": "Created bundles directory",
    "init.detecting_cores": "Detecting cores",
    "init.no_jar_files": "No .jar files found.",
    "init.which_core_blank": "Which one would you like to use (leave blank for newest):",
    "init.config_continue": "Do you want to continue?",
    "init.use_detected": "Use this version?",
    "init.enter_version": "Enter Minecraft server version (e.g., 1.21.5 or 1.21):",
    "init.enter_ram": "Set maximum RAM (e.g., 4096 for 4GB, or 4 for 4GB):",
    "init.continue_anyway": "Continue anyway?",
    "init.enter_exclusions": "Enter additional exclusions (comma-separated, leave empty if none):",
    "init.select_java": "Select Java installation (0-{max}):",
    "init.enter_java_home": "Enter Java path (can be Java home or bin directory):",
    "init.enter_params": "Enter additional parameters (leave empty if none):",
    "init.custom_java_ask": "Would you like to specify a custom Java path? (y/N):",
    "init.standardize_confirm": "Would you like to continue?",
    "init.your_choice": "Your choice (1-3):",
    "init.memory_warning": "Warning: Allocated memory {allocated}MB exceeds recommended limit {max}MB",
    "init.container_adjusted": "Container environment adjusted to: {value}MB",
    "init.adjusted_limit": "Adjusted to limit: {value}MB",
    "init.plugin_analyze_error": "Error analyzing {name}: {error}",
    "init.java_selection_title": "Java Selection",
    "init.col_path": "Path",
    "init.col_version": "Version",
    "init.col_vendor": "Vendor",
    "init.custom_java": "0. Custom Java",
    "init.java_unknown": "Java ?",
    "init.unknown": "Unknown",
    "init.multiple_jars": "Detected multiple .jar files",
    "init.core_exists_short": "core.jar already exists",
    "init.invalid_input": "Invalid input.",
    "init.selection_out_of_range": "Selection out of range.",
    "init.invalid_choice": "Invalid choice.",
    "init.you_should_init": "You should initialize your server:",
    # Version module
    "version.lock_error": "Error: Could not create task lock",
    "version.new_title": "New Server Creation",
    "version.no_versions": "No server versions found in bundles directory.",
    "version.download_hint": "Please download a version first using: --get <version>",
    "version.available_versions": "Available Versions:",
    "version.no_selection": "No selection made.",
    "version.invalid_selection": "Invalid selection.",
    "version.selected_version": "Selected version: {version}",
    "version.save_state": "Saving current server state",
    "version.backup_module_missing": "Cannot create a new server without the backup module.",
    "version.enter_number": "Invalid input. Please enter a number.",
    "version.extracted_core": "Extracted core for version {version}",
    "version.extract_error": "Error extracting core: {error}",
    "version.init_options": "Initialization options:",
    "version.init_manual": "Enter --init",
    "version.init_auto": "Enter --init auto",
    "version.init_exit": "Exit without initialization",
    "version.running_manual": "Running manual initialization",
    "version.running_auto": "Running auto initialization",
    "version.not_initialized": "Server created but not initialized.",
    "version.init_hint": "Please run --init or --init auto to configure the server.",
    "version.invalid_init_choice": "Invalid input. Choose 1, 2, or 3.",
    "version.cancelled": "Operation cancelled by user.",
    "version.create_error": "Error during new server creation: {error}",
    "version.no_local_version": "No local version found to check for updates.",
    "version.cannot_determine_build": "Could not determine local build number.",
    "version.no_successful_builds": "No successful builds found for this version.",
    "version.local_latest": "Local build: {local}, Latest build: {latest}",
    "version.update_available": "Update available!",
    "version.no_updates": "No updates found.",
    "version.no_core_zip": "No core.zip found for version {version}",
    "version.build_info": "Build Information:",
    "version.author": "Author: {author}",
    "version.date": "Date: {date}",
    "version.md5": "MD5: {md5}",
    "version.description": "Description:",
    "version.download_confirm": "Do you want to download this version?",
    "version.download_canceled": "Download canceled.",
    "version.download_started": "Downloading from {url}",
    "version.download_speed_hint": "This may take a while depending on your network speed.",
    "version.ctrl_c_hint": "Press CTRL+C to cancel the download.",
    "version.download_completed": "Download completed in {time} seconds.",
    "version.download_speed": "Download speed: {speed:.2f} KB/s",
    "version.verifying": "Verifying file integrity",
    "version.md5_failed": "MD5 verification failed",
    "version.md5_expected": "Expected: {md5}",
    "version.md5_got": "Got: {md5}",
    "version.corrupted": "The downloaded file may be corrupted.",
    "version.deleted_security": "The file will be deleted due to security reasons.",
    "version.md5_ok": "MD5 verified successfully!",
    "version.no_md5_warning": "Warning: No MD5 hash provided for verification.",
    "version.downloaded": "Successfully downloaded {version} (build {build}) to {path}",
    "version.download_error": "Error during download: {error}",
    "version.version_not_found": "Version {version} not found on PurpurMC",
    "version.http_error": "HTTP Error: {code} - {reason}",
    "version.url_error": "URL Error: {reason}",
    "version.timeout": "Timeout while fetching version {version}",
    "version.download_version_error": "Error downloading version {version}: {error}",
    "version.no_versions_installed": "No versions available in bundles directory",
    "version.exclusion_list": "Exclusion List:",
    "version.usage_delete": "Usage: --delete <version>",
    "version.version_not_exist": "Version {version} does not exist",
    "version.deletion_canceled": "Deletion canceled",
    "version.deleting_version": "Deleting version {version}",
    "version.deleted_version": "Version {version} deleted successfully",
    "version.delete_error": "Error deleting version: {error}",
    "version.usage_change": "Usage: --change <version>",
    "version.config_not_found": "Configuration file not found! Run with --init first.",
    "version.saving_current": "Saving current version {version}",
    "version.target_not_found": "Version {version} not found",
    "version.switching": "Switching to version {version}",
    "version.switch_error": "Error switching version: {error}",
    "version.upgrade_title": "Server Core Upgrade",
    "version.current_version": "Current server version: {version}",
    "version.backup_ask": "Do you want to create a backup before upgrading?",
    "version.creating_backup": "Creating backup",
    "version.no_versions_upgrade": "No versions found in bundles directory",
    "version.select_version": "Select a version to upgrade to (number):",
    "version.upgrade_confirm": "Are you sure you want to upgrade from {current} to {selected}?",
    "version.upgrading_core": "Upgrading server core",
    "version.backed_up_core": "Backed up current core.jar",
    "version.core_upgraded": "Core upgraded successfully.",
    "version.config_updated": "Updated configuration to version {version}",
    "version.upgrade_completed": "Server upgrade completed successfully",
    "version.plugins_review": "Please review your plugin compatibility before starting the server.",
    "version.upgrade_interrupted": "Upgrade interrupted by user.",
    "version.upgrade_error": "Error during upgrade process: {error}",
    "version.select_create": "Select a version to create (number):",
    "version.update_build_ask": "Update to latest build before creating?",
    "version.init_choice_prompt": "Your choice (1-3):",
    "version.overwrite_ask": "Version {version} already exists. Overwrite?",
    "version.delete_confirm": "Are you sure you want to delete version '{version}'?",
    "version.continue_ask": "Are you sure you want to continue?",
    "version.reinstall_ask": "Do you want to reinstall the current version?",
    "version.download_newer_ask": "Newer build available. Download now?",
    "version.cannot_check_updates": "Could not check for updates.",
    "version.network_hint": "Please check your internet connection.",
    "version.network_error": "Network Error: {reason}",
    "version.timeout_check": "Connection timeout while checking for updates.",
    "version.timeout_hint": "The request took too long. Please check your internet connection.",
    "version.parse_error": "Error parsing server response.",
    "version.invalid_data": "The API may have returned invalid data.",
    "version.continuing_local": "Continuing with local version...",
    "version.timeout_list": "Error: Connection timeout while fetching version list",
    "version.backup_module_missing_change": "Cannot switch versions without the backup module.",
    "version.download_first": 'Use "--get <version>" to download a version first.',
    "version.same_version": "Selected version is the same as current version.",
    "version.upgrade_canceled": "Upgrade canceled.",
    "version.plugins_hint": 'Use "--install plugins" to enable this option.',
    "version.updating_latest": "Updating to latest build...",
    "version.invalid_format": "Use format like 1.21.5 or 1.21",
    "version.current_unknown": "Error: Could not determine current server version.",
    "version.ensure_configured": "Please ensure the server is properly configured.",
    "version.backup_skipped": "Backup module is not installed; skipping backup.",
    "version.core_missing_package": "Error: core.jar not found in the package.",
    "version.plugins_unchanged": "Plugins left unchanged.",
    "version.config_warning": "Warning: Could not load config, using default version 'unknown'",
    "version.init_missing": "Required module 'init' is not installed.",
    "version.init_install_hint": 'Use "--install init" to install it.',
    "version.parse_current_error": "Error: Could not parse current version format.",
    "version.force_hint": 'Use "--upgrade force" to show all available versions.',
    "version.no_selection_made": "No selection made.",
    "version.invalid_selection_short": "Invalid selection.",
    "version.all_disabled": "All plugins have been disabled.",
    "version.disable_failed": "Failed to disable some plugins.",
    "version.major_warning": "This upgrade may cause world corruption or plugin incompatibility!",
    "version.downgrade_warning": "This may cause data loss or compatibility issues!",
    "version.plugins_disable_ask": "Do you want to disable all plugins for data safety?",
    "version.plugins_skipped": "Plugins module is not installed; skipping plugin disable step.",
    "version.selection_error": "Error during version selection: {error}",
    "version.major_mismatch_warning": "WARNING: Major version mismatch!",
    "version.current_major": "Current: {version} (major {major})",
    "version.selected_major": "Selected: {version} (major {major})",
    "version.downgrade_header": "WARNING: Downgrading from {current} to {selected}",
    "version.checking_updates": "Checking for updates for version {version}...",
    "version.switched": "Successfully switched to version {version}",
    "version.core_missing": "Error: core.zip missing for {version}",
    "version.info_read_error": "Error reading local version info: {error}",
    "version.unexpected_error": "Unexpected error: {error}",
    "version.version_info_error": "Error reading version info: {error}",
    "version.fetch_error": "Error fetching available versions: {error}",
    "version.connect_error": "Error: Could not connect to server - {error}",
    "version.fetching_info": "Fetching version information for {version}...",
    "version.core_package_error": "Error: Core package not found for version {version}",
    "version.no_info": "No info.txt found for version {version}",
    "version.invalid_format_short": "Invalid version format: {version}",
    "version.all_available": "All available versions:",
    "version.compatible_versions": "Available upgrade versions (compatible with {major}.x):",
    "version.core_upgrade_error": "Error during core upgrade: {error}",
    "version.no_success_build": "No successful builds found for version {version}",
    "version.no_compatible": "No compatible versions found for upgrade.",
    "version.current_version_short": "Current version: {version}",
    "version.looking_major": "Looking for versions with major version {major} or higher.",
    "version.creating_new": "Creating new server...",
    "version.config_section_missing": "Warning: Configuration file missing [SERVER] section. Creating default...",
    "version.target_config_missing": "Warning: No config file found in target version. Creating default...",
    "version.version_info": "Version Information:",
}


# ── Utility functions ──────────────────────────────────────────────


def confirm_action(prompt, default_no=True):
    """Ask a Y/N question; the uppercase option is the Enter default."""
    default_hint = " (y/N): " if default_no else " (Y/n): "
    while True:
        choice = input(prompt + default_hint).strip().upper()
        if not choice:
            return not default_no
        if choice == 'Y':
            return True
        if choice == 'N':
            return False
        print(t("core.confirm.invalid_yn"))


def truncate_text(text, max_length):
    text = str(text)
    if len(text) > max_length:
        return text[:max_length - 3] + "..."
    return text

def display_width(text):
    """Display width of text (East Asian characters count as 2 columns)."""
    width = 0
    for char in str(text):
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width

def center_text(text, width):
    """Center text by display width, so CJK titles align inside '=' banners."""
    text = str(text)
    pad = max(0, width - display_width(text))
    left = pad // 2
    return " " * left + text + " " * (pad - left)

def truncate_display(text, max_width):
    """Truncate text by display width (CJK chars count as 2 columns)."""
    text = str(text)
    if display_width(text) <= max_width:
        return text
    result = ""
    width = 0
    for char in text:
        char_width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if width + char_width + 3 > max_width:
            break
        result += char
        width += char_width
    return result + "..."

def pad_text(text, width, truncate=False):
    """Right-pad (or truncate) text by display width."""
    text = str(text)
    if truncate and display_width(text) > width:
        text = truncate_display(text, width)
    return text + " " * max(0, width - display_width(text))


def get_script_config():
    cfg = configparser.ConfigParser()
    if SCRIPT_CONFIG_FILE.exists():
        try:
            cfg.read(SCRIPT_CONFIG_FILE, encoding="utf-8")
        except Exception as e:
            logger.warning(f"Could not read script config: {e}")
    return cfg

def save_script_config(cfg):
    SCRIPT_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(SCRIPT_CONFIG_FILE, "w", encoding="utf-8") as f:
        cfg.write(f)

def ensure_script_config():
    """Migrate the legacy config/modules.cfg into config/script.cfg if needed."""
    if SCRIPT_CONFIG_FILE.exists():
        return
    if not MODULES_CONFIG_FILE.exists():
        return
    try:
        old = configparser.ConfigParser()
        old.read(MODULES_CONFIG_FILE, encoding="utf-8")
        modules_dir = ""
        if old.has_section("MODULES") and old.has_option("MODULES", "dir"):
            modules_dir = old.get("MODULES", "dir").strip()
        if modules_dir:
            cfg = configparser.ConfigParser()
            cfg.add_section("script")
            cfg.set("script", "language", "en")
            cfg.add_section("modules")
            cfg.set("modules", "dir", modules_dir)
            save_script_config(cfg)
            logger.info(f"Migrated modules config into {SCRIPT_CONFIG_FILE}")
    except Exception as e:
        logger.warning(f"Could not migrate modules config: {e}")

def get_script_language():
    cfg = get_script_config()
    if cfg.has_option("script", "language"):
        return cfg.get("script", "language").strip() or "en"
    return "en"

def set_script_language(code):
    cfg = get_script_config()
    if not cfg.has_section("script"):
        cfg.add_section("script")
    cfg.set("script", "language", code)
    save_script_config(cfg)
    logger.info(f"Script language set to: {code}")

def load_language(code):
    global CURRENT_LANG, LANG_DATA
    CURRENT_LANG = "en"
    LANG_DATA = {}
    if code:
        path = LANG_DIR / f"{code}.json"
        if code != "en" or path.exists():
            if path.exists():
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    strings = data.get("strings", {})
                    if isinstance(strings, dict):
                        LANG_DATA = strings
                        CURRENT_LANG = code
                        logger.info(f"Loaded language pack: {code}")
                    else:
                        logger.warning(f"Invalid language pack (missing strings): {path}")
                except Exception as e:
                    logger.warning(f"Could not load language pack {path}: {e}")
            else:
                logger.warning(f"Language pack not found: {path}")
    else:
        logger.info("Using default language: en")

def t(key, **kwargs):
    """Translate a UI string; falls back to English, then to the key itself."""
    text = LANG_DATA.get(key)
    if text is None:
        text = DEFAULT_STRINGS.get(key, key)
    if kwargs:
        try:
            return text.format(**kwargs)
        except (KeyError, IndexError, ValueError):
            return text
    return text

def get_installed_languages():
    langs = [{"code": "en", "display": "English"}]
    if LANG_DIR.exists():
        for path in sorted(LANG_DIR.glob("*.json")):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                code = data.get("lang", path.stem)
                display = data.get("display", path.stem)
                existing = next((item for item in langs if item["code"] == code), None)
                if existing:
                    existing["display"] = display
                    existing["path"] = path
                else:
                    langs.append({"code": code, "display": display, "path": path})
            except Exception as e:
                logger.warning(f"Invalid language file {path}: {e}")
    return langs

def get_remote_languages(update_info=None):
    if update_info is None:
        try:
            update_info = get_update_info()
        except Exception:
            return {}
    if isinstance(update_info, dict):
        languages = update_info.get("languages", {})
        return languages if isinstance(languages, dict) else {}
    return {}

def download_language_file(code, info):
    url = info.get("url")
    expected_md5 = info.get("md5")
    if not url:
        logger.error(f"No download URL for language pack: {code}")
        return False
    try:
        LANG_DIR.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read()
        actual_md5 = hashlib.md5(content).hexdigest()
        if expected_md5 and actual_md5 != expected_md5:
            logger.error(f"MD5 verification failed for language pack {code} (expected: {expected_md5}, got: {actual_md5})")
            print(t("core.lang.download_fail", code=code, error="MD5 verification failed"))
            return False
        data = json.loads(content.decode("utf-8"))
        if not isinstance(data.get("strings", {}), dict):
            raise ValueError("language file has no strings map")
        path = LANG_DIR / f"{code}.json"
        path.write_bytes(content)
        logger.info(f"Language pack downloaded: {code} (version {info.get('version', 'unknown')})")
        return True
    except Exception as e:
        logger.error(f"Error downloading language pack {code}: {e}")
        print(t("core.lang.download_fail", code=code, error=e))
        return False

def run_language_selection():
    print("\n" + "=" * 52)
    print(center_text(t("core.lang.title"), 52))
    print("=" * 52)
    print()
    remote = get_remote_languages()
    installed = get_installed_languages()
    options = [{"code": "en", "display": t("core.lang.english")}]
    for code, info in sorted(remote.items()):
        if code != "en" and not any(x["code"] == code for x in options):
            options.append({"code": code, "display": info.get("display", code), "remote": True})
    for item in installed:
        if item["code"] != "en" and not any(x["code"] == item["code"] for x in options):
            options.append(item)
    print(t("core.lang.choose"))
    for i, option in enumerate(options, 1):
        print(f" {i}. {option['display']} ({option['code']})")
    print()
    while True:
        choice = input("> ").strip().lower()
        if not choice:
            choice = "1"
        if choice.isdigit() and 1 <= int(choice) <= len(options):
            selected = options[int(choice) - 1]
            break
        matches = [option for option in options if option["code"] == choice]
        if matches:
            selected = matches[0]
            break
        print(t("core.lang.invalid_choice"))
    code = selected["code"]
    if code != "en":
        local = any(item["code"] == code and "path" in item for item in installed)
        if not local:
            info = remote.get(code)
            if not info:
                print(t("core.lang.download_fail", code=code, error="language pack is not available"))
                return "en"
            print(t("core.lang.downloading", code=code))
            if not download_language_file(code, info):
                print(t("core.lang.download_fail", code=code, error="download failed"))
                return "en"
    set_script_language(code)
    load_language(code)
    print(t("core.lang.set", display=selected["display"]))
    return code

def cmd_lang(args):
    if len(args) > 1:
        code = args[1]
        installed = get_installed_languages()
        local = next((item for item in installed if item["code"].lower() == code.lower()), None)
        if local:
            code = local["code"]
        remote = get_remote_languages()
        info = remote.get(code)
        if not local and not info:
            for remote_code, remote_info in remote.items():
                if remote_code.lower() == code.lower():
                    code = remote_code
                    info = remote_info
                    break
        if code == "en":
            set_script_language("en")
            load_language("en")
            print(t("core.lang.set", display="English"))
            return
        if not local and not info:
            print(t("core.lang.unknown", code=code))
            return
        if not local:
            print(t("core.lang.downloading", code=code))
            if not download_language_file(code, info):
                return
            installed = get_installed_languages()
            local = next((item for item in installed if item["code"] == code), None)
        set_script_language(code)
        load_language(code)
        display = local["display"] if local else info.get("display", code)
        print(t("core.lang.set", display=display))
        return
    installed = get_installed_languages()
    current_display = "English"
    if CURRENT_LANG != "en":
        current = next((item for item in installed if item["code"] == CURRENT_LANG), None)
        if current:
            current_display = current["display"]
    print("\n" + t("core.lang.current", display=current_display, code=CURRENT_LANG))
    print()
    print(t("core.lang.available"))
    for item in installed:
        marker = " *" if item["code"] == CURRENT_LANG else ""
        print(f" - {item['display']} ({item['code']}){marker}")
    remote = get_remote_languages()
    for code, info in sorted(remote.items()):
        if not any(item["code"] == code for item in installed):
            print(f" - {info.get('display', code)} ({code})")
    print("")


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


class AlignedFormatter(logging.Formatter):
    """Formatter with aligned, abbreviated level names (INFO/WARN/ERROR)."""
    LEVEL_NAMES = {
        logging.DEBUG: "DEBUG",
        logging.INFO: "INFO",
        logging.WARNING: "WARN",
        logging.ERROR: "ERROR",
        logging.CRITICAL: "CRIT",
    }

    def format(self, record):
        record.levelname = self.LEVEL_NAMES.get(record.levelno, record.levelname)
        return super().format(record)


def setup_logger():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("mc-manager")
    logger.setLevel(logging.INFO)
    if logger.handlers:
        return logger
    formatter = AlignedFormatter(
        fmt="%(asctime)s %(levelname)-5s > %(message)s",
        datefmt="%Y/%m/%d %H:%M:%S"
    )
    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setLevel(logging.INFO)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    if LOG_FILE.exists() and LOG_FILE.stat().st_size > 128 * 1024:
        try:
            original_size = LOG_FILE.stat().st_size
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
            logger.info(f"Log file rotated: {archive_filename} (original size: {original_size} bytes)")
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
        print(t("core.env.device_warning", error=e))
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
            print(center_text(t("core.env.no_device_title"), 62))
            print("=" * 62)
            print("\n" + t("core.env.no_device_msg1"))
            print(t("core.env.no_device_msg2"))
            print("\n" + t("core.env.no_device_msg3"))
            choice = input("\n" + t("core.env.continue_anyway") + " ").strip().upper() or "N"
            if choice != 'Y':
                logger.info("User chose to exit due to missing device data")
                print(t("core.env.exiting") + "\n")
                sys.exit(0)
            logger.info("User chose to continue despite missing device data")
            return True
        stored_device_id = config["SERVER"]["device"]
        current_device_id = get_device_id()
        logger.info(f"Stored device ID: {stored_device_id}, Current device ID: {current_device_id}")
        if stored_device_id == "unknown" or current_device_id == "unknown":
            logger.warning("Limited device identification detected")
            print("\n" + "=" * 61)
            print(center_text(t("core.env.limited_title"), 61))
            print("=" * 61)
            print("\n" + t("core.env.limited_msg1"))
            print(t("core.env.limited_msg2"))
            print("\n" + t("core.env.limited_msg3"))
            print("\n" + t("core.env.continuing") + "\n")
            return True
        if stored_device_id == current_device_id:
            logger.info("Device ID matches, environment unchanged")
            return True
        logger.warning(f"Environment change detected! Stored: {stored_device_id}, Current: {current_device_id}")
        print("\n" + "=" * 61)
        print(center_text(t("core.env.changed_title"), 61))
        print("=" * 61)
        print("\n" + t("core.env.changed_msg1"))
        print(t("core.env.changed_msg2"))
        print("\n" + t("core.env.changed_msg3"))
        print(t("core.env.changed_item1"))
        print(t("core.env.changed_item2"))
        print(t("core.env.changed_item3"))
        print(t("core.env.changed_item4"))
        print("\n" + t("core.env.changed_msg4"))
        while True:
            print("\n" + t("core.env.options"))
            print(t("core.env.opt_backup_manual"))
            print(t("core.env.opt_backup_auto"))
            print(t("core.env.opt_ignore"))
            print(t("core.env.opt_exit"))
            choice = input("\n" + t("core.env.enter_choice") + " ").strip()
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
                print(t("core.env.exiting") + "\n")
                sys.exit(0)
            else:
                logger.warning(f"Invalid user choice in environment change menu: {choice}")
                print(t("core.env.invalid_choice"))
    except Exception as e:
        logger.error(f"Error during environment check: {e}")
        print(t("core.env.check_error", error=e))
        print(t("core.env.continuing"))
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
                print("\n" + t("core.env.backed_up", path=backup_file))
            except Exception as backup_error:
                logger.error(f"Failed to backup configuration file: {backup_error}")
                print(t("core.env.backup_failed", error=backup_error))
        if init_type == "manual":
            logger.info("Starting manual initialization...")
            print(t("core.env.manual_init"))
            init_config()
        else:
            logger.info("Starting auto initialization...")
            print(t("core.env.auto_init"))
            init_config_auto()
        logger.info("Environment configuration completed successfully")
        print(t("core.env.completed"))
        print(t("core.env.run_again") + "\n")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Error during environment change handling: {e}", exc_info=True)
        print(t("core.env.handle_error", error=e))
        print(t("core.env.fallback"))
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
            print("\n" + t("core.env.device_updated"))
            print(t("core.env.continuing") + "\n")
        return True
    except Exception as e:
        print(t("core.env.update_error", error=e))
        print(t("core.env.continuing"))
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
        print("\n" + t("core.lock.create_error", error=e) + "\n")
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
        print("\n" + t("core.lock.remove_error", error=e) + "\n")
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
        print("\n" + t("core.lock.read_error", error=e) + "\n")
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
        print(center_text(t("core.pending.duplicate_title"), 51))
        print("=" * 51)
        print("\n" + t("core.pending.another_running"))
        print(f" - PID: {lock_info['pid']}")
        print(f" - Command: {lock_info['command']}")
        print(f" - Lock created at: {time_str}")
        print(f" - Task running for: {time_duration}")
        print("\n" + t("core.pending.multiple"))
        print(t("core.pending.wait"))
        while True:
            print("\n" + t("core.pending.options"))
            print(t("core.pending.quit"))
            print(t("core.pending.force"))
            print("\n" + t("core.pending.force_warn"))
            choice = input("\n" + t("core.pending.q_f_prompt") + " ").strip().upper()
            if choice == 'Q':
                logger.info("User chose to quit due to duplicate instance")
                print("\n" + t("core.env.exiting") + "\n")
                sys.exit(0)
            elif choice == 'F':
                logger.warning("User chose to force clear lock - requesting confirmation")
                confirm = input("\n" + t("core.pending.force_confirm") + " ").strip().upper() or "N"
                if confirm == 'Y':
                    logger.warning("User confirmed force clearing lock - proceeding")
                    print("\n" + t("core.pending.force_clearing") + "\n")
                    remove_lock()
                    return False
                else:
                    logger.info("User cancelled force clear after confirmation")
                    continue
            else:
                logger.warning(f"Invalid choice in duplicate instance menu: {choice}")
                print(t("core.pending.q_f"))
    else:
        logger.warning(f"Pending task detected - PID: {lock_info['pid']}, Command: {' '.join(lock_info['command'])}, "
                      f"Task started at: {time_str}, Interrupted {time_duration} ago")
        print(center_text(t("core.pending.pending_title"), 51))
        print("=" * 51)
        print("\n" + t("core.pending.interrupted"))
        print(f" - {lock_info['command']}")
        print(f" - PID: {lock_info['pid']}")
        print(f" - Task started at: {time_str}")
        print(f" - Interrupted {time_duration} ago")
        print("\n" + t("core.pending.terminated"))
        while True:
            print("\n" + t("core.pending.options"))
            print(t("core.pending.y"))
            print(t("core.pending.n"))
            print(t("core.pending.q"))
            print("\n" + t("core.pending.never_y") + "\n")
            choice = input(t("core.pending.prompt") + " ").strip().upper()
            if choice == 'Y':
                logger.warning("User chose to resume pending task - proceeding with caution")
                print("\n" + t("core.pending.resuming") + "\n")
                return lock_info['command']
            elif choice == 'N':
                logger.info("User chose to clear pending task")
                print("\n" + t("core.pending.clearing") + "\n")
                remove_lock()
                return False
            elif choice == 'Q':
                logger.info("User chose to quit without making changes")
                print("\n" + t("core.pending.exiting_no_changes") + "\n")
                sys.exit(0)
            else:
                logger.warning(f"Invalid choice in pending task menu: {choice}")
                print(t("core.pending.ynq") + "\n")


def check_server_requirements():
    logger.info("Checking server requirements")
    print(t("core.start.checking_requirements"))
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
                logger.warning(f"No write permission in {dir_path.name} directory: {e}")
                print(f" - No write permission in {dir_path.name} directory")
                return False
        except Exception as e:
            logger.warning(f"Error accessing {dir_path.name} directory: {e}")
            print(f" - Error accessing {dir_path.name} directory: {e}")
            return False
    if not SERVER_JAR.exists():
        logger.warning(f"Server core file not found: {SERVER_JAR}")
        print(f" - Server core file not found: {SERVER_JAR}")
        return False
    logger.info("File permissions are valid")
    print(" - File permissions are valid")
    return True


def check_and_accept_eula():
    if not EULA_FILE.exists():
        with open(EULA_FILE, 'w') as f:
            f.write("#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).\n")
            f.write(f"#{datetime.datetime.now().strftime('%a %b %d %H:%M:%S %Z %Y')}\n")
            f.write("eula=true\n")
        logger.info("EULA file created and accepted automatically")
        print(t("core.eula.created"))
        print(t("core.eula.agree") + "\n")
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
        logger.error(f"Error reading EULA file: {e}")
        print("\n" + t("core.eula.error", error=e) + "\n")
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
            logger.info("EULA accepted automatically (was set to false)")
            print(t("core.eula.accepted"))
            print(t("core.eula.agree") + "\n")
            return True
        except Exception as e:
            logger.error(f"Error updating EULA file: {e}")
            print(t("core.eula.update_error", error=e))
            return False
    logger.info("EULA already accepted")
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
        except Exception as e:
            logger.warning(f"Could not read additional exclusions from config: {e}")
    return exclude_list

def preserve_script_config():
    """Back up config/script.cfg before destructive server operations."""
    if not SCRIPT_CONFIG_FILE.exists():
        return False
    try:
        backup_dir = BUNDLES_DIR / ".meta"
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SCRIPT_CONFIG_FILE, backup_dir / "script.cfg")
        logger.info(f"Script config preserved: {SCRIPT_CONFIG_FILE}")
        return True
    except Exception as e:
        logger.warning(f"Could not preserve script config: {e}")
        return False

def restore_script_config():
    """Restore config/script.cfg after destructive server operations."""
    backup = BUNDLES_DIR / ".meta" / "script.cfg"
    if not backup.exists():
        return False
    try:
        SCRIPT_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup, SCRIPT_CONFIG_FILE)
        backup.unlink()
        logger.info(f"Script config restored: {SCRIPT_CONFIG_FILE}")
        return True
    except Exception as e:
        logger.warning(f"Could not restore script config: {e}")
        return False


def clear_screen():
    if platform.system() == "Windows":
        os.system("cls")
    else:
        os.system("clear")

_config_cache = {}
_config_mtime = 0


def load_config():
    global _config_cache, _config_mtime
    if not CONFIG_FILE.exists():
        logger.error("Configuration file not found")
        print("\n" + t("core.config.not_found_path", path=CONFIG_FILE))
        print(t("core.config.init_required") + "\n")
        sys.exit(1)
    current_mtime = CONFIG_FILE.stat().st_mtime
    if _config_cache and _config_mtime == current_mtime:
        return dict(_config_cache)
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)
    if "SERVER" not in config:
        logger.error("Invalid configuration format")
        print(t("core.config.invalid_format"))
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
        print("\n" + t("core.info.title"))
        print("=" * 50)
        print(t("core.info.version", version=version))
        print(t("core.info.ram", ram=ram_display))
        print(t("core.info.java", path=java_path))
        print(t("core.info.exclusions", list=additional_list))
        print(t("core.info.params", params=additional_params))
        print("=" * 50)
        print("")
    except Exception as e:
        print(t("core.info.error", error=e) + "\n")
        sys.exit(1)

def show_license():
    print("\n" + "=" * 51)
    print(center_text(t("core.license.title"), 51))
    print("=" * 51)
    print("\n" + t("core.license.fetching"))
    license_url = "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/LICENSE"
    try:
        request = urllib.request.Request(license_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=10) as response:
            license_content = response.read().decode("utf-8")
            print("\n" + t("core.license.current"))
            print("=" * 51)
            print(license_content)
            print("=" * 51)
            print("")
    except urllib.error.HTTPError as e:
        print("\n" + t("core.license.http_error", code=e.code))
        print(t("core.license.http_hint") + "\n")
    except urllib.error.URLError as e:
        print("\n" + t("core.license.network_error", error=e.reason))
        print(t("core.license.network_hint") + "\n")
    except socket.timeout:
        print("\n" + t("core.license.timeout"))
        print(t("core.license.timeout_hint") + "\n")
    except Exception as e:
        print("\n" + t("core.license.error", error=e) + "\n")


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
        logger.warning(f"Config parsing error: {e}")
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
        print("\n" + t("core.config.missing_corrupted"))
        print(t("core.config.init_required") + " first.\n")
        return
    elif config_check_result == "critical_missing":
        logger.error("Critical configuration parameters are missing")
        print("\n" + t("core.config.critical_missing2"))
        print(t("core.config.critical_missing"))
        print(t("core.config.fix_init") + "\n")
        return
    elif config_check_result == "optional_missing":
        logger.warning("Some optional configuration parameters are missing")
        print("\n" + t("core.config.optional_warning"))
        print(t("core.config.optional_missing"))
        print(t("core.config.complete_init") + "\n")
    logger.info("Checking server requirements...")
    port_ok, java_ok, permissions_ok = check_server_requirements()
    if not all([port_ok, java_ok, permissions_ok]):
        logger.error(f"Server requirements check failed: port_ok={port_ok}, java_ok={java_ok}, permissions_ok={permissions_ok}")
        print("\n" + t("core.start.requirements_failed") + "\n")
        return
    logger.info("All server requirements passed")
    show_info()
    if not check_and_accept_eula():
        logger.error("Failed to accept EULA")
        print("\n" + t("core.start.eula_failed"))
        print(t("core.config.manual_eula") + "\n")
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
        print(t("core.start.java_missing", path=java_path) + "\n")
        sys.exit(1)
    if not SERVER_JAR.exists():
        logger.error(f"Server JAR not found at: {SERVER_JAR}")
        print(t("core.start.jar_missing", path=SERVER_JAR) + "\n")
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
    print(t("core.start.banner"))
    print("")
    print(t("core.start.command"), " ".join(command))
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
            print("\n" + t("core.start.uptime_seconds", uptime=uptime_str, seconds=int(uptime_seconds)))
        else:
            print("\n" + t("core.start.uptime", uptime=uptime_str))
        if process.returncode != 0:
            logger.warning(f"Server crashed with exit code: {process.returncode}")
            crash_mod = load_module("crash")
            if crash_mod:
                crash_mod.handle_server_crash(process, uptime_str)
            else:
                print("\n" + t("core.start.crash_module_missing"))
                print(t("core.start.crash_hint") + "\n")
        else:
            crash_mod = load_module("crash")
            if crash_mod and crash_mod.check_logs_for_errors():
                logger.info("Server stopped normally but errors found in logs")
                if crash_mod.ask_user_for_crash_analysis():
                    logger.info("User requested crash analysis for normal exit with errors")
                    crash_mod.analyze_server_crash(0, uptime_str)
                else:
                    logger.info("User skipped crash analysis for normal exit with errors")
                    print("\n" + t("core.start.stopped_warnings") + "\n")
            else:
                logger.info("Server stopped normally without errors")
                print("\n" + t("core.start.stopped_normal") + "\n")
    except KeyboardInterrupt:
        SERVER_END_TIME = time.time()
        logger.warning("Server shutdown requested by user (KeyboardInterrupt)")
        print("\n" + t("core.start.shutdown") + "\n")
        uptime_seconds, uptime_str, _ = get_uptime()
        if uptime_seconds >= 60:
            print(t("core.start.uptime_seconds", uptime=uptime_str, seconds=int(uptime_seconds)))
        else:
            print(t("core.start.uptime", uptime=uptime_str))
        if process:
            logger.info(f"Terminating server process (PID: {process.pid})")
            process.terminate()
            process.wait()
            logger.info("Server process terminated")
        print(t("core.start.checking_issues"))
        crash_mod = load_module("crash")
        if crash_mod and crash_mod.check_logs_for_errors():
            logger.info("Errors found in logs after user interrupt")
            if crash_mod.ask_user_for_interrupt_analysis():
                logger.info("User requested interrupt analysis")
                crash_mod.analyze_server_crash(-1, uptime_str)
            else:
                logger.info("User skipped interrupt analysis")
                print("\n" + t("core.start.interrupted") + "\n")
        else:
            logger.info("No errors found in logs after user interrupt")
            print("\n" + t("core.start.interrupted_clean") + "\n")
    except Exception as e:
        logger.error(f"Error starting server: {e}")
        print(t("core.start.start_error", error=e) + "\n")
        SERVER_END_TIME = time.time()
        uptime_seconds, uptime_str, _ = get_uptime()
        if uptime_seconds >= 60:
            print(t("core.start.uptime_seconds", uptime=uptime_str, seconds=int(uptime_seconds)))
        else:
            print(t("core.start.uptime", uptime=uptime_str))
        if process and process.poll() is None:
            logger.info(f"Terminating server process due to error (PID: {process.pid})")
            process.terminate()
            process.wait()
        if process:
            uptime_seconds, uptime_str, _ = get_uptime()
            logger.warning(f"Handling server crash after error, uptime: {uptime_str}")
            crash_mod = load_module("crash")
            if crash_mod:
                crash_mod.handle_server_crash(process, uptime_str)
            else:
                print("\n" + t("core.start.crash_module_missing"))
                print(t("core.start.crash_hint") + "\n")


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
        print(t("core.compare_error", error=e))


def check_self_update(force=False):
    logger.info(f"Starting self update check (force mode: {force})")
    print("\n" + "=" * 50)
    print(center_text(t("core.update.title"), 50))
    print("=" * 50)
    print("\n" + t("core.update.current", version=SCRIPT_VERSION))
    try:
        update_info = get_update_info()
    except Exception as e:
        logger.error(f"Could not fetch update information: {e}")
        print(t("core.update.fetch_error", error=e) + "\n")
        return False
    latest_version = update_info.get("latest_version", "Unknown")
    release_date = update_info.get("date", "Unknown")
    print(t("core.update.latest", version=latest_version, date=release_date))
    core_update = force or (
        latest_version != "Unknown" and compare_script_versions(SCRIPT_VERSION, latest_version) < 0
    )
    if core_update:
        if not force:
            print("\n" + t("core.update.core_new", version=latest_version))
        else:
            print("\n" + t("core.update.force_bypass"))
        confirm = input(t("core.update.core_ask") + " ").strip().upper() or "N"
        if confirm == "Y":
            logger.info("User confirmed core update")
            download_latest_version()
        else:
            logger.info("User canceled core update")
            print(t("core.update.core_canceled") + "\n")
    else:
        print(t("core.update.core_uptodate"))
    update_installed_modules(update_info, force=force)
    update_language_files(update_info)
    return True


def download_latest_version():
    logger.info("Starting download of latest version")
    current_script = Path(__file__).resolve()
    script_url = os.environ.get(
        "MCSM_SCRIPT_URL",
        "https://raw.githubusercontent.com/Admin-SR40/MC-Server-Manager/refs/heads/main/start.sh"
    )
    print("\n" + t("core.update.downloading_core", url=script_url))
    try:
        update_info = get_update_info()
        expected_md5 = update_info.get("md5")
        latest_version = update_info.get("latest_version", "Unknown")
        if not expected_md5:
            logger.warning("No MD5 hash available for verification")
            print(t("core.update.no_md5_warning"))
        logger.info(f"Starting download of version {latest_version}")
        print("\n" + t("core.update.download_started"))
        start_time = time.time()
        request = urllib.request.Request(script_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            script_content = response.read()
        elapsed_time = time.time() - start_time
        file_size = len(script_content)
        download_speed = file_size / elapsed_time / 1024
        logger.info(f"Download completed in {elapsed_time:.2f}s, size: {file_size} bytes, speed: {download_speed:.2f} KB/s")
        print("\n" + t("core.update.download_completed", time=f"{elapsed_time:.2f}"))
        print(t("core.update.download_speed", speed=download_speed) + "\n")
        if expected_md5:
            logger.info("Verifying file integrity with MD5...")
            print(t("core.update.verifying") + "...")
            actual_md5 = hashlib.md5(script_content).hexdigest()
            if actual_md5 != expected_md5:
                logger.error(f"MD5 verification failed (expected: {expected_md5}, got: {actual_md5})")
                print(t("core.update.md5_failed") + "!")
                print(t("core.update.expected", md5=expected_md5))
                print(t("core.update.got", md5=actual_md5))
                print("\n" + t("core.update.corrupted"))
                print(t("core.update.aborted_security"))
                return False
            logger.info("MD5 verification passed")
            print(t("core.update.md5_passed") + "\n")
        backup_script = current_script.with_name(current_script.name + '.bak')
        new_script = current_script.with_name(current_script.name + '.new')
        try:
            shutil.copy2(current_script, backup_script)
            logger.info(f"Backup created: {backup_script}")
            print(t("core.update.backup_created", path=backup_script))
        except Exception as e:
            logger.warning(f"Could not create backup: {e}")
            print(t("core.update.backup_warning", error=e))
        with open(new_script, 'wb') as f:
            f.write(script_content)
        try:
            if platform.system() != "Windows":
                os.chmod(new_script, 0o755)
                logger.info("Set executable permissions on new script")
        except Exception as e:
            logger.warning(f"Could not set executable permissions: {e}")
            print(t("core.update.chmod_warning", error=e))
        try:
            if platform.system() == "Windows":
                os.remove(current_script)
                shutil.move(new_script, current_script)
            else:
                os.replace(new_script, current_script)
            logger.info(f"Update completed successfully to version {latest_version}")
            print("\n" + t("core.update.update_completed"))
            print(t("core.update.updated_version", version=latest_version))
            print(t("core.update.run_again"))
            print("")
            return True
        except Exception as e:
            logger.error(f"Failed to replace current script: {e}")
            print("\n" + t("core.update.replace_failed", error=e))
            print(t("core.update.replace_hint"))
            print("\n" + t("core.update.manual_title"))
            print("=" * 40)
            if platform.system() == "Windows":
                print(t("core.update.manual_windows"))
                print(t("core.update.manual_delete", path=current_script))
                print(t("core.update.manual_rename", new=new_script, name=current_script.name))
            else:
                print(t("core.update.manual_cmds"))
                print(t("core.update.manual_rm", path=current_script))
                print(t("core.update.manual_mv", new=new_script, path=current_script))
                print(t("core.update.manual_chmod", path=current_script))
            print("=" * 40)
            return False
    except Exception as e:
        logger.error(f"Error during update process: {e}")
        print(t("core.update.process_error", error=e) + "\n")
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
    cfg = get_script_config()
    if cfg.has_option("modules", "dir"):
        value = cfg.get("modules", "dir").strip()
        if value:
            return Path(value).expanduser().resolve()
    if MODULES_CONFIG_FILE.exists():
        try:
            old = configparser.ConfigParser()
            old.read(MODULES_CONFIG_FILE, encoding="utf-8")
            if old.has_option("MODULES", "dir"):
                value = old.get("MODULES", "dir").strip()
                if value:
                    return Path(value).expanduser().resolve()
        except Exception as e:
            logger.warning(f"Could not read legacy modules config: {e}")
    return None


def set_modules_dir(path):
    cfg = get_script_config()
    if not cfg.has_section("modules"):
        cfg.add_section("modules")
    cfg.set("modules", "dir", str(path))
    save_script_config(cfg)
    logger.info(f"Modules directory configured: {path}")
    print(t("core.install.dir_set", path=path))


def resolve_modules_dir():
    global MODULES_DIR, MODULES_JSON
    MODULES_DIR = get_modules_dir()
    MODULES_JSON = MODULES_DIR / "modules.json" if MODULES_DIR else None


def choose_modules_dir():
    logger.info("Choosing modules directory")
    print("\n" + t("core.install.choose_dir"))
    print(f" 1. {t('core.install.dir_shared')}")
    print(f" 2. {t('core.install.dir_server')}")
    print(f" 3. {t('core.install.dir_custom')}")
    try:
        while True:
            choice = input("\n" + t("core.install.your_choice_123") + " ").strip()
            if choice == "1":
                return Path.home() / ".cache" / "MC-Server-Manager"
            elif choice == "2":
                return BASE_DIR / "bundles" / "modules"
            elif choice == "3":
                custom = input(t("core.install.enter_custom_path") + " ").strip()
                if custom:
                    return Path(custom).expanduser().resolve()
                print(t("core.install.path_empty"))
            else:
                print(t("core.install.invalid_choice_123"))
    except (KeyboardInterrupt, EOFError):
        logger.warning("Module directory selection interrupted by user")
        print("\n" + t("core.install.canceled") + "\n")
        return None


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
        print(t("core.install.registry_error", error=e) + "\n")
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
        print(t("core.install.no_url", name=name) + "\n")
        return False
    if not MODULES_DIR:
        print(t("core.install.modules_dir_error") + "\n")
        return False
    try:
        MODULES_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(f"Could not create modules directory {MODULES_DIR}: {e}")
        print(t("core.install.dir_fail", path=MODULES_DIR) + f": {e}\n")
        return False
    temp_dir = MODULES_DIR / ".tmp"
    try:
        temp_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(f"Could not create temporary directory {temp_dir}: {e}")
        print(t("core.install.temp_dir_fail", path=temp_dir) + f": {e}\n")
        return False
    temp_file = temp_dir / f"{name}.py"
    print("\n" + t("core.install.downloading", name=name))
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        start_time = time.time()
        with urllib.request.urlopen(request, timeout=30) as response:
            content = response.read()
        elapsed_time = time.time() - start_time
        actual_md5 = hashlib.md5(content).hexdigest()
        if expected_md5 and actual_md5 != expected_md5:
            logger.error(f"MD5 verification failed for module {name} (expected: {expected_md5}, got: {actual_md5})")
            print(t("core.install.md5_failed", name=name))
            print(t("core.install.md5_expected", md5=expected_md5))
            print(t("core.install.md5_got", md5=actual_md5))
            print(t("core.install.corrupted") + "\n")
            return False
        try:
            compile(content, f"{name}.py", "exec")
        except SyntaxError as e:
            logger.error(f"Module {name} failed syntax check: {e}")
            print(t("core.install.syntax_error", name=name, error=e) + "\n")
            return False
        temp_file.write_bytes(content)
        os.replace(temp_file, MODULES_DIR / f"{name}.py")
        download_speed = len(content) / elapsed_time / 1024 if elapsed_time > 0 else 0
        print(t("core.install.installed", name=name, version=info.get('version', 'unknown'), size=len(content), speed=download_speed))
        logger.info(f"Module {name} installed successfully (version {info.get('version', 'unknown')})")
        return True
    except urllib.error.URLError as e:
        logger.error(f"Network error downloading module {name}: {e}")
        print(t("core.install.download_error", name=name, error=e) + "\n")
        return False
    except Exception as e:
        logger.error(f"Error downloading module {name}: {e}")
        print(t("core.install.download_error", name=name, error=e) + "\n")
        return False
    finally:
        if temp_file.exists():
            try:
                temp_file.unlink()
            except Exception:
                pass


def install_modules_from_info(update_info, names, interactive=True):
    logger.info(f"Installing modules: {', '.join(names)} (interactive={interactive})")
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
            print(t("core.install.unknown", name=name))
            skipped.add(name)
            return False
        missing_deps = [dep for dep in info.get("requires", []) if dep not in installed and dep not in to_install]
        if missing_deps:
            print("\n" + t("core.install.dep_required", name=name, deps=", ".join(missing_deps)))
            for dep in missing_deps:
                if interactive and not confirm_action(t("core.install.dep_ask", dep=dep), default_no=True):
                    print(t("core.install.dep_skip", name=name, dep=dep) + "\n")
                    skipped.add(name)
                    return False
                if not resolve(dep):
                    return False
        to_install.append(name)
        return True
    for name in names:
        resolve(name)
    if not to_install:
        logger.info("No modules to install (all requested modules already installed)")
        if skipped:
            print(t("core.install.skipped_deps") + "\n")
        elif names:
            print(t("core.install.all_already") + "\n")
        else:
            print(t("core.install.nothing") + "\n")
        return False
    ok = False
    installed_count = 0
    for name in to_install:
        info = modules[name]
        current = registry.get(name)
        if isinstance(current, dict) and current.get("version") == info.get("version") and current.get("md5") == info.get("md5"):
            print(t("core.install.already", name=name, version=info.get('version')))
            ok = True
            continue
        if download_module(name, info):
            installed_count += 1
            registry[name] = {
                "version": info.get("version"),
                "md5": info.get("md5"),
                "installed_at": datetime.datetime.now().isoformat()
            }
            ok = True
    if registry != installed:
        write_modules_json(registry)
    logger.info(f"Module installation finished: {installed_count} installed, {len(to_install) - installed_count} skipped/failed")
    print("")
    return ok


def select_modules_interactive(modules):
    names = sorted(modules.keys())
    print("\n" + t("core.install.available"))
    print("=" * 52)
    for i, name in enumerate(names, 1):
        info = modules[name]
        requires = f" (requires: {', '.join(info.get('requires', []))})" if info.get("requires") else ""
        print(f"{i:2d}. {name:<12} - {info.get('description', '')}{requires}")
    print("=" * 52)
    print(t("core.install.select_prompt"))
    choice = input("\n" + t("core.install.selection") + " ").strip().lower()
    if not choice:
        return []
    if choice == "all":
        logger.info("User selected all modules")
        return names
    selected = []
    for part in choice.split():
        if not part.isdigit():
            continue
        idx = int(part) - 1
        if 0 <= idx < len(names) and names[idx] not in selected:
            selected.append(names[idx])
    logger.info(f"User selected modules: {', '.join(selected)}")
    return selected


def run_install_flow(args=None, first_run=False):
    args = args or []
    global MODULES_DIR, MODULES_JSON
    logger.info(f"Starting module install flow (args={args}, first_run={first_run})")
    try:
        if first_run:
            print()
            print("=" * 60)
            print(center_text(t("core.first_run.title"), 60))
            print("=" * 60)
            print()
            print(t("core.first_run.desc1"))
            print(t("core.first_run.desc2"))
            print()
            print(t("core.first_run.desc3"))
            print(t("core.first_run.desc4"))
            print(t("core.first_run.desc5"))
            print(t("core.first_run.desc6"))
            print()
            print(t("core.first_run.desc7"))
            print()
            print(t("core.first_run.desc8"))
            print(t("core.first_run.desc9"))
        if not MODULES_DIR:
            path = choose_modules_dir()
            if not path:
                return False
            set_modules_dir(path)
            MODULES_DIR = path
            MODULES_JSON = path / "modules.json"
        try:
            MODULES_DIR.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            logger.error(f"Could not create modules directory {MODULES_DIR}: {e}")
            print("\n" + t("core.install.dir_create_error", path=MODULES_DIR))
            print(f"{e}\n")
            return False
        try:
            update_info = get_update_info()
        except Exception as e:
            logger.error(f"Could not fetch module list: {e}")
            print("\n" + t("core.install.fetch_error", error=e))
            print(t("core.install.network_hint") + "\n")
            return False
        modules = update_info.get("modules", {})
        if not modules:
            print(t("core.install.no_modules_available") + "\n")
            return False
        if args:
            targets = []
            for arg in args:
                if arg.lower() == "all":
                    targets = list(modules.keys())
                    break
                targets.append(arg)
            unknown = [target for target in targets if target not in modules]
            if unknown:
                print(t("core.install.unknown_modules", names=", ".join(unknown)))
                print(t("core.install.available_modules", names=", ".join(sorted(modules))) + "\n")
            targets = [target for target in targets if target in modules]
            if not targets:
                return False
            return install_modules_from_info(update_info, targets)
        selected = select_modules_interactive(modules)
        if not selected:
            print(t("core.install.no_selection") + "\n")
            return False
        return install_modules_from_info(update_info, selected)
    except (KeyboardInterrupt, EOFError):
        logger.warning("Module installation interrupted by user (KeyboardInterrupt)")
        print("\n" + t("core.install.canceled") + "\n")
        return False


def update_installed_modules(update_info, force=False):
    logger.info(f"Checking installed modules for updates (force={force})")
    print(t("core.update.modules_check"))
    installed = read_modules_json()
    if not installed:
        print(t("core.update.modules_none") + "\n")
        return
    updates = []
    cloud_modules = update_info.get("modules", {})
    for name, local in sorted(installed.items()):
        cloud = cloud_modules.get(name)
        local_version = local.get("version") if isinstance(local, dict) else local
        local_md5 = local.get("md5") if isinstance(local, dict) else ""
        if not cloud:
            print(t("core.update.removed_from_list", name=name))
            continue
        if force or local_version != cloud.get("version") or local_md5 != cloud.get("md5"):
            updates.append((name, cloud))
    if not updates:
        print(t("core.update.modules_uptodate") + "\n")
        return
    print("\n" + t("core.update.modules_available"))
    for name, cloud in updates:
        local = installed.get(name, {})
        local_version = local.get("version") if isinstance(local, dict) else "?"
        print(f" - {name}: {local_version} -> {cloud.get('version')}")
    confirm = input("\n" + t("core.update.modules_ask") + " ").strip().upper() or "N"
    if confirm != "Y":
        print(t("core.update.modules_canceled") + "\n")
        return
    registry = dict(installed)
    updated_count = 0
    for name, cloud in updates:
        if download_module(name, cloud):
            updated_count += 1
            registry[name] = {
                "version": cloud.get("version"),
                "md5": cloud.get("md5"),
                "installed_at": datetime.datetime.now().isoformat()
            }
    write_modules_json(registry)
    logger.info(f"Module update finished: {updated_count} updated, {len(updates) - updated_count} failed")
    print("")

def update_language_files(update_info):
    print(t("core.update.languages_check"))
    installed = get_installed_languages()
    remote = get_remote_languages(update_info)
    outdated = []
    for item in installed:
        code = item["code"]
        if code == "en":
            continue
        info = remote.get(code)
        if not info:
            continue
        local_version = "?"
        try:
            with open(item["path"], "r", encoding="utf-8") as f:
                local_version = json.load(f).get("version", "?")
        except Exception as e:
            logger.warning(f"Could not read language version for {code}: {e}")
        if str(local_version) != str(info.get("version")):
            outdated.append((code, info, local_version))
    if not outdated:
        print(t("core.update.languages_uptodate") + "\n")
        return
    print(t("core.update.languages_available"))
    for code, info, local_version in outdated:
        print(f" - {code}: {local_version} -> {info.get('version')}")
    confirm = input(t("core.update.languages_ask") + " ").strip().upper() or "N"
    if confirm != "Y":
        print(t("core.update.languages_canceled") + "\n")
        return
    for code, info, _ in outdated:
        if download_language_file(code, info):
            if code == CURRENT_LANG:
                load_language(code)
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

def require_module(name):
    """Load a module or print a clear "not installed" message."""
    module = load_module(name)
    if module is None:
        print("\n" + t("core.module.required_missing", name=name))
        print(t("core.module.install_hint", name=name) + "\n")
    return module


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
        print(t("core.module.load_error", name=name, error=e))
        print(t("core.module.reinstall_hint", name=name) + "\n")
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
        self.confirm_action = confirm_action
        self.safe_rmtree = safe_rmtree
        self.unlock_with_logging = _unlock_with_logging
        self.format_file_size = format_file_size
        self.truncate_text = truncate_text
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
        self.preserve_script_config = preserve_script_config
        self.restore_script_config = restore_script_config
        self.t = t
        self.require_module = require_module
        self.center_text = center_text
        self.pad_text = pad_text
        self.truncate_display = truncate_display

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
    print(center_text(t("core.help.title", version=SCRIPT_VERSION), 51))
    print("=" * 51)
    print("")
    print(t("core.help.desc"))
    print("")
    print(t("core.help.usage"))
    print(f"  {SCRIPT_NAME} [command] [options]")
    print("")
    print(t("core.help.core"))
    print(f"  (no command)           {t('core.help.start')}")
    print(f"  --install [module|all] {t('core.help.install')}")
    print(f"  --info                 {t('core.help.info')}")
    print(f"  --version [force]      {t('core.help.version')}")
    print(f"  --lang [code]          {t('core.help.lang')}")
    print(f"  --license              {t('core.help.license')}")
    print(f"  --help                 {t('core.help.help')}")
    print("")
    installed = get_installed_module_names()
    if installed:
        print(t("core.help.installed"))
        print("-" * 51)
        for name in installed:
            module = load_module(name)
            if not module or not hasattr(module, "MODULE"):
                continue
            commands = module.MODULE.get("commands", {})
            for command, description in commands.items():
                print(f"  {command:<22} {t(description)}")
        print("-" * 51)
        print("")
    else:
        print(t("core.help.no_modules"))
        print(t("core.help.install_hint"))
        print("")
    try:
        update_info = get_update_info()
        available = update_info.get("modules", {})
        uninstalled = [name for name in sorted(available) if name not in installed]
        if uninstalled:
            print(t("core.help.not_installed"))
            print("=" * 51)
            for name in uninstalled:
                info = available[name]
                print(f"  {name:<12} - {info.get('description', '')}")
            print("")
            print(t("core.help.tip_all"))
    except Exception as e:
        print(t("core.help.install_available"))
    print("")


def main():
    global logger, ctx
    logger = setup_logger()
    ctx = CoreContext()
    logger.info(f"Starting {SCRIPT_NAME} version {SCRIPT_VERSION}")
    clear_screen()
    args = sys.argv[1:]
    ensure_script_config()
    resolve_modules_dir()
    if args and args[0] == "--lang" and len(args) > 1:
        load_language(get_script_language())
    elif not SCRIPT_CONFIG_FILE.exists() or not get_script_config().has_option("script", "language"):
        run_language_selection()
    else:
        load_language(get_script_language())
    core_only_commands = ("--help", "--license", "--install", "--version", "--lang")
    is_core_only = bool(args) and args[0] in core_only_commands
    if args and args[0] == "--install":
        try:
            run_install_flow(args[1:], first_run=not is_modules_environment_installed())
            logger.info("Command execution completed")
        except (KeyboardInterrupt, EOFError):
            logger.warning("Script interrupted by user (KeyboardInterrupt)")
            print("\n\n" + t("core.interrupted") + "\n")
        logger.info("Exiting script\n")
        return
    if not is_core_only and not is_modules_environment_installed():
        logger.info("No modules installed, entering first-run install flow")
        try:
            run_install_flow(first_run=True)
        except (KeyboardInterrupt, EOFError):
            logger.warning("Script interrupted by user (KeyboardInterrupt)")
            print("\n\n" + t("core.interrupted") + "\n")
        if not is_modules_environment_installed():
            print(t("core.install.no_modules") + "\n")
            logger.info("Exiting script\n")
            return
    try:
        logger.info("Checking environment...")
        if not check_environment_change():
            logger.warning("Environment check failed or user chose to exit")
            logger.info("Exiting script\n")
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
        elif args[0] == "--lang":
            logger.info("Running language command")
            cmd_lang(args)
        elif args[0] in MODULE_COMMANDS:
            module_name = MODULE_COMMANDS[args[0]]
            logger.info(f"Routing command to module: {module_name}")
            module = load_module(module_name)
            if module and hasattr(module, "dispatch"):
                module.dispatch(args, ctx)
            else:
                print(t("core.module.missing", name=module_name))
                print(t("core.module.install_hint", name=module_name) + "\n")
                sys.exit(1)
        else:
            logger.warning(f"Invalid command: {' '.join(args)}")
            print("\n" + t("core.invalid_command"))
            print(t("core.invalid_use_help", script=SCRIPT_NAME) + "\n")
            sys.exit(1)
        logger.info("Command execution completed")
    except KeyboardInterrupt:
        logger.warning("Script interrupted by user (KeyboardInterrupt)")
        print("\n\n" + t("core.interrupted") + "\n")
        logger.info("Exiting script\n")
        sys.exit(0)
    except SystemExit as e:
        logger.info(f"Script exiting with code: {e.code}\n")
        raise
    except Exception as e:
        logger.error(f"Unexpected error in main(): {e}\n", exc_info=True)
        print(f"\n{t('core.unexpected_error', error=e)}")
        print(t("core.check_log", log=LOG_FILE) + "\n")
        sys.exit(1)
    logger.info("Exiting script\n")

if __name__ == "__main__":
    main()

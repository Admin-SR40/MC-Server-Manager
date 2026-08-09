#!/usr/bin/env python3
# crash module for MC-Server-Manager
# Crash detection, log analysis and structured crash reports.

import os
import sys
import re
import json
import time
import datetime
import platform
import subprocess
import traceback
from collections import deque

MODULE = {
    "name": "crash",
    "version": "1.0",
    "description": "Crash detection, log analysis and crash reports",
    "requires": [],
    "commands": {},
}

BASE_DIR = None
PLUGINS_DIR = None
SERVER_PROPERTIES = None
logger = None
load_config = None
get_device_id = None
get_uptime = None
SCRIPT_VERSION = None
_ctx = None

def bind(ctx):
    global BASE_DIR, PLUGINS_DIR, SERVER_PROPERTIES, logger
    global load_config, get_device_id, get_uptime, SCRIPT_VERSION, _ctx
    BASE_DIR = ctx.BASE_DIR
    PLUGINS_DIR = ctx.PLUGINS_DIR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    load_config = ctx.load_config
    get_device_id = ctx.get_device_id
    get_uptime = ctx.get_uptime
    SCRIPT_VERSION = ctx.SCRIPT_VERSION
    _ctx = ctx

def dispatch(args, ctx):
    pass

def analyze_server_crash(exit_code, uptime_str=None):
    start_time = time.time()
    print("\n" + "=" * 50)
    uptime_seconds, uptime_display, crash_time = get_uptime()
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
        if "Unknown or incomplete command" in line:
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
        plugins_mod = _ctx.get_module("plugins") if _ctx else None
        if plugins_mod is None:
            data['plugin_dependencies'] = {
                'missing_hard': {},
                'missing_soft': {}
            }
            return
        if not PLUGINS_DIR.exists():
            return
        plugin_files = list(PLUGINS_DIR.glob("*.jar"))
        if not plugin_files:
            return
        enabled_plugins = []
        for plugin_path in plugin_files:
            if not plugin_path.name.endswith('.disabled'):
                name, version, main_class = plugins_mod.get_plugin_info(plugin_path)
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
                dependencies = plugins_mod.get_plugin_dependencies(plugin['path'])
                hard_deps_missing = []
                for dep in dependencies.get('depend', []):
                    if not plugins_mod.is_plugin_enabled(dep, enabled_plugins):
                        hard_deps_missing.append(dep)
                soft_deps_missing = []
                for dep in dependencies.get('softdepend', []):
                    if not plugins_mod.is_plugin_enabled(dep, enabled_plugins):
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

def get_environment_info():
    info = {}
    init_mod = _ctx.get_module("init") if _ctx else None
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
            if init_mod:
                version, vendor = init_mod.parse_java_version(output)
            else:
                version, vendor = "Unknown", "Unknown"
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
            total_mem_bytes = init_mod.get_total_memory() if init_mod else 0
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
    if init_mod:
        if init_mod.is_running_in_container():
            container_mem = init_mod.get_container_memory_limit()
            if container_mem:
                container_mem_gb = container_mem / (1024 ** 3)
                info['container_info'] = f"Yes ({container_mem_gb:.1f}GB limit)"
            else:
                info['container_info'] = "Yes"
        else:
            info['container_info'] = "No"
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

def generate_crash_report(report_file, data, log_file, exit_code, uptime_display, crash_time):
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
                    logger.info(f"Environment item: {key}: {value}")
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
                logger.info(f"Writing error context #{i} with {len(context_block)} lines")
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
                logger.info(f"Keyword '{keyword}' found {line_count} times")
                for line_num in lines[:10]:
                    f.write(f" - Line {line_num}\n")
                if len(lines) > 10:
                    additional_count = len(lines) - 10
                    f.write(f" - ... and {additional_count} more\n")
                    logger.info(f"Keyword '{keyword}' has {additional_count} additional occurrences not shown")
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
                                logger.info(f"Plugin '{plugin_name}' missing hard dependencies: {deps}")
                    if missing_soft and isinstance(missing_soft, dict):
                        f.write("\nMissing Soft Dependencies:\n")
                        logger.info(f"Writing {len(missing_soft)} soft dependency issues")
                        for plugin_name, deps in missing_soft.items():
                            if isinstance(deps, list):
                                f.write(f"\nPlugin '{plugin_name}' suggests:\n")
                                for dep in deps:
                                    f.write(f" - {dep}\n")
                                logger.info(f"Plugin '{plugin_name}' missing soft dependencies: {deps}")
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
        traceback.print_exc()
    except Exception as e:
        logger.error(f"Unexpected error generating crash report: {e}", exc_info=True)
        print(f"Error generating crash report: {e}\n")
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
            last_lines = deque(f, maxlen=200)
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
        _, uptime_str, _ = get_uptime()
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

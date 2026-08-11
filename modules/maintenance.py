#!/usr/bin/env python3
# maintenance module for MC-Server-Manager
# File cleanup and log dumping utilities.

import os
import sys
import glob
import gzip
import shutil
import zipfile
import datetime
import traceback

MODULE = {
    "name": "maintenance",
    "version": "1.0",
    "description": "File cleanup and log dump utilities",
    "requires": [],
    "commands": {
        "--cleanup": "cmd.cleanup",
        "--dump": "cmd.dump",
    },
}

BASE_DIR = None
logger = None
create_lock = None
remove_lock = None
safe_rmtree = None
format_file_size = None
_unlock_with_logging = None
t = None


def bind(ctx):
    global BASE_DIR, logger, create_lock, remove_lock
    global safe_rmtree, format_file_size, _unlock_with_logging, t
    BASE_DIR = ctx.BASE_DIR
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    safe_rmtree = ctx.safe_rmtree
    format_file_size = ctx.format_file_size
    _unlock_with_logging = ctx.unlock_with_logging
    t = ctx.t


def dispatch(args, ctx):
    if not args:
        return
    if args[0] == "--cleanup":
        cleanup_files()
    elif args[0] == "--dump":
        dump_logs()


def cleanup_files():
    logger.info("Starting cleanup operation")
    if not create_lock(["--cleanup"]):
        logger.error("Could not create task lock")
        print("\n" + t("maintenance.lock_error") + "\n")
        return
    try:
        print("\n" + t("maintenance.preparing") + "...")
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
            print(t("maintenance.nothing_clean"))
            print("")
            return
        print("\n" + t("maintenance.will_delete"))
        print("=" * 50)
        for file_path in files_to_clean:
            file_size = os.path.getsize(file_path) if os.path.exists(file_path) else 0
            print(f"{file_path} ({file_size} bytes)")
        print("=" * 50)
        total_size = sum(os.path.getsize(f) for f in files_to_clean if os.path.exists(f))
        print(t("maintenance.total_free", size=total_size, mb=total_size // (1024*1024)) + "\n")
        confirm = input(t("maintenance.confirm_delete") + " ").strip().upper() or "N"
        if confirm != "Y":
            print(t("maintenance.canceled") + "\n")
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
                    print(t("maintenance.deleted", path=file_path))
            except Exception as e:
                logger.error(f"Error deleting {file_path}: {e}")
                print(t("maintenance.delete_error", path=file_path, error=e) + "\n")
        logger.info(f"Cleanup completed: deleted {deleted_count} files, freed {freed_space} bytes")
        print("\n" + t("maintenance.completed", count=deleted_count, size=freed_space, mb=freed_space // (1024*1024)) + "\n")
    finally:
        remove_lock()


def dump_logs():
    command = ["--dump"] + sys.argv[2:]
    logger.info(f"Starting dump_logs function with command: {' '.join(command)}")
    if not create_lock(command):
        logger.error("Failed to create lock for dump_logs operation")
        print("\n" + t("maintenance.lock_error") + "\n")
        return
    try:
        logs_dir = BASE_DIR / "logs"
        logger.info(f"Checking logs directory: {logs_dir}")
        if not logs_dir.exists() or not any(logs_dir.iterdir()):
            logger.warning("No log files found to dump")
            print("")
            print(t("maintenance.no_logs"))
            print("")
            return
        search_terms = sys.argv[2:] if len(sys.argv) > 2 else []
        logger.info(f"Search terms: {search_terms}")
        if search_terms:
            logger.info(f"Starting log search with terms: {search_terms}")
            print("\n" + "=" * 45)
            print(t("maintenance.search_title").center(45))
            print("=" * 45)
            print(t("maintenance.searching_for", terms=", ".join(search_terms)))
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
                            print(t("maintenance.found_matches", count=file_matched_lines, path=rel_path))
                    except Exception as e:
                        logger.error(f"Error processing {log_file}: {e}")
                        print(t("maintenance.process_error", path=log_file, error=e))
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
                    print(t("maintenance.dumped_files", count=files_matched))
                    print(t("maintenance.found_lines", lines=total_matched_lines, files=files_matched))
                    print("\n" + t("maintenance.result_saved", name=output_file.name))
                    print(t("maintenance.file_size", size=file_size, mb=file_size // (1024*1024)))
                    print("=" * 45)
                    confirm = input("\n" + t("maintenance.delete_originals") + " ").strip().upper() or "N"
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
                                    print(t("maintenance.delete_log_error", path=log_file, error=e))
                        logger.info(f"Log deletion completed: {deleted_count} files deleted, {format_file_size(freed_space)} freed")
                        print(t("maintenance.deleted_logs", count=deleted_count, size=freed_space))
                    else:
                        logger.info("User chose not to delete original log files")
                else:
                    logger.info("No matching content found in any log files")
                    print("\n" + t("maintenance.no_match"))
                print("")
            except Exception as e:
                logger.error(f"Error creating log search: {e}", exc_info=True)
                print(t("maintenance.dump_error", error=e))
                traceback.print_exc()
            finally:
                if temp_dir.exists():
                    logger.info(f"Cleaning up temporary directory: {temp_dir}")
                    try:
                        safe_rmtree(temp_dir)
                        logger.info(f"Temporary directory removed: {temp_dir}")
                    except Exception as cleanup_error:
                        logger.error(f"Failed to remove temporary directory {temp_dir}: {cleanup_error}")
        else:
            logger.info("Starting full log dump (no search terms)")
            print("\n" + "=" * 45)
            print(t("maintenance.dump_title").center(45))
            print("=" * 45)
            timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = BASE_DIR / f"logs_dump_{timestamp}.zip"
            logger.info(f"Full log dump output file: {output_file}")
            print("\n" + t("maintenance.creating_dump") + "...")
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
                safe_rmtree(temp_dir)
                logger.info(f"Temporary directory cleaned up: {temp_dir}")
                file_size = os.path.getsize(output_file)
                logger.info(f"Full log dump completed: {output_file}, size: {format_file_size(file_size)}")
                print("\n" + "=" * 45)
                print(t("maintenance.dumped_files", count=file_count))
                print(t("maintenance.result_saved", name=output_file.name))
                print(t("maintenance.file_size", size=file_size, mb=file_size // (1024*1024)))
                print("=" * 45)
                confirm = input("\n" + t("maintenance.delete_originals") + " ").strip().upper() or "N"
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
                                print(t("maintenance.delete_log_error", path=file_path, error=e))
                    logger.info(f"Full log deletion completed: {deleted_count} files deleted, {format_file_size(freed_space)} freed")
                    print(t("maintenance.deleted_logs", count=deleted_count, size=freed_space))
                else:
                    logger.info("User chose not to delete original log files")
                print("")
            except Exception as e:
                logger.error(f"Error creating log dump: {e}", exc_info=True)
                print(t("maintenance.dump_error", error=e) + "\n")
                traceback.print_exc()
                if temp_dir.exists():
                    logger.info(f"Cleaning up temporary directory after error: {temp_dir}")
                    safe_rmtree(temp_dir)
    finally:
        _unlock_with_logging("dump_logs")

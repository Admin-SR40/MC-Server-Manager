#!/usr/bin/env python3
# worlds module for MC-Server-Manager
# World management: delete, backup, import and seed configuration.

import os
import sys
import shutil
import zipfile
import datetime
from pathlib import Path

MODULE = {
    "name": "worlds",
    "version": "1.0",
    "description": "Manage worlds (reset, backup, restore, import)",
    "requires": [],
    "commands": {
        "--worlds": "cmd.worlds",
    },
}

BASE_DIR = None
BUNDLES_DIR = None
WORLDS_DIR = None
SERVER_PROPERTIES = None
logger = None
create_lock = None
remove_lock = None
load_config = None
format_file_size = None
t = None
center_text = None


def bind(ctx):
    global BASE_DIR, BUNDLES_DIR, WORLDS_DIR, SERVER_PROPERTIES, logger
    global create_lock, remove_lock, load_config, format_file_size, t, center_text
    BASE_DIR = ctx.BASE_DIR
    BUNDLES_DIR = ctx.BUNDLES_DIR
    WORLDS_DIR = ctx.WORLDS_DIR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    load_config = ctx.load_config
    format_file_size = ctx.format_file_size
    t = ctx.t
    center_text = ctx.center_text


def dispatch(args, ctx):
    if not args or args[0] != "--worlds":
        return
    if len(args) > 1:
        mode = args[1].lower()
        if mode in ("import", "delete", "backup"):
            manage_worlds(mode)
        else:
            print("\n" + t("worlds.invalid_arg", mode=mode))
            print(t("worlds.invalid_arg_hint"))
            print("")
            sys.exit(1)
    else:
        manage_worlds()


def manage_worlds(mode=None):
    if not create_lock(["--worlds"] + ([mode] if mode else [])):
        logger.error("Failed to create lock for world management")
        print("\n" + t("worlds.lock_error") + "\n")
        return
    try:
        logger.info(f"Starting world management utility (mode: {mode})")
        print("\n" + "=" * 52)
        print(center_text(t("worlds.title"), 52))
        print("=" * 52)
        WORLDS_DIR.mkdir(parents=True, exist_ok=True)
        world_folders = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        world_info = []
        total_size = 0
        for world_folder in world_folders:
            try:
                world_size = sum(f.stat().st_size for f in world_folder.rglob('*') if f.is_file())
                status = "OK" if (world_folder / "level.dat").exists() else "CORRUPTED"
                world_info.append((world_folder, world_size, status))
                total_size += world_size
                logger.info(f"World found: {world_folder.name}, size: {world_size} bytes, status: {status}")
            except Exception as e:
                world_info.append((world_folder, 0, "ERROR"))
                logger.error(f"Error reading world folder {world_folder.name}: {e}")
                print(t("worlds.read_error", name=world_folder.name, error=e))
        world_info.sort(key=lambda x: x[1], reverse=True)
        name_width = 25
        size_width = 11
        status_width = 12
        print(center_text(t("worlds.table_title"), 30))
        print("╔" + "═" * name_width + "╦" + "═" * size_width + "╦" + "═" * status_width + "╗")
        print("║" + (" " + t("worlds.col_worlds")).ljust(name_width) +
              "║" + (" " + t("worlds.col_size")).ljust(size_width) +
              "║" + (" " + t("worlds.col_status")).ljust(status_width) + "║")
        print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
        if world_info:
            for i, (world_folder, size, status) in enumerate(world_info, 1):
                name_display = f"{i}. {world_folder.name}"
                print(f"║ {name_display:<{name_width - 1}}"
                      f"║ {format_file_size(size):<{size_width - 1}}"
                      f"║ {status:<{status_width - 1}}║")
            print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
            print(f"║ {'0. ' + t('worlds.all'):<{name_width - 1}}║ {format_file_size(total_size):<{size_width - 1}}║ {t('worlds.all_worlds'):<{status_width - 1}}║")
        else:
            print(f"║ {t('worlds.no_worlds'):<{name_width - 1}}║ {'0 B':<{size_width - 1}}║ {t('worlds.none'):<{status_width - 1}}║")
        print("╚" + "═" * name_width + "╩" + "═" * size_width + "╩" + "═" * status_width + "╝")
        logger.info(f"Total world size: {format_file_size(total_size)} across {len(world_info)} worlds")
        if mode == 'import':
            logger.info("Direct import mode")
            import_world()
        elif mode == 'delete':
            logger.info("Direct delete mode")
            if not world_folders:
                print("\n" + t("worlds.no_delete") + "\n")
                return
            delete_worlds(world_info)
        elif mode == 'backup':
            logger.info("Direct backup mode")
            if not world_folders:
                print("\n" + t("worlds.no_backup") + "\n")
                return
            backup_worlds(world_info)
        else:
            logger.info("Interactive mode")
            print("\n" + t("worlds.operations"))
            print(" 1. " + t("worlds.op_delete"))
            print(" 2. " + t("worlds.op_backup"))
            print(" 3. " + t("worlds.op_import"))
            print(" 4. " + t("worlds.op_seed"))
            try:
                operation_choice = input("\n" + t("worlds.select_op") + " ").strip()
                if not operation_choice:
                    logger.info("User cancelled operation selection")
                    print(t("worlds.no_op") + "\n")
                    return
                logger.info(f"User selected operation: {operation_choice}")
                if operation_choice == "1":
                    delete_worlds(world_info)
                elif operation_choice == "2":
                    backup_worlds(world_info)
                elif operation_choice == "3":
                    import_world()
                elif operation_choice == "4":
                    configure_world_seed()
                else:
                    logger.warning(f"Invalid operation selection: {operation_choice}")
                    print(t("worlds.invalid_op") + "\n")
                    return
            except KeyboardInterrupt:
                logger.info("World management operation interrupted by user")
                print("\n" + t("worlds.cancelled") + "\n")
            except Exception as e:
                logger.error(f"Error during world operation: {e}")
                print(t("worlds.op_error", error=e) + "\n")
    finally:
        if remove_lock():
            logger.info("World management lock released")
        else:
            logger.error("Failed to remove world management lock")


def delete_worlds(world_info):
    try:
        logger.info("Starting world deletion process")
        selection = input("\n" + t("worlds.select_delete") + " ").strip()
        if not selection:
            logger.info("User cancelled world deletion")
            print(t("worlds.no_selection") + "\n")
            return
        logger.info(f"User selection for deletion: {selection}")
        selected_indices = []
        for num_str in selection.split():
            try:
                num = int(num_str)
                if 0 <= num <= len(world_info):
                    selected_indices.append(num)
                else:
                    logger.warning(f"Invalid number in selection: {num}")
                    print(t("worlds.invalid_number", num=num))
                    return
            except ValueError:
                logger.error(f"Invalid input in selection: {num_str}")
                print(t("worlds.invalid_input", value=num_str))
                return
        logger.info(f"Parsed indices for deletion: {selected_indices}")
        if 0 in selected_indices:
            logger.warning("User selected to delete ALL worlds")
            confirm = input("\n" + t("worlds.confirm_delete_all") + " (y/N): ").strip().upper() or "N"
            if confirm != "Y":
                logger.info("User cancelled deletion of all worlds")
                print(t("worlds.cancelled") + "\n")
                return
            logger.info("User confirmed deletion of all worlds")
            deleted_count = 0
            total_freed = 0
            for world_folder, size, _ in world_info:
                try:
                    shutil.rmtree(world_folder)
                    deleted_count += 1
                    total_freed += size
                    logger.info(f"Deleted world: {world_folder.name} ({format_file_size(size)})")
                    print(t("worlds.deleted", name=world_folder.name))
                except Exception as e:
                    logger.error(f"Error deleting world {world_folder.name}: {e}")
                    print(t("worlds.delete_error", name=world_folder.name, error=e))
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(total_freed)}")
            print("\n" + t("worlds.all_deleted"))
            print(t("worlds.deleted_count", count=deleted_count, size=format_file_size(total_freed)))
        else:
            worlds_to_delete = [world_info[i - 1][0] for i in selected_indices]
            delete_sizes = [world_info[i - 1][1] for i in selected_indices]
            total_delete_size = sum(delete_sizes)
            logger.info(f"User selected {len(worlds_to_delete)} worlds for deletion")
            print("\n" + t("worlds.selected_delete"))
            for i, w in enumerate(worlds_to_delete):
                size = delete_sizes[i]
                print(f" - {w.name} ({format_file_size(size)})")
            logger.info(f"Total size to delete: {format_file_size(total_delete_size)}")
            confirm = input("\n" + t("worlds.confirm_delete") + " (y/N): ").strip().upper() or "N"
            if confirm != "Y":
                logger.info("User cancelled deletion of selected worlds")
                print(t("worlds.cancelled") + "\n")
                return
            logger.info("User confirmed deletion of selected worlds")
            deleted_count = 0
            freed_space = 0
            for i, w in enumerate(worlds_to_delete):
                try:
                    size = delete_sizes[i]
                    shutil.rmtree(w)
                    deleted_count += 1
                    freed_space += size
                    logger.info(f"Deleted world: {w.name} ({format_file_size(size)})")
                    print(t("worlds.deleted", name=w.name))
                except Exception as e:
                    logger.error(f"Error deleting world {w.name}: {e}")
                    print(t("worlds.delete_error", name=w.name, error=e))
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(freed_space)}")
            print("\n" + t("worlds.deleted_selected"))
            print(t("worlds.deleted_selected_count", count=deleted_count, size=format_file_size(freed_space)))
        remaining = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        logger.info(f"Remaining worlds after deletion: {len(remaining)}")
        if not remaining:
            logger.info("All world folders have been removed")
            choice = input("\n" + t("worlds.after_delete_seed") + " (y/N): ").strip().upper() or "N"
            if choice == "Y":
                logger.info("User chose to configure new world seed")
                configure_world_seed()
            else:
                logger.info("User skipped seed configuration")
                print(t("worlds.skip_seed") + "\n")
        else:
            logger.info(f"{len(remaining)} world folders remain")
            print(t("worlds.skip_seed_remain") + "\n")
    except KeyboardInterrupt:
        logger.info("World deletion operation interrupted by user")
        print("\n" + t("worlds.cancelled") + "\n")
    except Exception as e:
        logger.error(f"Error in delete_worlds(): {e}")
        print(t("worlds.op_error", error=e) + "\n")


def backup_worlds(world_info):
    try:
        logger.info("Starting world backup process")
        config = load_config()
        current_version = config.get("version", "unknown")
        logger.info(f"Current server version for backup: {current_version}")
    except Exception as e:
        logger.error(f"Error loading config for backup: {e}")
        print(t("worlds.config_error_backup") + "\n")
        return
    selection = input("\n" + t("worlds.select_backup") + " ").strip()
    if not selection:
        logger.info("User cancelled backup selection")
        print(t("worlds.no_selection") + "\n")
        return
    logger.info(f"User backup selection: {selection}")
    selected_indices = []
    for num_str in selection.split():
        try:
            num = int(num_str)
            if 0 <= num <= len(world_info):
                selected_indices.append(num)
            else:
                logger.warning(f"Invalid number in backup selection: {num}")
                print(t("worlds.invalid_number", num=num))
                return
        except ValueError:
            logger.error(f"Invalid input in backup selection: {num_str}")
            print(t("worlds.invalid_input", value=num_str))
            return
    logger.info(f"Parsed backup indices: {selected_indices}")
    if 0 in selected_indices:
        worlds_to_backup = [world_info[i][0] for i in range(len(world_info))]
        print("\n" + t("worlds.selected_all"))
    else:
        worlds_to_backup = [world_info[i - 1][0] for i in selected_indices]
        print("\n" + t("worlds.selected_list"))
    backup_sizes = []
    for w in worlds_to_backup:
        size = sum(f.stat().st_size for f in w.rglob('*') if f.is_file())
        backup_sizes.append(size)
        print(f" - {w.name} ({format_file_size(size)})")
    total_backup_size = sum(backup_sizes)
    logger.info(f"Total size to backup: {format_file_size(total_backup_size)} for {len(worlds_to_backup)} worlds")
    confirm = input("\n" + t("worlds.confirm_backup") + " (y/N): ").strip().upper() or "N"
    if confirm != "Y":
        logger.info("User cancelled backup")
        print(t("worlds.cancelled") + "\n")
        return
    logger.info("User confirmed backup")
    backup_dir = BUNDLES_DIR / current_version / "worlds"
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"worlds_{timestamp}.zip"
    backup_path = backup_dir / backup_filename
    logger.info(f"Creating backup at: {backup_path}")
    print("\n" + t("worlds.backup_path", path=backup_path))
    try:
        with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for world_folder in worlds_to_backup:
                if not world_folder.exists():
                    logger.warning(f"World folder {world_folder.name} does not exist, skipping")
                    print(t("worlds.warn_missing", name=world_folder.name))
                    continue
                logger.info(f"Adding world to backup: {world_folder.name}")
                print(t("worlds.adding", name=world_folder.name))
                for root, _, files in os.walk(world_folder):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.join(world_folder.name, os.path.relpath(file_path, world_folder))
                        zipf.write(file_path, arcname)
        file_size = os.path.getsize(backup_path)
        logger.info(f"Backup created successfully: {backup_path}, size: {format_file_size(file_size)}")
        print("\n" + t("worlds.backup_success", path=backup_path))
        print(t("worlds.file_size", size=format_file_size(file_size)))
        print(t("worlds.worlds_backed", count=len(worlds_to_backup)))
        print("")
    except Exception as e:
        logger.error(f"Error creating backup: {e}")
        print(t("worlds.backup_error", error=e) + "\n")
        if backup_path.exists():
            try:
                backup_path.unlink()
                logger.info("Removed incomplete backup file")
            except:
                logger.warning("Could not remove incomplete backup file")


def import_world():
    logger.info("Starting world import utility")
    print("\n" + "=" * 50)
    print(center_text(t("worlds.import_title"), 50))
    print("=" * 50)
    while True:
        zip_path_input = input("\n" + t("worlds.enter_zip") + " ").strip()
        if not zip_path_input:
            logger.info("User cancelled world import")
            print(t("worlds.cancelled") + "\n")
            return
        if zip_path_input.startswith('"') and zip_path_input.endswith('"'):
            zip_path_input = zip_path_input[1:-1]
            logger.info("Stripped surrounding quotes from path")
        if zip_path_input.startswith("."):
            zip_path = (BASE_DIR / zip_path_input).resolve()
            logger.info(f"Detected relative path, converted to absolute: {zip_path}")
        else:
            zip_path = Path(zip_path_input).resolve()
        logger.info(f"Final resolved zip path: {zip_path}")
        if not zip_path.exists():
            logger.error(f"File not found: {zip_path}")
            print(t("worlds.file_not_found", path=zip_path))
            continue
        if zip_path.suffix.lower() != ".zip":
            logger.error(f"File is not a ZIP archive: {zip_path}")
            print(t("worlds.not_zip"))
            continue
        logger.info(f"Valid zip file found: {zip_path}")
        break
    logger.info(f"Reading archive: {zip_path}")
    print("\n" + t("worlds.reading", name=zip_path.name))
    try:
        with zipfile.ZipFile(zip_path, "r") as zipf:
            world_candidates = set()
            for name in zipf.namelist():
                if name.endswith("/"):
                    continue
                parts = name.split("/")
                if len(parts) >= 2 and parts[-1] == "level.dat":
                    world_candidates.add(parts[0])
            logger.info(f"Found {len(world_candidates)} world candidates in archive")
            if not world_candidates:
                logger.error("No valid worlds found in archive")
                print(t("worlds.no_valid_worlds"))
                print(t("worlds.valid_hint") + "\n")
                return
            print(t("worlds.found_worlds", count=len(world_candidates)))
            for i, world_name in enumerate(world_candidates, 1):
                print(f" {i}. {world_name}")
            existing_worlds = [d.name for d in WORLDS_DIR.iterdir() if d.is_dir()]
            conflicting_worlds = [w for w in world_candidates if w in existing_worlds]
            logger.info(f"Conflicting worlds: {conflicting_worlds}")
            if conflicting_worlds:
                print("\n" + t("worlds.existing_warning"))
                for world in conflicting_worlds:
                    print(f" - {world}")
                replace_choice = input("\n" + t("worlds.replace_ask") + " (y/N): ").strip().upper() or "N"
                if replace_choice != "Y":
                    logger.info("User chose not to replace existing worlds")
                    print(t("worlds.import_canceled") + "\n")
                    return
                logger.info("User confirmed replacement of existing worlds")
                for world_name in conflicting_worlds:
                    world_path = WORLDS_DIR / world_name
                    try:
                        shutil.rmtree(world_path)
                        logger.info(f"Removed existing world: {world_name}")
                        print(t("worlds.removed", name=world_name))
                    except Exception as e:
                        logger.error(f"Error removing {world_name}: {e}")
                        print(t("worlds.remove_error", name=world_name, error=e))
            print("\n" + t("worlds.extracting"))
            extracted_count = 0
            for world_name in world_candidates:
                world_path = WORLDS_DIR / world_name
                world_path.mkdir(parents=True, exist_ok=True)
                for name in zipf.namelist():
                    if name.startswith(world_name + "/"):
                        relative_path = name[len(world_name) + 1 :]
                        if not relative_path:
                            continue
                        target_path = world_path / relative_path
                        target_path.parent.mkdir(parents=True, exist_ok=True)
                        if not name.endswith("/"):
                            with zipf.open(name) as source, open(target_path, "wb") as target:
                                shutil.copyfileobj(source, target)
                if (world_path / "level.dat").exists():
                    world_size = sum(
                        f.stat().st_size for f in world_path.rglob("*") if f.is_file()
                    )
                    logger.info(f"Imported world: {world_name}")
                    print(t("worlds.imported", name=world_name, size=format_file_size(world_size)))
                    extracted_count += 1
                else:
                    logger.warning(f"Invalid world (missing level.dat): {world_name}")
                    print(t("worlds.invalid_world", name=world_name))
                    shutil.rmtree(world_path, ignore_errors=True)
            print("\n" + t("worlds.import_success", count=extracted_count) + "\n")
            logger.info(f"World import completed: {extracted_count} worlds imported")
    except Exception as e:
        logger.error(f"Error importing world: {e}", exc_info=True)
        print(t("worlds.import_error", error=e) + "\n")


def configure_world_seed():
    logger.info("Starting world seed configuration")
    if not SERVER_PROPERTIES.exists():
        logger.info("Server properties file not found, creating default")
        print(t("worlds.seed_not_found") + "\n")
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
                logger.info(f"Current seed found: '{current_seed}'")
                break
    logger.info("Presenting seed configuration options to user")
    print("\n" + t("worlds.seed_options"))
    print(" 1. " + t("worlds.keep_seed"))
    print(" 2. " + t("worlds.random_seed"))
    print(" 3. " + t("worlds.custom_seed"))
    while True:
        try:
            option = input("\n" + t("worlds.your_option") + " ").strip()
            logger.info(f"User selected seed option: {option}")
            
            if option == "1":
                logger.info(f"Keeping current seed: '{current_seed}'")
                print(t("worlds.keeping") + "...")
                break
            elif option == "2":
                logger.info("Using random seed")
                print(t("worlds.random") + "...")
                current_seed = ""
                break
            elif option == "3":
                new_seed = input(t("worlds.enter_seed") + " ").strip()
                if new_seed:
                    logger.info(f"User set custom seed: '{new_seed}'")
                    current_seed = new_seed
                    print(t("worlds.seed_set", seed=current_seed))
                    break
                else:
                    logger.warning("User entered empty seed")
                    print(t("worlds.seed_empty") + "\n")
            else:
                logger.warning(f"Invalid seed option: {option}")
                print(t("worlds.seed_invalid") + "\n")
        except KeyboardInterrupt:
            logger.info("Seed configuration cancelled by user")
            print("\n" + t("worlds.seed_cancelled") + "\n")
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
    try:
        with open(SERVER_PROPERTIES, 'w') as f:
            f.writelines(new_properties_content)
        logger.info(f"World seed configured successfully: '{current_seed}'")
        print("\n" + t("worlds.seed_success"))
        print(t("worlds.seed_future"))
        print("")
    except Exception as e:
        logger.error(f"Error saving world seed configuration: {e}")
        print(t("worlds.seed_error", error=e) + "\n")

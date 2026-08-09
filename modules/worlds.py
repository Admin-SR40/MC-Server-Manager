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
        "--worlds": "Manage worlds (delete, backup, import, seed)",
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


def bind(ctx):
    global BASE_DIR, BUNDLES_DIR, WORLDS_DIR, SERVER_PROPERTIES, logger
    global create_lock, remove_lock, load_config, format_file_size
    BASE_DIR = ctx.BASE_DIR
    BUNDLES_DIR = ctx.BUNDLES_DIR
    WORLDS_DIR = ctx.WORLDS_DIR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    create_lock = ctx.create_lock
    remove_lock = ctx.remove_lock
    load_config = ctx.load_config
    format_file_size = ctx.format_file_size


def dispatch(args, ctx):
    if not args or args[0] != "--worlds":
        return
    if len(args) > 1:
        mode = args[1].lower()
        if mode in ("import", "delete", "backup"):
            manage_worlds(mode)
        else:
            print(f"\nInvalid argument for --worlds: {mode}")
            print("Available arguments: import, delete, backup")
            print("")
            sys.exit(1)
    else:
        manage_worlds()


def manage_worlds(mode=None):
    if not create_lock(["--worlds"] + ([mode] if mode else [])):
        logger.error("Failed to create lock for world management")
        print("\nError: Could not create task lock\n")
        return
    try:
        logger.info(f"Starting world management utility (mode: {mode})")
        print("\n" + "=" * 52)
        print("                World Management Utility")
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
                print(f"Error reading {world_folder.name}: {e}")
        world_info.sort(key=lambda x: x[1], reverse=True)
        name_width = 25
        size_width = 11
        status_width = 12
        print("                - Existing Worlds -")
        print("╔" + "═" * name_width + "╦" + "═" * size_width + "╦" + "═" * status_width + "╗")
        print("║" + " Worlds".ljust(name_width - 1) +
              " ║" + " Size".ljust(size_width - 1) +
              " ║" + " Status".ljust(status_width - 1) + " ║")
        print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
        if world_info:
            for i, (world_folder, size, status) in enumerate(world_info, 1):
                name_display = f"{i}. {world_folder.name}"
                print(f"║ {name_display:<{name_width - 1}}"
                      f"║ {format_file_size(size):<{size_width - 1}}"
                      f"║ {status:<{status_width - 1}}║")
            print("╠" + "═" * name_width + "╬" + "═" * size_width + "╬" + "═" * status_width + "╣")
            print(f"║ {'0. All':<{name_width - 1}}║ {format_file_size(total_size):<{size_width - 1}}║ {'All Worlds':<{status_width - 1}}║")
        else:
            print(f"║ {'No worlds found.':<{name_width - 1}}║ {'0 B':<{size_width - 1}}║ {'N/A':<{status_width - 1}}║")
        print("╚" + "═" * name_width + "╩" + "═" * size_width + "╩" + "═" * status_width + "╝")
        logger.info(f"Total world size: {format_file_size(total_size)} across {len(world_info)} worlds")
        if mode == 'import':
            logger.info("Direct import mode")
            import_world()
        elif mode == 'delete':
            logger.info("Direct delete mode")
            if not world_folders:
                print("\nNo world folders found. Nothing to delete.\n")
                return
            delete_worlds(world_info)
        elif mode == 'backup':
            logger.info("Direct backup mode")
            if not world_folders:
                print("\nNo world folders found. Nothing to backup.\n")
                return
            backup_worlds(world_info)
        else:
            logger.info("Interactive mode")
            print("\nAvailable operations:")
            print(" 1. Delete worlds")
            print(" 2. Backup worlds")
            print(" 3. Import worlds")
            print(" 4. Configure world seed")
            try:
                operation_choice = input("\nSelect operation (1-4): ").strip()
                if not operation_choice:
                    logger.info("User cancelled operation selection")
                    print("No operation selected. Operation canceled.\n")
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
                    print("Invalid operation selection.\n")
                    return
            except KeyboardInterrupt:
                logger.info("World management operation interrupted by user")
                print("\nOperation canceled by user.\n")
            except Exception as e:
                logger.error(f"Error during world operation: {e}")
                print(f"Error during world operation: {e}\n")
    finally:
        if remove_lock():
            logger.info("World management lock released")
        else:
            logger.error("Failed to remove world management lock")


def delete_worlds(world_info):
    try:
        logger.info("Starting world deletion process")
        selection = input("\nSelect world folders to delete (space-separated numbers, 0 for all): ").strip()
        if not selection:
            logger.info("User cancelled world deletion")
            print("No selection made. Operation canceled.\n")
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
                    print(f"Invalid number: {num}")
                    return
            except ValueError:
                logger.error(f"Invalid input in selection: {num_str}")
                print(f"Invalid input: {num_str}")
                return
        logger.info(f"Parsed indices for deletion: {selected_indices}")
        if 0 in selected_indices:
            logger.warning("User selected to delete ALL worlds")
            confirm = input("\nAre you sure you want to delete ALL world folders?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                logger.info("User cancelled deletion of all worlds")
                print("Operation canceled.\n")
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
                    print(f"Deleted: {world_folder.name}")
                except Exception as e:
                    logger.error(f"Error deleting world {world_folder.name}: {e}")
                    print(f"Error deleting {world_folder.name}: {e}")
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(total_freed)}")
            print(f"\nAll world folders deleted successfully.")
            print(f"Deleted {deleted_count} worlds, freed {format_file_size(total_freed)}")
        else:
            worlds_to_delete = [world_info[i - 1][0] for i in selected_indices]
            delete_sizes = [world_info[i - 1][1] for i in selected_indices]
            total_delete_size = sum(delete_sizes)
            logger.info(f"User selected {len(worlds_to_delete)} worlds for deletion")
            print("\nYou have selected the following world(s) to delete:")
            for i, w in enumerate(worlds_to_delete):
                size = delete_sizes[i]
                print(f" - {w.name} ({format_file_size(size)})")
            logger.info(f"Total size to delete: {format_file_size(total_delete_size)}")
            confirm = input("\nAre you sure you want to delete these world(s)?\nThis cannot be undone! (Y/N): ").strip().upper()
            if confirm != "Y":
                logger.info("User cancelled deletion of selected worlds")
                print("Operation canceled.\n")
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
                    print(f"Deleted: {w.name}")
                except Exception as e:
                    logger.error(f"Error deleting world {w.name}: {e}")
                    print(f"Error deleting {w.name}: {e}")
            logger.info(f"Deleted {deleted_count} worlds, freed {format_file_size(freed_space)}")
            print(f"\nSelected world(s) deleted successfully.")
            print(f"Deleted {deleted_count} worlds, freed {format_file_size(freed_space)}")
        remaining = [d for d in WORLDS_DIR.iterdir() if d.is_dir()]
        logger.info(f"Remaining worlds after deletion: {len(remaining)}")
        if not remaining:
            logger.info("All world folders have been removed")
            choice = input("\nAll world folders have been removed.\nDo you want to configure a new world seed now? (Y/N): ").strip().upper()
            if choice == "Y":
                logger.info("User chose to configure new world seed")
                configure_world_seed()
            else:
                logger.info("User skipped seed configuration")
                print("Skipped seed configuration.\n")
        else:
            logger.info(f"{len(remaining)} world folders remain")
            print("Some world folders remain. Skipping seed configuration.\n")
    except KeyboardInterrupt:
        logger.info("World deletion operation interrupted by user")
        print("\nOperation canceled by user.\n")
    except Exception as e:
        logger.error(f"Error in delete_worlds(): {e}")
        print(f"Error: {e}\n")


def backup_worlds(world_info):
    try:
        logger.info("Starting world backup process")
        config = load_config()
        current_version = config.get("version", "unknown")
        logger.info(f"Current server version for backup: {current_version}")
    except Exception as e:
        logger.error(f"Error loading config for backup: {e}")
        print("Error: Could not determine current server version for backup.\n")
        return
    selection = input("\nSelect world folders to backup (space-separated numbers, 0 for all): ").strip()
    if not selection:
        logger.info("User cancelled backup selection")
        print("No selection made. Operation canceled.\n")
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
                print(f"Invalid number: {num}")
                return
        except ValueError:
            logger.error(f"Invalid input in backup selection: {num_str}")
            print(f"Invalid input: {num_str}")
            return
    logger.info(f"Parsed backup indices: {selected_indices}")
    if 0 in selected_indices:
        worlds_to_backup = [world_info[i][0] for i in range(len(world_info))]
        print("\nYou have selected ALL worlds to backup:")
    else:
        worlds_to_backup = [world_info[i - 1][0] for i in selected_indices]
        print("\nYou have selected the following world(s) to backup:")
    backup_sizes = []
    for w in worlds_to_backup:
        size = sum(f.stat().st_size for f in w.rglob('*') if f.is_file())
        backup_sizes.append(size)
        print(f" - {w.name} ({format_file_size(size)})")
    total_backup_size = sum(backup_sizes)
    logger.info(f"Total size to backup: {format_file_size(total_backup_size)} for {len(worlds_to_backup)} worlds")
    confirm = input("\nProceed with backup? (Y/N): ").strip().upper()
    if confirm != "Y":
        logger.info("User cancelled backup")
        print("Operation canceled.\n")
        return
    logger.info("User confirmed backup")
    backup_dir = BUNDLES_DIR / current_version / "worlds"
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_filename = f"worlds_{timestamp}.zip"
    backup_path = backup_dir / backup_filename
    logger.info(f"Creating backup at: {backup_path}")
    print(f"\nCreating backup: {backup_path}")
    try:
        with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for world_folder in worlds_to_backup:
                if not world_folder.exists():
                    logger.warning(f"World folder {world_folder.name} does not exist, skipping")
                    print(f"Warning: World folder {world_folder.name} does not exist, skipping.")
                    continue
                logger.info(f"Adding world to backup: {world_folder.name}")
                print(f"Adding: {world_folder.name}")
                for root, _, files in os.walk(world_folder):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.join(world_folder.name, os.path.relpath(file_path, world_folder))
                        zipf.write(file_path, arcname)
        file_size = os.path.getsize(backup_path)
        logger.info(f"Backup created successfully: {backup_path}, size: {format_file_size(file_size)}")
        print(f"\nBackup created successfully: {backup_path}")
        print(f"File size: {format_file_size(file_size)}")
        print(f"Worlds backed up: {len(worlds_to_backup)}")
        print("")
    except Exception as e:
        logger.error(f"Error creating backup: {e}")
        print(f"Error creating backup: {e}\n")
        if backup_path.exists():
            try:
                backup_path.unlink()
                logger.info("Removed incomplete backup file")
            except:
                logger.warning("Could not remove incomplete backup file")


def import_world():
    logger.info("Starting world import utility")
    print("\n" + "=" * 50)
    print("               World Import Utility")
    print("=" * 50)
    while True:
        zip_path_input = input("\nEnter the path to the world backup ZIP file: ").strip()
        if not zip_path_input:
            logger.info("User cancelled world import")
            print("Operation canceled.\n")
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
            print(f"Error: File not found: {zip_path}")
            continue
        if zip_path.suffix.lower() != ".zip":
            logger.error(f"File is not a ZIP archive: {zip_path}")
            print("Error: File must be a ZIP archive.")
            continue
        logger.info(f"Valid zip file found: {zip_path}")
        break
    logger.info(f"Reading archive: {zip_path}")
    print(f"\nReading archive: {zip_path.name}")
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
                print("Error: No valid worlds found in the archive.")
                print("A valid world must contain a level.dat file.\n")
                return
            print(f"Found {len(world_candidates)} world(s) in archive:")
            for i, world_name in enumerate(world_candidates, 1):
                print(f" {i}. {world_name}")
            existing_worlds = [d.name for d in WORLDS_DIR.iterdir() if d.is_dir()]
            conflicting_worlds = [w for w in world_candidates if w in existing_worlds]
            logger.info(f"Conflicting worlds: {conflicting_worlds}")
            if conflicting_worlds:
                print("\nWarning: The following worlds already exist:")
                for world in conflicting_worlds:
                    print(f" - {world}")
                replace_choice = input("\nReplace existing worlds? (Y/N): ").strip().upper()
                if replace_choice != "Y":
                    logger.info("User chose not to replace existing worlds")
                    print("Import canceled.\n")
                    return
                logger.info("User confirmed replacement of existing worlds")
                for world_name in conflicting_worlds:
                    world_path = WORLDS_DIR / world_name
                    try:
                        shutil.rmtree(world_path)
                        logger.info(f"Removed existing world: {world_name}")
                        print(f"Removed existing world: {world_name}")
                    except Exception as e:
                        logger.error(f"Error removing {world_name}: {e}")
                        print(f"Error removing {world_name}: {e}")
            print("\nExtracting worlds.")
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
                    print(f" - Imported: {world_name} ({format_file_size(world_size)})")
                    extracted_count += 1
                else:
                    logger.warning(f"Invalid world (missing level.dat): {world_name}")
                    print(f" - Invalid world (missing level.dat): {world_name}")
                    shutil.rmtree(world_path, ignore_errors=True)
            print(f"\nSuccessfully imported {extracted_count} world(s).\n")
            logger.info(f"World import completed: {extracted_count} worlds imported")
    except Exception as e:
        logger.error(f"Error importing world: {e}", exc_info=True)
        print(f"Error importing world: {e}\n")


def configure_world_seed():
    logger.info("Starting world seed configuration")
    if not SERVER_PROPERTIES.exists():
        logger.info("Server properties file not found, creating default")
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
                logger.info(f"Current seed found: '{current_seed}'")
                break
    logger.info("Presenting seed configuration options to user")
    print("\nTo generate new worlds, there are 3 options for the seed:")
    print(" 1. Keep the current seed")
    print(" 2. Use a random seed")
    print(" 3. Set a custom seed")
    while True:
        try:
            option = input("\nYour option (1-3): ").strip()
            logger.info(f"User selected seed option: {option}")
            
            if option == "1":
                logger.info(f"Keeping current seed: '{current_seed}'")
                print("Keeping current seed...")
                break
            elif option == "2":
                logger.info("Using random seed")
                print("Using random seed...")
                current_seed = ""
                break
            elif option == "3":
                new_seed = input("Enter your seed: ").strip()
                if new_seed:
                    logger.info(f"User set custom seed: '{new_seed}'")
                    current_seed = new_seed
                    print(f"Seed set to: {current_seed}")
                    break
                else:
                    logger.warning("User entered empty seed")
                    print("Seed cannot be empty. Please try again.\n")
            else:
                logger.warning(f"Invalid seed option: {option}")
                print("Invalid option. Please choose 1, 2, or 3.\n")
        except KeyboardInterrupt:
            logger.info("Seed configuration cancelled by user")
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
    try:
        with open(SERVER_PROPERTIES, 'w') as f:
            f.writelines(new_properties_content)
        logger.info(f"World seed configured successfully: '{current_seed}'")
        print("\nSuccessfully configured world seed.")
        print("New worlds will be generated with the specified seed when server starts.")
        print("")
    except Exception as e:
        logger.error(f"Error saving world seed configuration: {e}")
        print(f"Error saving world seed configuration: {e}\n")

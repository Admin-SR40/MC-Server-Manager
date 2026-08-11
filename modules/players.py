#!/usr/bin/env python3
# players module for MC-Server-Manager
# Manage banned players, banned IPs and whitelist.

import os
import re
import json
import hashlib
import datetime
import urllib.request
import urllib.error
import socket
from pathlib import Path

MODULE = {
    "name": "players",
    "version": "1.0",
    "description": "Manage banned players, IP bans and whitelist",
    "requires": [],
    "commands": {
        "--players": "cmd.players",
    },
}

BASE_DIR = None
SERVER_PROPERTIES = None
logger = None
truncate_text = None
t = None
center_text = None
pad_text = None


def bind(ctx):
    global BASE_DIR, SERVER_PROPERTIES, logger, truncate_text, t, center_text, pad_text
    BASE_DIR = ctx.BASE_DIR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    truncate_text = ctx.truncate_text
    t = ctx.t
    center_text = ctx.center_text
    pad_text = ctx.pad_text


def dispatch(args, ctx):
    if args and args[0] == "--players":
        manage_player_lists()


def generate_offline_uuid(username: str) -> str:
    data = f"OfflinePlayer:{username}".encode('utf-8')
    md5_bytes = hashlib.md5(data).digest()
    b = bytearray(md5_bytes)
    b[6] = (b[6] & 0x0f) | 0x30
    b[8] = (b[8] & 0x3f) | 0x80
    hex_str = b.hex()
    uuid_str = f"{hex_str[0:8]}-{hex_str[8:12]}-{hex_str[12:16]}-{hex_str[16:20]}-{hex_str[20:32]}"
    return uuid_str


def format_uuid(uuid_str):
    if len(uuid_str) == 32 and '-' not in uuid_str:
        return f"{uuid_str[:8]}-{uuid_str[8:12]}-{uuid_str[12:16]}-{uuid_str[16:20]}-{uuid_str[20:32]}"
    return uuid_str


def get_mojang_uuid(username):
    logger.info(f"Fetching Mojang UUID for username: {username}")
    try:
        url = f"https://api.mojang.com/users/profiles/minecraft/{username}"
        logger.info(f"Making API request to: {url}")
        with urllib.request.urlopen(url, timeout=10) as response:
            logger.info(f"API response received - Status: {response.status}")
            data = json.loads(response.read().decode())
            uuid = data.get("id")
            actual_name = data.get("name", username)
            if uuid:
                formatted_uuid = format_uuid(uuid)
                logger.info(f"Successfully fetched UUID for '{username}': {formatted_uuid}, name: {actual_name}")
                return formatted_uuid, actual_name
            else:
                logger.warning(f"No UUID found in API response for username: {username}")
                return None, username                
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error fetching UUID for '{username}' - HTTP {e.code}: {e.reason}")
        return None, username
    except urllib.error.URLError as e:
        logger.error(f"URL error fetching UUID for '{username}' - {e.reason}")
        return None, username
    except socket.timeout as e:
        logger.error(f"Timeout error fetching UUID for '{username}' - Connection timed out")
        return None, username
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error fetching UUID for '{username}' - {e}")
        return None, username
    except Exception as e:
        logger.error(f"Unexpected error fetching UUID for '{username}' - {type(e).__name__}: {e}")
        return None, username


def is_online_mode():
    if not SERVER_PROPERTIES.exists():
        logger.warning("server.properties file not found, using default online-mode=true")
        return True
    try:
        logger.info("Checking online-mode in server.properties")
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                if line.strip().startswith('online-mode='):
                    value = line.split('=', 1)[1].strip().lower()
                    is_online = value == 'true'
                    logger.info(f"Online mode setting found: {value} -> is_online={is_online}")
                    return is_online
        logger.info("Online mode setting not found in server.properties, using default (true)")
        return True
    except Exception as e:
        logger.error(f"Error reading online-mode from server.properties: {e}")
        print(t("players.properties_error", error=e))
        return True


def format_list_table(items, list_type):
    if not items:
        if list_type == "banned-ips":
            return t("players.table_banned_ips_empty")
        elif list_type == "banned-players":
            return t("players.table_banned_players_empty")
        else:
            return t("players.table_whitelist_empty")
    if list_type == "banned-ips":
        name_width = 20
        reason_width = 40
        table = []
        table.append(t("players.table_banned_ips"))
        table.append("╔" + "═" * name_width + "╦" + "═" * reason_width + "╗")
        table.append("║" + (" " + pad_text(t("players.col_ip"), name_width - 1, True)) + "║" + (" " + pad_text(t("players.col_reason"), reason_width - 1, True)) + "║")
        table.append("╠" + "═" * name_width + "╬" + "═" * reason_width + "╣")
        for i, item in enumerate(items, 1):
            ip = item.get("ip", "Unknown")
            reason = item.get("reason", "No reason")
            row = (f"║ {pad_text(f'{i}. {ip}', name_width-1, True)}"
                   f"║ {pad_text(reason, reason_width-1, True)}║")
            table.append(row)
        table.append("╚" + "═" * name_width + "╩" + "═" * reason_width + "╝")
    else:
        name_width = 25
        uuid_width = 38
        table = []
        if list_type == "banned-players":
            table.append(t("players.table_banned_players"))
        else:
            table.append(t("players.table_whitelist"))
        table.append("╔" + "═" * name_width + "╦" + "═" * uuid_width + "╗")
        table.append("║" + (" " + pad_text(t("players.col_name"), name_width - 1, True)) + "║" + (" " + pad_text(t("players.col_uuid"), uuid_width - 1, True)) + "║")
        table.append("╠" + "═" * name_width + "╬" + "═" * uuid_width + "╣")
        for i, item in enumerate(items, 1):
            name = item.get("name", "Unknown")
            uuid = item.get("uuid", "Unknown")
            row = (f"║ {pad_text(f'{i}. {name}', name_width-1, True)}"
                   f"║ {pad_text(uuid, uuid_width-1, True)}║")
            table.append(row)
        table.append("╚" + "═" * name_width + "╩" + "═" * uuid_width + "╝")
    return "\n".join(table)


def manage_player_lists():
    logger.info("Starting player list management")
    print("\n" + "=" * 50)
    print(center_text(t("players.title"), 50))
    print("=" * 50)
    print("\n" + t("players.select_list"))
    print(" 1. " + t("players.opt_banned_players"))
    print(" 2. " + t("players.opt_banned_ips"))
    print(" 3. " + t("players.opt_whitelist"))
    print("")
    try:
        choice = input(t("players.choose_prompt") + " ").strip()
        if not choice:
            logger.info("User exited player list management without selection")
            print("")
            return
        list_choice = int(choice)
        if list_choice not in [1, 2, 3]:
            logger.warning(f"Invalid list choice: {choice}")
            print(t("players.invalid_choice") + "\n")
            return
        list_files = {
            1: "banned-players.json",
            2: "banned-ips.json", 
            3: "whitelist.json"
        }
        list_names = {
            1: "banned-players",
            2: "banned-ips",
            3: "whitelist"
        }
        selected_file = list_files[list_choice]
        selected_type = list_names[list_choice]
        file_path = BASE_DIR / selected_file
        logger.info(f"User selected list: {selected_type} ({selected_file})")
        items = []
        if file_path.exists():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    items = json.load(f)
                if not isinstance(items, list):
                    items = []
                logger.info(f"Loaded {len(items)} items from {selected_file}")
            except Exception as e:
                logger.error(f"Error reading {selected_file}: {e}")
                items = []
        else:
            logger.info(f"File {selected_file} does not exist, starting with empty list")
        print("\n" + format_list_table(items, selected_type))
        print("\n" + t("players.available_ops"))
        print(" " + t("players.add_entry"))
        if items:
            print(" " + t("players.delete_entry"))
        print("")
        op_choice = input(t("players.op_prompt") + " ").strip().upper()
        if not op_choice:
            logger.info("User exited without selecting operation")
            print("")
            return
        if op_choice == 'A':
            logger.info(f"User chose to add entry to {selected_type}")
            add_to_list(items, selected_type, file_path)
        elif op_choice == 'D':
            if items:
                logger.info(f"User chose to delete entry from {selected_type}")
                delete_from_list(items, selected_type, file_path)
            else:
                logger.info(f"Attempted to delete from empty {selected_type} list")
                print(t("players.no_entries") + "\n")
        else:
            logger.warning(f"Invalid operation choice: {op_choice}")
            print(t("players.invalid_op") + "\n")
    except ValueError:
        logger.error("Invalid input in player list management - expected number")
        print(t("players.enter_number") + "\n")
    except Exception as e:
        logger.error(f"Error in player list management: {e}")
        print(t("players.delete_error", list=selected_type if 'selected_type' in dir() else "?", error=e) + "\n")


def delete_from_list(items, list_type, file_path):
    logger.info(f"Starting delete operation on {list_type}")
    if not items:
        logger.warning(f"Attempted to delete from empty {list_type} list")
        print("\n" + t("players.empty_list", list=list_type) + "\n")
        return
    print("\n" + t("players.deleting_from", list=list_type) + "...")
    try:
        selection = input(t("players.delete_selection") + " ").strip()
        if not selection:
            logger.info("User cancelled delete operation")
            print(t("players.op_cancelled") + "\n")
            return
        indices = [int(i.strip()) for i in selection.split()]
        indices.sort(reverse=True)
        valid_indices = [i for i in indices if 1 <= i <= len(items)]
        if not valid_indices:
            logger.warning(f"No valid indices in delete selection: {selection}")
            print(t("players.no_valid_numbers") + "\n")
            return
        logger.info(f"User selected indices for deletion: {valid_indices}")
        print("\n" + t("players.will_delete"))
        entries_to_delete = []
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                entry_info = f"IP: {item.get('ip', 'Unknown')}"
            else:
                entry_info = f"{item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})"
            entries_to_delete.append(entry_info)
            print(f" - {entry_info}")
        logger.info(f"Entries to delete: {', '.join(entries_to_delete)}")
        confirm = input("\n" + t("players.are_you_sure") + " ").strip().upper() or "N"
        if confirm != 'Y':
            logger.info("User cancelled deletion after confirmation")
            print(t("players.deletion_cancelled") + "\n")
            return
        logger.info("User confirmed deletion")
        for idx in valid_indices:
            item = items[idx-1]
            if list_type == "banned-ips":
                entry_info = item.get('ip', 'Unknown')
            else:
                entry_info = f"{item.get('name', 'Unknown')} ({item.get('uuid', 'Unknown')})"
            logger.info(f"Deleting entry: {entry_info}")
            del items[idx-1]
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        logger.info(f"Successfully deleted {len(valid_indices)} entries from {list_type}")
        print("\n" + t("players.deleted_count", list=list_type, count=len(valid_indices)) + "\n")
    except ValueError:
        logger.error("Invalid input in delete operation - expected numbers separated by spaces")
        print(t("players.enter_numbers") + "\n")
    except Exception as e:
        logger.error(f"Error deleting from {list_type}: {e}")
        print(t("players.delete_error", list=list_type, error=e) + "\n")


def add_to_list(items, list_type, file_path):
    logger.info(f"Starting add operation to {list_type}")
    print("\n" + t("players.adding_to", list=list_type) + "...")
    if list_type == "banned-ips":
        while True:
            ip = input(t("players.enter_ip") + " ").strip()
            if not ip:
                logger.info("User cancelled IP ban addition")
                print(t("players.op_cancelled") + "\n")
                return
            ip_pattern = re.compile(
                r'^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.'
                r'(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.'
                r'(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.'
                r'(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
            )
            if ip_pattern.match(ip):
                logger.info(f"Valid IP address entered: {ip}")
                break
            else:
                logger.warning(f"Invalid IP address format: {ip}")
                print(t("players.invalid_ip") + "\n")
        reason = input("\n" + t("players.ban_reason") + " ").strip() or t("players.default_reason")
        logger.info(f"Ban reason: {reason}")
        new_entry = {
            "ip": ip,
            "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
            "source": "Server",
            "expires": "forever",
            "reason": reason
        }
        items.append(new_entry)
        logger.info(f"Added IP ban entry: {ip} with reason: {reason}")
    else:
        online_mode = is_online_mode()
        use_offline_uuid = False
        if not online_mode:
            logger.warning("Server is in offline mode, will generate offline UUIDs")
            print("\n" + t("players.offline_warning1"))
            print(t("players.offline_warning2"))
            print(t("players.offline_warning3") + "\n")
            choice = input(t("players.offline_ask") + " ").strip().upper() or "N"
            if choice != 'Y':
                logger.info("User cancelled adding player in offline mode")
                print(t("players.op_cancelled") + "\n")
                return
            logger.info("User chose to continue in offline mode, will generate offline UUID")
            use_offline_uuid = True
        username = None
        uuid = None
        actual_name = None
        while True:
            username_input = input("\n" + t("players.enter_username") + " ").strip()
            if not username_input:
                logger.info("User cancelled player addition")
                print(t("players.op_cancelled") + "\n")
                return
            if len(username_input) > 16:
                logger.warning(f"Username too long: {username_input}")
                print(t("players.username_too_long"))
                continue
            if use_offline_uuid:
                logger.info(f"Generating offline UUID for username: {username_input}")
                uuid = generate_offline_uuid(username_input)
                actual_name = username_input
                print(t("players.generated", name=actual_name, uuid=uuid))
                break
            else:
                logger.info(f"Fetching UUID for username: {username_input}")
                print(t("players.fetching_uuid", name=username_input) + "...")
                uuid, actual_name = get_mojang_uuid(username_input)
                if not uuid:
                    logger.error(f"Could not fetch UUID for username: {username_input}")
                    print(t("players.fetch_failed", name=username_input))
                    print(t("players.check_username"))
                    continue
                logger.info(f"Successfully fetched UUID for {username_input}: {uuid}")
                print(t("players.found", name=actual_name, uuid=uuid))
                break
        if actual_name is None or uuid is None:
            logger.error("Failed to obtain valid username/UUID, this should not happen")
            print(t("players.internal_error") + "\n")
            return
        if list_type == "banned-players":
            reason = input("\n" + t("players.ban_reason") + " ").strip() or t("players.default_reason")
            logger.info(f"Ban reason: {reason}")
            new_entry = {
                "uuid": uuid,
                "name": actual_name,
                "created": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S +0800"),
                "source": "Server",
                "expires": "forever",
                "reason": reason
            }
            items.append(new_entry)
            logger.info(f"Added player ban entry: {actual_name} ({uuid}) with reason: {reason}")
        else:
            new_entry = {
                "uuid": uuid,
                "name": actual_name
            }
            items.append(new_entry)
            logger.info(f"Added whitelist entry: {actual_name} ({uuid})")
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        logger.info(f"Successfully saved {list_type} to {file_path}")
        print("\n" + t("players.added_success", list=list_type) + "\n")
    except Exception as e:
        logger.error(f"Error saving {list_type}: {e}")
        print(t("players.save_error", list=list_type, error=e) + "\n")

#!/usr/bin/env python3
# settings module for MC-Server-Manager
# Interactive editor for server.properties.

import os
import sys

MODULE = {
    "name": "settings",
    "version": "1.0",
    "description": "Interactive editor for server.properties",
    "requires": [],
    "commands": {
        "--settings": "cmd.settings",
    },
}

BASE_DIR = None
SERVER_PROPERTIES = None
logger = None
t = None
center_text = None


def bind(ctx):
    global BASE_DIR, SERVER_PROPERTIES, logger, t, center_text
    BASE_DIR = ctx.BASE_DIR
    SERVER_PROPERTIES = ctx.SERVER_PROPERTIES
    logger = ctx.logger
    t = ctx.t
    center_text = ctx.center_text


def dispatch(args, ctx):
    if args and args[0] == "--settings":
        edit_server_settings()


def edit_server_settings():
    if not SERVER_PROPERTIES.exists():
        logger.error("Server properties file not found")
        print("\n" + "=" * 50)
        print(center_text(t("settings.title"), 50))
        print("=" * 50)
        print("\n" + t("settings.error_not_found"))
        print(t("settings.hint_start"))
        print("")
        return
    logger.info("Starting server configuration editor")
    print("\n" + "=" * 50)
    print(center_text(t("settings.title"), 50))
    print("=" * 50)
    properties = {}
    try:
        logger.info(f"Reading server properties from: {SERVER_PROPERTIES}")
        with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    if '=' in line:
                        key, value = line.split('=', 1)
                        properties[key.strip()] = value.strip()
        logger.info(f"Successfully read {len(properties)} properties from server.properties")
    except Exception as e:
        logger.error(f"Error reading server.properties: {e}")
        print(t("settings.read_error", error=e))
        return
    settings_config = [
        {
            'key': 'online-mode',
            'name': 'Online Mode',
            'type': 'boolean',
            'default': 'true',
            'description': 'Verify player authentication with Mojang'
        },
        {
            'key': 'white-list',
            'name': 'Whitelist',
            'type': 'boolean', 
            'default': 'false',
            'description': 'Enable whitelist to restrict server access'
        },
        {
            'key': 'enable-command-block',
            'name': 'Command Blocks',
            'type': 'boolean',
            'default': 'false',
            'description': 'Enable command blocks in the world'
        },
        {
            'key': 'allow-flight',
            'name': 'Allow Flight',
            'type': 'boolean',
            'default': 'false',
            'description': 'Allow players to fly in survival mode'
        },
        {
            'key': 'hardcore',
            'name': 'Hardcore Mode',
            'type': 'boolean', 
            'default': 'false',
            'description': 'Enable hardcore mode (permanent death)'
        },
        {
            'key': 'pvp',
            'name': 'PVP',
            'type': 'boolean',
            'default': 'true',
            'description': 'Allow player vs player combat'
        },
        {
            'key': 'server-port',
            'name': 'Server Port',
            'type': 'int',
            'range': (0, 65535),
            'default': '25565',
            'description': 'The port the server will listen on'
        },
        {
            'key': 'op-permission-level',
            'name': 'OP Permission Level',
            'type': 'int',
            'range': (0, 4),
            'default': '4',
            'description': 'Permission level for server operators'
        },
        {
            'key': 'function-permission-level',
            'name': 'Function Permission Level', 
            'type': 'int',
            'range': (0, 4),
            'default': '2',
            'description': 'Permission level for functions'
        },
        {
            'key': 'max-players',
            'name': 'Max Players',
            'type': 'int',
            'range': (1, 9999),
            'default': '20',
            'description': 'Maximum number of players allowed'
        },
        {
            'key': 'view-distance',
            'name': 'View Distance',
            'type': 'int',
            'range': (2, 32),
            'default': '10',
            'description': 'Maximum view distance in chunks'
        },
        {
            'key': 'difficulty',
            'name': 'Difficulty',
            'type': 'enum',
            'options': ['peaceful', 'easy', 'normal', 'hard'],
            'default': 'easy',
            'description': 'Game difficulty level'
        },
        {
            'key': 'level-seed',
            'name': 'World Seed',
            'type': 'string',
            'default': '',
            'description': 'Seed for world generation'
        },
        {
            'key': 'motd',
            'name': 'MOTD',
            'type': 'string',
            'default': 'A Minecraft Server',
            'description': 'Server description shown in server list'
        }
    ]
    logger.info("Entering server configuration editor loop")
    edited_settings = []
    while True:
        print("\n" + center_text(t("settings.table_title"), 45))
        print("╔" + "═" * 35 + "╦" + "═" * 26 + "╗")
        print("║ " + t("settings.col_setting").ljust(33) + " ║ " + t("settings.col_value").ljust(23) + " ║")
        print("╠" + "═" * 35 + "╬" + "═" * 26 + "╣")
        for i, setting in enumerate(settings_config, 1):
            key = setting['key']
            current_value = properties.get(key, setting['default'])
            if not current_value and setting['type'] == 'string':
                current_value = t("settings.empty")
            name_display = f"{i}. {t('settings.name.' + key)}"
            value_display = str(current_value)
            if len(name_display) > 34:
                name_display = name_display[:31] + "..."
            if len(value_display) > 24:
                value_display = value_display[:21] + "..."
            print(f"║ {name_display.ljust(34)}║ {value_display.ljust(24)} ║")
        print("╚" + "═" * 35 + "╩" + "═" * 26 + "╝")
        print("\n" + t("settings.prompt_number"))
        try:
            choice = input("\n" + t("settings.your_choice") + " ").strip()
            if not choice:
                logger.info("User exited configuration editor")
                print(t("settings.exiting") + "\n")
                break
            index = int(choice) - 1
            if index < 0 or index >= len(settings_config):
                logger.warning(f"Invalid selection: {choice}")
                print(t("settings.invalid_selection"))
                continue
            setting = settings_config[index]
            key = setting['key']
            current_value = properties.get(key, setting['default'])
            logger.info(f"User editing setting: {setting['name']} ({key}), current value: {current_value}")
            print("\n" + t("settings.editing", name=t('settings.name.' + key)))
            print("\n" + t("settings.description", description=t('settings.desc.' + key)))
            print(t("settings.current_value", value=current_value if current_value else t('settings.empty')))
            old_value = current_value
            new_value = None
            if setting['type'] == 'boolean':
                print("\n" + t("settings.options"))
                print(" 1. " + t("settings.enable"))
                print(" 2. " + t("settings.disable"))
                while True:
                    bool_choice = input("\n" + t("settings.select_option") + " ").strip()
                    if not bool_choice:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print(t("settings.cancelled") + "\n")
                        break
                    if bool_choice == '1':
                        new_value = 'true'
                        break
                    elif bool_choice == '2':
                        new_value = 'false'
                        break
                    else:
                        logger.warning(f"Invalid boolean choice: {bool_choice}")
                        print(t("settings.invalid_choice_12"))
                if bool_choice:
                    properties[key] = new_value
                    logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                    edited_settings.append(f"{t('settings.name.' + key)}: {old_value} -> {new_value}")
                    print(t("settings.set_to", name=t('settings.name.' + key), value=new_value))
            elif setting['type'] == 'int':
                min_val, max_val = setting['range']
                print("\n" + t("settings.valid_range", min=min_val, max=max_val))
                while True:
                    int_input = input("\n" + t("settings.enter_value") + " ").strip()
                    if not int_input:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print(t("settings.cancelled") + "\n")
                        break
                    try:
                        int_value = int(int_input)
                        if min_val <= int_value <= max_val:
                            new_value = str(int_value)
                            properties[key] = new_value
                            if key == 'view-distance':
                                properties['simulation-distance'] = new_value
                                logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}, simulation-distance also set to {new_value}")
                                edited_settings.append(f"{t('settings.name.' + key)}: {old_value} -> {new_value} (simulation-distance also updated)")
                                print(t("settings.set_to", name=t('settings.name.' + key), value=int_value))
                                print(t("settings.simulation_also", value=int_value))
                            else:
                                logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                                edited_settings.append(f"{t('settings.name.' + key)}: {old_value} -> {new_value}")
                                print(t("settings.set_to", name=t('settings.name.' + key), value=int_value))
                            break
                        else:
                            logger.warning(f"Value out of range: {int_value}, allowed: {min_val}-{max_val}")
                            print(t("settings.value_out_of_range", min=min_val, max=max_val))
                    except ValueError:
                        logger.warning(f"Invalid integer input: {int_input}")
                        print(t("settings.enter_number"))
            elif setting['type'] == 'enum':
                print("\n" + t("settings.available_options"))
                for j, option in enumerate(setting['options'], 1):
                    print(f" {j}. {option}")
                while True:
                    enum_choice = input("\n" + t("settings.select_option_prompt") + " ").strip()
                    if not enum_choice:
                        logger.info(f"User cancelled editing {setting['name']}")
                        print(t("settings.cancelled") + "\n")
                        break
                    try:
                        option_index = int(enum_choice) - 1
                        if 0 <= option_index < len(setting['options']):
                            new_value = setting['options'][option_index]
                            properties[key] = new_value
                            logger.info(f"Setting changed: {setting['name']} from {old_value} to {new_value}")
                            edited_settings.append(f"{t('settings.name.' + key)}: {old_value} -> {new_value}")
                            print(t("settings.set_to", name=t('settings.name.' + key), value=new_value))
                            break
                        else:
                            logger.warning(f"Invalid enum index: {option_index}, allowed: 0-{len(setting['options'])-1}")
                            print(t("settings.enter_number_between", max=len(setting['options'])))
                    except ValueError:
                        logger.warning(f"Invalid enum input: {enum_choice}")
                        print(t("settings.enter_number"))
            elif setting['type'] == 'string':
                string_input = input("\n" + t("settings.enter_new_value") + " ").strip()
                if not string_input:
                    logger.info(f"User cancelled editing {setting['name']}")
                    print(t("settings.cancelled") + "\n")
                else:
                    new_value = string_input
                    properties[key] = new_value
                    logger.info(f"Setting changed: {setting['name']} from '{old_value}' to '{new_value}'")
                    edited_settings.append(f"{t('settings.name.' + key)}: '{old_value}' -> '{new_value}'")
                    print(t("settings.set_to", name=t('settings.name.' + key), value=string_input))
            try:
                logger.info("Saving updated server properties")
                with open(SERVER_PROPERTIES, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                updated_lines = []
                found_keys = set()
                for line in lines:
                    stripped_line = line.strip()
                    if stripped_line and not stripped_line.startswith('#'):
                        if '=' in stripped_line:
                            line_key = stripped_line.split('=', 1)[0].strip()
                            if line_key in properties:
                                updated_lines.append(f"{line_key}={properties[line_key]}\n")
                                found_keys.add(line_key)
                                continue
                    updated_lines.append(line)
                for prop_key, prop_value in properties.items():
                    if prop_key not in found_keys:
                        updated_lines.append(f"{prop_key}={prop_value}\n")
                with open(SERVER_PROPERTIES, 'w', encoding='utf-8') as f:
                    f.writelines(updated_lines)
                logger.info("Configuration saved successfully")
                print("\n" + t("settings.saved"))
            except Exception as e:
                logger.error(f"Error saving configuration: {e}")
                print("\n" + t("settings.save_error", error=e) + "\n")
        except ValueError:
            logger.warning(f"Invalid input (not a number): {choice}")
            print(t("settings.enter_number"))
        except KeyboardInterrupt:
            logger.warning("Configuration editor interrupted by user")
            print("\n\n" + t("settings.operation_cancelled") + "\n")
            break
        except Exception as e:
            logger.error(f"Unexpected error in configuration editor: {e}")
            print("\n" + t("settings.unexpected", error=e) + "\n")
    if edited_settings:
        logger.info(f"Configuration editor completed. Changes made: {len(edited_settings)}")
        logger.info("Changes list: " + ", ".join(edited_settings))
    else:
        logger.info("Configuration editor completed with no changes")

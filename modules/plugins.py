#!/usr/bin/env python3
# plugins module for MC-Server-Manager
# Plugin management with dependency awareness.

import os
import zipfile

try:
    import yaml
except ImportError:
    yaml = None

MODULE = {
    "name": "plugins",
    "version": "1.0",
    "description": "Plugin management with dependency awareness",
    "requires": [],
    "commands": {
        "--plugins": "cmd.plugins",
        "--plugins analyze": "cmd.plugins.analyze",
    },
}

PLUGINS_DIR = None
logger = None
truncate_text = None
t = None
center_text = None
pad_text = None


def bind(ctx):
    global PLUGINS_DIR, logger, truncate_text, t, center_text, pad_text
    PLUGINS_DIR = ctx.PLUGINS_DIR
    logger = ctx.logger
    truncate_text = ctx.truncate_text
    t = ctx.t
    center_text = ctx.center_text
    pad_text = ctx.pad_text


def dispatch(args, ctx):
    if not args or args[0] != "--plugins":
        return
    if yaml is None:
        print("\n" + t("plugins.yaml_required"))
        print(t("plugins.yaml_install") + "\n")
        return
    if len(args) > 1 and args[1] == "analyze":
        analyze_plugin_dependencies_cli()
    else:
        manage_plugins_with_dependencies()


def format_plugins_table(plugins):
    name_width = 25
    version_width = 15
    status_width = 10
    table = []
    table.append(center_text(t("plugins.table_title"), 40))
    table.append("╔" + "═" * name_width + "╦" + "═" * version_width + "╦" + "═" * status_width + "╗")
    table.append("║" + (" " + pad_text(t("plugins.col_name"), name_width - 1, True)) + "║" + (" " + pad_text(t("plugins.col_version"), version_width - 1, True)) + "║" + (" " + pad_text(t("plugins.col_status"), status_width - 1, True)) + "║")
    table.append("╠" + "═" * name_width + "╬" + "═" * version_width + "╬" + "═" * status_width + "╣")
    for i, plugin in enumerate(plugins, 1):
        name = f"{i}. {plugin['name']}"
        version = plugin['version']
        status = t("plugins.enabled") if plugin['enabled'] else t("plugins.disabled")
        row = (f"║ {pad_text(name, name_width-1, True)}"
               f"║ {pad_text(version, version_width-1, True)}"
               f"║ {pad_text(status, status_width-1, True)}║")
        table.append(row)
    table.append("╚" + "═" * name_width + "╩" + "═" * version_width + "╩" + "═" * status_width + "╝")
    return "\n".join(table)


def get_plugin_info(plugin_path):
    try:
        with zipfile.ZipFile(plugin_path, 'r') as jar:
            try:
                with jar.open('plugin.yml') as f:
                    plugin_data = yaml.safe_load(f)
                    name = str(plugin_data.get('name', 'Unknown'))
                    version = str(plugin_data.get('version', 'Unknown'))
                    main_class = str(plugin_data.get('main', 'Unknown'))
                    return name, version, main_class
            except KeyError:
                try:
                    with jar.open('META-INF/plugin.yml') as f:
                        plugin_data = yaml.safe_load(f)
                        name = str(plugin_data.get('name', 'Unknown'))
                        version = str(plugin_data.get('version', 'Unknown'))
                        main_class = str(plugin_data.get('main', 'Unknown'))
                        return name, version, main_class
                except KeyError:
                    name = plugin_path.stem
                    if name.endswith('.disabled'):
                        name = name[:-9]
                    return name, 'Unknown', 'Unknown'
    except Exception as e:
        name = plugin_path.stem
        if name.endswith('.disabled'):
            name = name[:-9]
        return name, 'Unknown', 'Unknown'


def get_plugin_dependencies(plugin_path):
    try:
        with zipfile.ZipFile(plugin_path, 'r') as jar:
            plugin_yml_locations = ['plugin.yml', 'META-INF/plugin.yml']
            plugin_data = {}
            for location in plugin_yml_locations:
                try:
                    with jar.open(location) as f:
                        plugin_data = yaml.safe_load(f)
                        break
                except KeyError:
                    continue
            if not plugin_data:
                return {'depend': [], 'softdepend': []}
            depend = plugin_data.get('depend', [])
            softdepend = plugin_data.get('softdepend', [])
            if isinstance(depend, str):
                depend = [depend] if depend else []
            if isinstance(softdepend, str):
                softdepend = [softdepend] if softdepend else []
            return {
                'depend': depend,
                'softdepend': softdepend
            }
    except Exception as e:
        return {'depend': [], 'softdepend': []}


def check_plugin_dependencies(plugins, plugin_to_disable):
    plugin_name = plugin_to_disable['name']
    hard_dependents = []
    soft_dependents = []
    for plugin in plugins:
        if plugin['enabled'] and plugin['name'] != plugin_name:
            dependencies = get_plugin_dependencies(plugin['path'])
            if plugin_name in dependencies['depend']:
                hard_dependents.append(plugin)
            if plugin_name in dependencies['softdepend']:
                soft_dependents.append(plugin)
    return {
        'hard_dependents': hard_dependents,
        'soft_dependents': soft_dependents
    }


def format_dependency_warning(plugin, hard_dependents, soft_dependents):
    message = []
    if hard_dependents:
        message.append(f"\nCRITICAL WARNING: {plugin['name']} is REQUIRED by:")
        for dependent in hard_dependents:
            message.append(f" - {dependent['name']} (version {dependent['version']})")
        message.append("\nThese plugins WILL STOP WORKING if you disable this plugin!")
        message.append("This may cause SERVER CRASHES or errors!")
    if soft_dependents:
        message.append(f"\nWARNING: {plugin['name']} is optionally used by:")
        for dependent in soft_dependents:
            message.append(f" - {dependent['name']} (version {dependent['version']})")
        message.append("\nThese plugins may lose functionality or not work perfectly!")
    return "\n".join(message)


def manage_plugins_with_dependencies():
    logger.info("Starting plugin management with dependency analysis")
    if not PLUGINS_DIR.exists():
        logger.error("Plugins directory not found")
        print("\n" + t("plugins.dir_not_found") + "!")
        print("")
        return
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    logger.info(f"Found {len(plugin_files)} plugin files (including disabled)")
    if not plugin_files:
        logger.info("No plugins found in directory")
        print("\n" + t("plugins.none_found") + "!")
        print("")
        return
    plugins = []
    for plugin_path in plugin_files:
        name, version, main_class = get_plugin_info(plugin_path)
        enabled = not plugin_path.name.endswith('.disabled')
        plugins.append({
            'path': plugin_path,
            'name': name,
            'version': version,
            'main_class': main_class,
            'enabled': enabled
        })
        logger.info(f"Plugin loaded: {name} (version: {version}, enabled: {enabled})")
    enabled_count = len([p for p in plugins if p['enabled']])
    disabled_count = len([p for p in plugins if not p['enabled']])
    logger.info(f"Plugin statistics: {enabled_count} enabled, {disabled_count} disabled")
    print("\n" + format_plugins_table(plugins))
    choice = input("\n" + t("plugins.toggle_ask") + " (y/N): ").strip().upper() or "N"
    logger.info(f"User choice for plugin toggle: {choice}")
    if choice != 'Y':
        logger.info("User cancelled plugin management")
        print("")
        return
    try:
        selected = input(t("plugins.toggle_numbers") + " ").strip()
        if not selected:
            logger.info("No plugins selected for toggling")
            print(t("plugins.no_selection") + "\n")
            return
        logger.info(f"User selected plugins: {selected}")
        indices = [int(i) for i in selected.split()]
        indices = [i for i in indices if 1 <= i <= len(plugins)]
        logger.info(f"Valid plugin indices after filtering: {indices}")
        if not indices:
            logger.warning("No valid plugin numbers selected")
            print(t("plugins.no_valid_numbers") + "\n")
            return
        plugins_to_disable = []
        plugins_to_enable = []
        for idx in indices:
            plugin = plugins[idx-1]
            if plugin['enabled']:
                plugins_to_disable.append(plugin)
                logger.info(f"Plugin to disable: {plugin['name']} (index: {idx})")
            else:
                plugins_to_enable.append(plugin)
                logger.info(f"Plugin to enable: {plugin['name']} (index: {idx})")
        logger.info(f"Operation summary: {len(plugins_to_enable)} to enable, {len(plugins_to_disable)} to disable")
        for plugin in plugins_to_enable:
            old_path = plugin['path']
            new_name = old_path.name.replace(".disabled", "")
            new_path = old_path.parent / new_name
            try:
                old_path.rename(new_path)
                plugin['path'] = new_path
                plugin['enabled'] = True
                logger.info(f"Enabled plugin: {plugin['name']}")
                print(t("plugins.enabled_one", name=plugin['name']))
            except Exception as e:
                logger.error(f"Failed to enable plugin {plugin['name']}: {e}")
                print(t("plugins.enable_error", name=plugin['name'], error=e))
        for plugin in plugins_to_disable:
            dependencies = check_plugin_dependencies(plugins, plugin)
            hard_dependents = dependencies['hard_dependents']
            soft_dependents = dependencies['soft_dependents']
            logger.info(f"Checking dependencies for {plugin['name']}: "
                       f"{len(hard_dependents)} hard dependents, {len(soft_dependents)} soft dependents")
            if hard_dependents or soft_dependents:
                warning_message = format_dependency_warning(plugin, hard_dependents, soft_dependents)
                if hard_dependents:
                    hard_dep_names = [dep['name'] for dep in hard_dependents]
                    logger.warning(f"Hard dependencies found for {plugin['name']}: {hard_dep_names}")
                if soft_dependents:
                    soft_dep_names = [dep['name'] for dep in soft_dependents]
                    logger.info(f"Soft dependencies found for {plugin['name']}: {soft_dep_names}")
                print(warning_message)
                if hard_dependents:
                    logger.info("Presenting options for hard dependencies")
                    print("\n" + t("plugins.multiple_options"))
                    print(" 1. " + t("plugins.opt_manual"))
                    print(" 2. " + t("plugins.opt_force"))
                    print(" 3. " + t("plugins.opt_auto"))
                    while True:
                        choice = input("\n" + t("plugins.choose_option") + " ").strip().upper()
                        logger.info(f"User dependency resolution choice: {choice}")
                        if choice == '1':
                            logger.info(f"User chose to manually disable dependent plugins first")
                            print(t("plugins.disable_dependents_first"))
                            for dependent in hard_dependents:
                                print(f" - {dependent['name']}")
                            print(t("plugins.then_retry") + "\n")
                            continue
                        elif choice == '2':
                            logger.warning(f"User chose to force disable {plugin['name']}")
                            confirm = input(t("plugins.force_confirm") + " (y/N): ").strip().upper() or "N"
                            if confirm == 'Y':
                                logger.warning(f"User confirmed force disable for {plugin['name']}")
                                try:
                                    old_path = plugin['path']
                                    new_path = old_path.parent / (old_path.name + ".disabled")
                                    old_path.rename(new_path)
                                    plugin['path'] = new_path
                                    plugin['enabled'] = False
                                    logger.info(f"Force disabled: {plugin['name']}")
                                    print(t("plugins.force_disabled", name=plugin['name']) + "\n")
                                    break
                                except Exception as e:
                                    logger.error(f"Failed to force disable {plugin['name']}: {e}")
                                    print(t("plugins.force_error", name=plugin['name'], error=e) + "\n")
                                    break
                            else:
                                logger.info(f"User cancelled force disable for {plugin['name']}")
                                continue
                        elif choice == '3':
                            logger.info(f"User chose automatic dependency chain disable for {plugin['name']}")
                            disabled_plugins = disable_dependency_chain(plugins, plugin)
                            if disabled_plugins:
                                disabled_names = [p['name'] for p in disabled_plugins]
                                logger.info(f"Automatically disabled {len(disabled_plugins)} plugins: {disabled_names}")
                                print("\n" + t("plugins.auto_disabled"))
                                for disabled_plugin in disabled_plugins:
                                    print(f" - {disabled_plugin['name']}")           
                                if soft_dependents:
                                    soft_names = [dep['name'] for dep in soft_dependents]
                                    logger.info(f"Soft dependents not auto-disabled: {soft_names}")
                                    print("\n" + t("plugins.soft_not_auto"))
                                    for soft_dep in soft_dependents:
                                        print(f"  - {soft_dep['name']}")
                                    print(t("plugins.may_lose") + "\n")
                            break
                        elif choice == 'C':
                            logger.info(f"User cancelled disabling of {plugin['name']}")
                            print(t("plugins.cancelled_disable", name=plugin['name']) + "\n")
                            break
                        else:
                            logger.warning(f"Invalid dependency resolution choice: {choice}")
                            print(t("plugins.invalid_choice") + "\n")
                else:
                    logger.info(f"Only soft dependencies found for {plugin['name']}")
                    confirm = input("\n" + t("plugins.disable_confirm", name=plugin['name']) + " (y/N): ").strip().upper() or "N"
                    logger.info(f"User confirmation for soft dependency disable: {confirm}")   
                    if confirm == 'Y':
                        try:
                            old_path = plugin['path']
                            new_path = old_path.parent / (old_path.name + ".disabled")
                            old_path.rename(new_path)
                            plugin['path'] = new_path
                            plugin['enabled'] = False
                            logger.info(f"Disabled plugin with soft dependencies: {plugin['name']}")
                            print(t("plugins.disabled_one", name=plugin['name']))
                        except Exception as e:
                            logger.error(f"Failed to disable {plugin['name']}: {e}")
                            print(t("plugins.disable_error", name=plugin['name'], error=e))
                    else:
                        logger.info(f"User skipped disabling {plugin['name']}")
                        print(t("plugins.skipped", name=plugin['name']))
            else:
                logger.info(f"No dependencies found for {plugin['name']}, disabling directly")
                try:
                    old_path = plugin['path']
                    new_path = old_path.parent / (old_path.name + ".disabled")
                    old_path.rename(new_path)
                    plugin['path'] = new_path
                    plugin['enabled'] = False
                    logger.info(f"Disabled plugin without dependencies: {plugin['name']}")
                    print(t("plugins.disabled_one", name=plugin['name']))
                except Exception as e:
                    logger.error(f"Failed to disable {plugin['name']}: {e}")
                    print(t("plugins.disable_error", name=plugin['name'], error=e))
        enabled_after = len([p for p in plugins if p['enabled']])
        disabled_after = len([p for p in plugins if not p['enabled']])
        logger.info(f"Final plugin statistics: {enabled_after} enabled, {disabled_after} disabled")
        logger.info("Plugin state changes completed successfully")
        print("\n" + t("plugins.states_changed") + "!")
        print("")
    except ValueError:
        logger.error("Invalid input - expected numbers separated by spaces")
        print(t("plugins.invalid_input") + "\n")
    except Exception as e:
        logger.error(f"Error toggling plugins: {e}")
        print(t("plugins.toggle_error", error=e) + "\n")


def disable_dependency_chain(plugins, target_plugin):
    logger.info(f"Starting dependency chain disable for {target_plugin['name']}")
    disabled_plugins = []
    plugins_to_disable = [target_plugin]
    while plugins_to_disable:
        current_plugin = plugins_to_disable.pop(0)
        if not current_plugin['enabled'] or current_plugin in disabled_plugins:
            continue
        try:
            old_path = current_plugin['path']
            new_path = old_path.parent / (old_path.name + ".disabled")
            old_path.rename(new_path)
            current_plugin['path'] = new_path
            current_plugin['enabled'] = False
            disabled_plugins.append(current_plugin)
            logger.info(f"Disabled: {current_plugin['name']}")
            print("  " + t("plugins.disabled_one", name=current_plugin['name']))
        except Exception as e:
            logger.error(f"Error disabling {current_plugin['name']}: {e}")
            print("  " + t("plugins.disable_error", name=current_plugin['name'], error=e))
            continue
        for plugin in plugins:
            if plugin['enabled'] and plugin not in disabled_plugins and plugin not in plugins_to_disable:
                dependencies = get_plugin_dependencies(plugin['path'])
                if current_plugin['name'] in dependencies['depend']:
                    plugins_to_disable.append(plugin)
                    logger.info(f"Queued for disabling (hard dependency): {plugin['name']}")
                    print("  " + t("plugins.queued", name=plugin['name']))
    logger.info(f"Dependency chain disable finished: {len(disabled_plugins)} plugin(s) disabled")
    return disabled_plugins


def analyze_plugin_dependencies_cli():
    logger.info("Starting analyze_plugin_dependencies_cli function")
    print("\n" + "=" * 52)
    print(center_text(t("plugins.analyze_title"), 52))
    print("=" * 52)
    if not PLUGINS_DIR.exists():
        logger.error("Plugins directory not found: %s", PLUGINS_DIR)
        print("\n" + t("plugins.dir_not_found") + "!")
        print("")
        return
    plugin_files = list(PLUGINS_DIR.glob("*.jar")) + list(PLUGINS_DIR.glob("*.jar.disabled"))
    logger.info("Found %d plugin files (including disabled)", len(plugin_files))
    if not plugin_files:
        logger.info("No plugins found in directory")
        print("\n" + t("plugins.none_found") + "!")
        print("")
        return
    all_plugins = []
    logger.info("Processing plugin files...")
    for plugin_path in plugin_files:
        name, version, main_class = get_plugin_info(plugin_path)
        enabled = not plugin_path.name.endswith('.disabled')
        dependencies = get_plugin_dependencies(plugin_path)
        all_plugins.append({
            'path': plugin_path,
            'name': name,
            'version': version,
            'enabled': enabled,
            'dependencies': dependencies
        })
        logger.info("Plugin loaded: %s (version: %s, enabled: %s, dependencies: %s)", 
                    name, version, enabled, dependencies)
    logger.info("Total plugins processed: %d", len(all_plugins))
    installed_plugin_names = {plugin['name'].lower() for plugin in all_plugins}
    enabled_plugin_names = {plugin['name'].lower() for plugin in all_plugins if plugin['enabled']}
    logger.info("Installed plugin names (lowercase): %s", installed_plugin_names)
    logger.info("Enabled plugin names (lowercase): %s", enabled_plugin_names)
    found_issues = False
    logger.info("Starting dependency analysis...")
    for plugin in all_plugins:
        if not plugin['enabled']:
            continue
        plugin_name = plugin['name']
        logger.info("Analyzing dependencies for plugin: %s", plugin_name)
        dependencies = plugin['dependencies']
        hard_deps = dependencies.get('depend', [])
        soft_deps = dependencies.get('softdepend', [])
        logger.info("Plugin %s hard dependencies: %s", plugin_name, hard_deps)
        logger.info("Plugin %s soft dependencies: %s", plugin_name, soft_deps)
        hard_dep_not_installed = []
        hard_dep_not_enabled = []
        for dep in hard_deps:
            dep_lower = dep.lower()
            if dep_lower not in installed_plugin_names:
                hard_dep_not_installed.append(dep)
                logger.warning("Hard dependency not installed: %s (required by: %s)", dep, plugin_name)
            elif dep_lower not in enabled_plugin_names:
                disabled_dep = next((p for p in all_plugins if p['name'].lower() == dep_lower and not p['enabled']), None)
                if disabled_dep:
                    hard_dep_not_enabled.append(dep)
                    logger.warning("Hard dependency not enabled: %s (required by: %s)", dep, plugin_name)
        soft_dep_not_installed = []
        soft_dep_not_enabled = []
        for dep in soft_deps:
            dep_lower = dep.lower()
            if dep_lower not in installed_plugin_names:
                soft_dep_not_installed.append(dep)
                logger.info("Soft dependency not installed: %s (used by: %s)", dep, plugin_name)
            elif dep_lower not in enabled_plugin_names:
                disabled_dep = next((p for p in all_plugins if p['name'].lower() == dep_lower and not p['enabled']), None)
                if disabled_dep:
                    soft_dep_not_enabled.append(dep)
                    logger.info("Soft dependency not enabled: %s (used by: %s)", dep, plugin_name)
        if soft_dep_not_installed:
            found_issues = True
            logger.info("Plugin %s has missing soft dependencies: %s", plugin_name, soft_dep_not_installed)
            print("\n" + t("plugins.soft_missing", name=plugin_name))
            for dep in soft_dep_not_installed:
                print(f" - {dep}")
        if soft_dep_not_enabled:
            found_issues = True
            logger.info("Plugin %s has disabled soft dependencies: %s", plugin_name, soft_dep_not_enabled)
            print("\n" + t("plugins.soft_disabled", name=plugin_name))
            for dep in soft_dep_not_enabled:
                print(f" - {dep}")
        if hard_dep_not_installed:
            found_issues = True
            logger.warning("Plugin %s has missing hard dependencies: %s", plugin_name, hard_dep_not_installed)
            print("\n" + t("plugins.hard_missing", name=plugin_name))
            for dep in hard_dep_not_installed:
                print(f" - {dep}")
        if hard_dep_not_enabled:
            found_issues = True
            logger.warning("Plugin %s has disabled hard dependencies: %s", plugin_name, hard_dep_not_enabled)
            print("\n" + t("plugins.hard_disabled", name=plugin_name))
            for dep in hard_dep_not_enabled:
                print(f" - {dep}")
    if not found_issues:
        logger.info("All plugin dependencies are satisfied")
        print("\n" + t("plugins.all_satisfied"))
        print(t("plugins.no_issues"))
    disabled_plugins = [p for p in all_plugins if not p['enabled']]
    logger.info("Found %d disabled plugins", len(disabled_plugins))
    if disabled_plugins:
        print("\n" + "=" * 50)
        print(t("plugins.disabled_list"))
        print("=" * 50)
        for plugin in disabled_plugins:
            print(f" - {plugin['name']} (version: {plugin['version']})")
            logger.info("Disabled plugin: %s (version: %s)", plugin['name'], plugin['version'])
    enabled_count = len([p for p in all_plugins if p['enabled']])
    disabled_count = len([p for p in all_plugins if not p['enabled']])
    total_hard_deps = sum(len(p['dependencies'].get('depend', [])) for p in all_plugins if p['enabled'])
    total_soft_deps = sum(len(p['dependencies'].get('softdepend', [])) for p in all_plugins if p['enabled'])
    logger.info("Plugin statistics - Total: %d, Enabled: %d, Disabled: %d, Hard dependencies: %d, Soft dependencies: %d",
                len(all_plugins), enabled_count, disabled_count, total_hard_deps, total_soft_deps)
    print("\n" + t("plugins.ignore_soft"))
    print(t("plugins.never_ignore_hard") + "!")
    print(f"\n" + "=" * 52)
    print(t("plugins.statistics"))
    print(" - " + t("plugins.total", count=len(all_plugins)))
    print(" - " + t("plugins.enabled_count", count=enabled_count))
    print(" - " + t("plugins.disabled_count", count=disabled_count))
    print(" - " + t("plugins.hard_total", count=total_hard_deps))
    print(" - " + t("plugins.soft_total", count=total_soft_deps))
    print("=" * 52)
    print("")
    logger.info("Plugin dependency analysis completed")


def is_plugin_enabled(plugin_name, enabled_plugins):
    return any(plugin['name'].lower() == plugin_name.lower() for plugin in enabled_plugins)


def disable_all_plugins():
    logger.info("Starting disable of all plugins")
    if not PLUGINS_DIR.exists():
        logger.warning("Plugins directory not found")
        print(t("plugins.dir_missing"))
        return False
    plugin_files = list(PLUGINS_DIR.glob("*.jar"))
    if not plugin_files:
        logger.info("No plugins found to disable")
        print(t("plugins.no_plugins_disable"))
        return True
    disabled_count = 0
    for plugin_path in plugin_files:
        if not plugin_path.name.endswith('.disabled'):
            new_path = plugin_path.parent / (plugin_path.name + ".disabled")
            try:
                plugin_path.rename(new_path)
                disabled_count += 1
            except Exception as e:
                logger.error(f"Error disabling {plugin_path.name}: {e}")
                print(t("plugins.disable_error_file", name=plugin_path.name, error=e))
                return False
    logger.info(f"Disabled {disabled_count} plugins")
    print(t("plugins.disabled_count_result", count=disabled_count))
    return True

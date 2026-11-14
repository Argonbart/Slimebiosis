extends SceneTree
## Headless equivalent of the SpacetimeDB dock's "Generate schema" button.
## Usage: tools/gen_bindings.sh (fetches the schema, then runs this script).

const MODULE_NAME := "slimecrime"
const MODULE_ALIAS := "game"
const SCHEMA_JSON := "user://schema_fetch.json"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var json_path: String = args[0] if args.size() > 0 else SCHEMA_JSON
	var json := FileAccess.get_file_as_string(json_path)
	if json.is_empty():
		printerr("gen_bindings: could not read schema json at ", json_path)
		quit(1)
		return

	var config: SpacetimeDBPluginConfig
	if ResourceLoader.exists(SpacetimePlugin.SAVE_PATH):
		config = ResourceLoader.load(SpacetimePlugin.SAVE_PATH)
	if config == null:
		config = SpacetimeDBPluginConfig.new()
	var module: SpacetimeDBModuleConfig = config.module_configs.get(MODULE_ALIAS, SpacetimeDBModuleConfig.new())
	module.name = MODULE_NAME
	module.alias = MODULE_ALIAS
	module.unparsed_module_schema = json
	config.module_configs[MODULE_ALIAS] = module

	DirAccess.make_dir_recursive_absolute(SpacetimePlugin.BINDINGS_SCHEMA_PATH)
	var codegen := SpacetimeCodegen.new(SpacetimePlugin.BINDINGS_SCHEMA_PATH)
	codegen._plugin_config = config
	var files := codegen.generate_bindings()
	if files.is_empty():
		printerr("gen_bindings: nothing generated")
		quit(1)
		return
	_cleanup(SpacetimePlugin.BINDINGS_SCHEMA_PATH, files)
	ResourceSaver.save(config, SpacetimePlugin.SAVE_PATH)
	print("gen_bindings: generated %d files" % files.size())
	quit(0)

func _cleanup(dir_path: String, keep: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	for file in dir.get_files():
		var full := "%s/%s" % [dir_path, file]
		if file.ends_with(".gd") and not full in keep:
			DirAccess.remove_absolute(full)
			DirAccess.remove_absolute(full + ".uid")
	for sub in dir.get_directories():
		_cleanup(dir_path + "/" + sub, keep)

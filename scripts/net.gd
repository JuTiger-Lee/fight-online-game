extends Node
## Bridge to Supabase Realtime. On the web build it talks to window.SupaNet
## (web/supanet.js); on desktop it is unavailable and the game runs offline.

signal message(event: String, payload: Variant)

var available := false
var _js: JavaScriptObject


func _ready() -> void:
	if OS.has_feature("web"):
		_js = JavaScriptBridge.get_interface("SupaNet")
		available = _js != null
	print("[Net] web=%s available=%s" % [OS.has_feature("web"), available])


func join(room: String, meta: Dictionary) -> void:
	if available:
		_js.join(room, JSON.stringify(meta))


func leave() -> void:
	if available:
		_js.leave()


func send(event: String, payload: Dictionary) -> void:
	if available:
		_js.send(event, JSON.stringify(payload))


func url_param(param: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var v: Variant = JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') || ''" % param, true)
	return str(v) if v != null else ""


func copy_invite(room: String) -> void:
	if available:
		_js.copyInvite(room)


func _process(_dt: float) -> void:
	if not available:
		return
	var raw: Variant = _js.poll()
	if typeof(raw) != TYPE_STRING or raw == "":
		return
	var batch: Variant = JSON.parse_string(raw)
	if typeof(batch) != TYPE_ARRAY:
		return
	for m in batch:
		message.emit(str(m.get("e", "")), m.get("p", {}))

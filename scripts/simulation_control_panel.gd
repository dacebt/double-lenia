class_name SimulationControlPanel
extends Control

## Runtime control panel for tweaking simulation parameters live

## Wiring contract:
## - Prefer exported NodePaths (layout-stable, explicit).
## - Fall back to groups ONLY if the NodePath is unset OR resolves to null.
## - Groups must be unique in runnable scenes: exactly one "environment_field" and one "particle_system".
##
## UI → behavior mapping (authoritative):
## - ParticleCountSpin → `ParticleSystemGPU.particle_count` → realloc particle buffers.
## - ShowFieldButton → `EnvironmentField.show_field` → toggles `FieldSprite.visible`.
## - FieldMuSlider → `EnvironmentField.field_mu` → affects `field_evolution.glsl` + `field_to_texture.glsl` colormap.
## - FieldSigmaSlider → `EnvironmentField.field_sigma` → affects `field_evolution.glsl`.
## - FieldDtSlider → `EnvironmentField.field_dt` → affects field evolution time step.
## - FieldDecaySlider → `EnvironmentField.field_decay` → used in `deposit_particles_gpu()` uniforms.
## - FieldBaselineSlider → `EnvironmentField.field_baseline` → used in `deposit_particles_gpu()` uniforms.
## - FieldKernelRadiusSlider → `EnvironmentField.field_kernel_radius` → affects `field_evolution.glsl`.
## - FieldKernelWidthSlider → `EnvironmentField.field_kernel_width` → affects `field_evolution.glsl`.
## - GradientStrengthSlider → `ParticleSystemGPU.gradient_strength` → uploaded to `particle_compute.glsl`.
## - RepulsionStrengthSlider → `ParticleSystemGPU.repulsion_strength` → uploaded to `particle_compute.glsl`.
## - TimeScaleSlider → `ParticleSystemGPU.time_scale` → uploaded to `particle_compute.glsl` and CPU integration.
## - MinDistSlider → `ParticleSystemGPU.min_dist` → uploaded to `particle_compute.glsl` and CPU wrap.
## - DepositAmountSlider → `EnvironmentField.deposit_amount` → used in `deposit_particles_gpu()` uniforms.
## - DepositRadiusSlider → `EnvironmentField.deposit_radius` → used in `deposit_particles_gpu()` uniforms.
## - ParticleKernelRadiusSlider → `ParticleSystemGPU.particle_kernel_radius` → uploaded to `particle_compute.glsl`.
## - ParticleKernelWidthSlider → `ParticleSystemGPU.particle_kernel_width` → uploaded to `particle_compute.glsl`.
## - ParticleSigmaSlider → `ParticleSystemGPU.particle_sigma` → uploaded to `particle_compute.glsl`.
## - MuBaseSlider → `ParticleSystemGPU.mu_base` → used in `_upload_mu_locals()`.
## - MuRangeSlider → `ParticleSystemGPU.mu_range` → used in `_upload_mu_locals()` to control field influence strength.
@export var environment_field_path: NodePath
@export var particle_system_path: NodePath

var environment_field: EnvironmentField = null
var particle_system: Node = null  # ParticleSystemGPU

enum RangeProfile {
	TUNING,
	STRESS
}

# UI References (null-safe lookups)
var panel: Panel = null
var wiring_status: Label = null
var collapse_button: Button = null
var body_scroll: ScrollContainer = null
var range_profile_selector: OptionButton = null
var particle_count_spin: SpinBox = null
var show_field_button: CheckButton = null
var show_advanced: CheckButton = null
var field_container: VBoxContainer = null
var particle_container: VBoxContainer = null
var advanced_container: VBoxContainer = null
var field_advanced: VBoxContainer = null
var particle_advanced: VBoxContainer = null

# Field sliders (null-safe lookups)
var field_mu_slider: HSlider = null
var field_mu_label: Label = null
var field_sigma_slider: HSlider = null
var field_sigma_label: Label = null
var field_dt_slider: HSlider = null
var field_dt_label: Label = null
var field_decay_slider: HSlider = null
var field_decay_label: Label = null
var field_baseline_slider: HSlider = null
var field_baseline_label: Label = null
# Field advanced sliders
var field_kernel_radius_slider: HSlider = null
var field_kernel_radius_label: Label = null
var field_kernel_width_slider: HSlider = null
var field_kernel_width_label: Label = null

# Particle sliders
var gradient_strength_slider: HSlider = null
var gradient_strength_label: Label = null
var repulsion_strength_slider: HSlider = null
var repulsion_strength_label: Label = null
var time_scale_slider: HSlider = null
var time_scale_label: Label = null
var min_dist_slider: HSlider = null
var min_dist_label: Label = null
var deposit_amount_slider: HSlider = null
var deposit_amount_label: Label = null
var deposit_radius_slider: HSlider = null
var deposit_radius_label: Label = null

# Particle advanced sliders
var particle_kernel_radius_slider: HSlider = null
var particle_kernel_radius_label: Label = null
var particle_kernel_width_slider: HSlider = null
var particle_kernel_width_label: Label = null
var particle_sigma_slider: HSlider = null
var particle_sigma_label: Label = null
var mu_base_slider: HSlider = null
var mu_base_label: Label = null
var mu_range_slider: HSlider = null
var mu_range_label: Label = null

var _expanded_offset_bottom: float = 0.0
var _collapsed_offset_bottom: float = 0.0
var _is_collapsed: bool = false

var _particle_count_timer: Timer
var _pending_particle_count: int = -1

func _ready():
	_resolve_ui_nodes()
	var ui_ok = _check_ui_integrity()
	if not ui_ok:
		return  # UI broken, can't proceed
	
	_resolve_targets()
	_setup_ui()
	sync_ui_from_sim()

func _resolve_ui_nodes() -> void:
	## Resolve all UI node references using null-safe lookups.
	panel = get_node_or_null("Panel")
	wiring_status = get_node_or_null("Panel/MainVBox/HeaderRow/WiringStatus")
	collapse_button = get_node_or_null("Panel/MainVBox/HeaderRow/CollapseButton")
	body_scroll = get_node_or_null("Panel/MainVBox/BodyScroll")
	range_profile_selector = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/RangeProfileContainer/RangeProfileSelector")
	particle_count_spin = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleCountContainer/ParticleCountSpin")
	show_field_button = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/TogglesRow/ShowFieldButton")
	show_advanced = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/TogglesRow/ShowAdvancedButton")
	field_container = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer")
	particle_container = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer")
	advanced_container = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer")
	field_advanced = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced")
	particle_advanced = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced")
	
	# Field sliders
	field_mu_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldMuContainer/FieldMuSlider")
	field_mu_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldMuContainer/FieldMuValue")
	field_sigma_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldSigmaContainer/FieldSigmaSlider")
	field_sigma_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldSigmaContainer/FieldSigmaValue")
	field_dt_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDtContainer/FieldDtSlider")
	field_dt_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDtContainer/FieldDtValue")
	field_decay_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDecayContainer/FieldDecaySlider")
	field_decay_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDecayContainer/FieldDecayValue")
	field_baseline_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldBaselineContainer/FieldBaselineSlider")
	field_baseline_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldBaselineContainer/FieldBaselineValue")
	# Field advanced sliders
	field_kernel_radius_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelRadiusContainer/FieldKernelRadiusSlider")
	field_kernel_radius_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelRadiusContainer/FieldKernelRadiusValue")
	field_kernel_width_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelWidthContainer/FieldKernelWidthSlider")
	field_kernel_width_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelWidthContainer/FieldKernelWidthValue")
	
	# Particle sliders
	gradient_strength_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/GradientStrengthContainer/GradientStrengthSlider")
	gradient_strength_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/GradientStrengthContainer/GradientStrengthValue")
	repulsion_strength_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/RepulsionStrengthContainer/RepulsionStrengthSlider")
	repulsion_strength_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/RepulsionStrengthContainer/RepulsionStrengthValue")
	time_scale_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/TimeScaleContainer/TimeScaleSlider")
	time_scale_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/TimeScaleContainer/TimeScaleValue")
	min_dist_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/MinDistContainer/MinDistSlider")
	min_dist_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/MinDistContainer/MinDistValue")
	deposit_amount_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositAmountContainer/DepositAmountSlider")
	deposit_amount_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositAmountContainer/DepositAmountValue")
	deposit_radius_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositRadiusContainer/DepositRadiusSlider")
	deposit_radius_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositRadiusContainer/DepositRadiusValue")
	
	# Particle advanced sliders
	particle_kernel_radius_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelRadiusContainer/ParticleKernelRadiusSlider")
	particle_kernel_radius_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelRadiusContainer/ParticleKernelRadiusValue")
	particle_kernel_width_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelWidthContainer/ParticleKernelWidthSlider")
	particle_kernel_width_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelWidthContainer/ParticleKernelWidthValue")
	particle_sigma_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleSigmaContainer/ParticleSigmaSlider")
	particle_sigma_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleSigmaContainer/ParticleSigmaValue")
	mu_base_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/MuBaseContainer/MuBaseSlider")
	mu_base_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/MuBaseContainer/MuBaseValue")
	mu_range_slider = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/MuRangeContainer/MuRangeSlider")
	mu_range_label = get_node_or_null("Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/MuRangeContainer/MuRangeValue")

func _check_ui_integrity() -> bool:
	## Check that critical UI nodes exist. Returns false if UI is broken.
	var missing: Array[String] = []
	if panel == null:
		missing.append("Panel")
	if wiring_status == null:
		missing.append("WiringStatus")
	if collapse_button == null:
		missing.append("CollapseButton")
	if body_scroll == null:
		missing.append("BodyScroll")
	if advanced_container == null:
		missing.append("AdvancedContainer")
	
	if missing.size() > 0:
		if wiring_status != null:
			wiring_status.text = "UI broken (missing: %s)" % ", ".join(missing)
		_set_controls_enabled(false)
		return false
	
	return true

func _safe_set_visible(node: CanvasItem, should_show: bool) -> void:
	## Safely set node visibility with null check.
	if node != null:
		node.visible = should_show

func _resolve_targets() -> void:
	environment_field = null
	particle_system = null

	# 1) Explicit NodePath wiring (preferred)
	if environment_field_path != NodePath():
		var n = get_node_or_null(environment_field_path)
		if n is EnvironmentField:
			environment_field = n
	if particle_system_path != NodePath():
		var p = get_node_or_null(particle_system_path)
		if p != null and "particle_count" in p:
			particle_system = p

	# 2) Fallback wiring via unique groups (only if missing/unresolved)
	if environment_field == null:
		var env_nodes := get_tree().get_nodes_in_group("environment_field")
		if env_nodes.size() != 1:
			push_error("Expected exactly 1 node in group 'environment_field', found %d" % env_nodes.size())
		else:
			var gf = env_nodes[0]
			if gf is EnvironmentField:
				environment_field = gf

	if particle_system == null:
		var ps_nodes := get_tree().get_nodes_in_group("particle_system")
		if ps_nodes.size() != 1:
			push_error("Expected exactly 1 node in group 'particle_system', found %d" % ps_nodes.size())
		else:
			var gp = ps_nodes[0]
			if gp != null and "particle_count" in gp:
				particle_system = gp

func _setup_ui() -> void:
	# Ensure body is visible by default (not collapsed)
	_is_collapsed = false
	_safe_set_visible(body_scroll, true)
	
	# Save expanded size; compute collapsed size
	if panel != null:
		_expanded_offset_bottom = panel.offset_bottom
		_collapsed_offset_bottom = panel.offset_top + 40.0

	# Collapse button
	if collapse_button != null:
		if not collapse_button.pressed.is_connected(_on_collapse_pressed):
			collapse_button.pressed.connect(_on_collapse_pressed)
		collapse_button.text = "▾"  # Expanded state

	# Advanced toggle: one container controls all advanced widgets
	_safe_set_visible(advanced_container, false)
	if show_advanced != null:
		if not show_advanced.toggled.is_connected(_on_show_advanced_toggled):
			show_advanced.toggled.connect(_on_show_advanced_toggled)

	# Range profile selector: configure once
	if range_profile_selector != null:
		range_profile_selector.clear()
		range_profile_selector.add_item("Tuning")   # 0
		range_profile_selector.add_item("Stress")   # 1
		range_profile_selector.select(RangeProfile.TUNING)
		if not range_profile_selector.item_selected.is_connected(_on_range_profile_selected):
			range_profile_selector.item_selected.connect(_on_range_profile_selected)
		# Apply initial profile
		_apply_range_profile(RangeProfile.TUNING)

	# Bindings: connect signals (UI -> sim)
	_connect_slider(field_mu_slider, _on_field_mu_changed)
	_connect_slider(field_sigma_slider, _on_field_sigma_changed)
	_connect_slider(field_dt_slider, _on_field_dt_changed)
	_connect_slider(field_decay_slider, _on_field_decay_changed)
	_connect_slider(field_baseline_slider, _on_field_baseline_changed)
	_connect_slider(field_kernel_radius_slider, _on_field_kernel_radius_changed)
	_connect_slider(field_kernel_width_slider, _on_field_kernel_width_changed)

	_connect_slider(gradient_strength_slider, _on_gradient_strength_changed)
	_connect_slider(repulsion_strength_slider, _on_repulsion_strength_changed)
	_connect_slider(time_scale_slider, _on_time_scale_changed)
	_connect_slider(min_dist_slider, _on_min_dist_changed)
	_connect_slider(deposit_amount_slider, _on_deposit_amount_changed)
	_connect_slider(deposit_radius_slider, _on_deposit_radius_changed)

	_connect_slider(particle_kernel_radius_slider, _on_particle_kernel_radius_changed)
	_connect_slider(particle_kernel_width_slider, _on_particle_kernel_width_changed)
	_connect_slider(particle_sigma_slider, _on_particle_sigma_changed)
	_connect_slider(mu_base_slider, _on_mu_base_changed)
	_connect_slider(mu_range_slider, _on_mu_range_changed)

	if show_field_button != null:
		if not show_field_button.toggled.is_connected(_on_show_field_toggled):
			show_field_button.toggled.connect(_on_show_field_toggled)

	# Particle count: debounce to avoid realloc spam
	_particle_count_timer = Timer.new()
	_particle_count_timer.one_shot = true
	_particle_count_timer.wait_time = 0.25
	add_child(_particle_count_timer)
	_particle_count_timer.timeout.connect(_apply_pending_particle_count)
	if particle_count_spin != null:
		if not particle_count_spin.value_changed.is_connected(_on_particle_count_value_changed):
			particle_count_spin.value_changed.connect(_on_particle_count_value_changed)

	# Show/hide sections based on availability
	_safe_set_visible(field_container, environment_field != null)
	_safe_set_visible(particle_container, particle_system != null)
	if particle_count_spin != null:
		particle_count_spin.editable = (particle_system != null)

	# Fail loudly & disable controls if not wired
	var ok = (environment_field != null) or (particle_system != null)
	if wiring_status != null:
		if not ok:
			wiring_status.text = "Not wired (missing targets)"
			_set_controls_enabled(false)
		else:
			var bits: Array[String] = []
			bits.append("field" if environment_field != null else "no-field")
			bits.append("particles" if particle_system != null else "no-particles")
			wiring_status.text = "Wired: %s" % ", ".join(bits)
			_set_controls_enabled(true)

func _connect_slider(slider: HSlider, handler: Callable) -> void:
	if slider == null:
		return
	if not slider.value_changed.is_connected(handler):
		slider.value_changed.connect(handler)

func _set_controls_enabled(enabled: bool) -> void:
	# Only disable the scrollable body; keep header buttons usable.
	if body_scroll != null:
		_set_controls_enabled_recursive(body_scroll, enabled)

func _set_controls_enabled_recursive(n: Node, enabled: bool) -> void:
	if n is Range:
		n.editable = enabled
	elif n is BaseButton:
		n.disabled = not enabled
	for c in n.get_children():
		_set_controls_enabled_recursive(c, enabled)

func sync_ui_from_sim() -> void:
	# Pull sim -> UI exactly once (init / explicit refresh)
	if environment_field:
		_apply_slider(field_mu_slider, environment_field.field_mu, _update_field_mu_label)
		_apply_slider(field_sigma_slider, environment_field.field_sigma, _update_field_sigma_label)
		_apply_slider(field_dt_slider, environment_field.field_dt, _update_field_dt_label)
		_apply_slider(field_decay_slider, environment_field.field_decay, _update_field_decay_label)
		_apply_slider(field_baseline_slider, environment_field.field_baseline, _update_field_baseline_label)
		_apply_slider(field_kernel_radius_slider, environment_field.field_kernel_radius, _update_field_kernel_radius_label)
		_apply_slider(field_kernel_width_slider, environment_field.field_kernel_width, _update_field_kernel_width_label)

		if show_field_button != null:
			show_field_button.set_pressed_no_signal(environment_field.show_field)

	if particle_system:
		if particle_count_spin != null:
			particle_count_spin.set_value_no_signal(int(particle_system.get("particle_count")))

		_apply_slider(gradient_strength_slider, float(particle_system.get("gradient_strength")), _update_gradient_strength_label)
		_apply_slider(repulsion_strength_slider, float(particle_system.get("repulsion_strength")), _update_repulsion_strength_label)
		_apply_slider(time_scale_slider, float(particle_system.get("time_scale")), _update_time_scale_label)
		_apply_slider(min_dist_slider, float(particle_system.get("min_dist")), _update_min_dist_label)

		_apply_slider(particle_kernel_radius_slider, float(particle_system.get("particle_kernel_radius")), _update_particle_kernel_radius_label)
		_apply_slider(particle_kernel_width_slider, float(particle_system.get("particle_kernel_width")), _update_particle_kernel_width_label)
		_apply_slider(particle_sigma_slider, float(particle_system.get("particle_sigma")), _update_particle_sigma_label)
		_apply_slider(mu_base_slider, float(particle_system.get("mu_base")), _update_mu_base_label)
		_apply_slider(mu_range_slider, float(particle_system.get("mu_range")), _update_mu_range_label)

	# deposit sliders live on EnvironmentField
	if environment_field:
		_apply_slider(deposit_amount_slider, environment_field.deposit_amount, _update_deposit_amount_label)
		_apply_slider(deposit_radius_slider, environment_field.deposit_radius, _update_deposit_radius_label)

func _apply_slider(slider: HSlider, value: float, label_updater: Callable) -> void:
	if slider == null:
		return
	slider.set_value_no_signal(value)
	label_updater.call(value)

func _on_show_advanced_toggled(pressed: bool) -> void:
	_safe_set_visible(advanced_container, pressed)

func _on_collapse_pressed() -> void:
	_is_collapsed = not _is_collapsed
	if _is_collapsed:
		_safe_set_visible(body_scroll, false)
		if panel != null:
			panel.offset_bottom = _collapsed_offset_bottom
		if collapse_button != null:
			collapse_button.text = "▸"
	else:
		_safe_set_visible(body_scroll, true)
		if panel != null:
			panel.offset_bottom = _expanded_offset_bottom
		if collapse_button != null:
			collapse_button.text = "▾"

func _on_particle_count_value_changed(value: float) -> void:
	if particle_system == null:
		return
	# Safety: must be >= 1 to avoid 0-workgroup dispatch
	_pending_particle_count = max(1, int(value))
	_particle_count_timer.start()

func _apply_pending_particle_count() -> void:
	if particle_system == null:
		return
	if _pending_particle_count < 0:
		return
	var current = int(particle_system.get("particle_count"))
	if current != _pending_particle_count:
		particle_system.set("particle_count", _pending_particle_count)

func _setup_field_sliders():
	if not environment_field:
		return
	# Field mu
	if field_mu_slider:
		field_mu_slider.min_value = 0.0
		field_mu_slider.max_value = 1.0
		field_mu_slider.value = environment_field.field_mu
		field_mu_slider.value_changed.connect(_on_field_mu_changed)
		_update_field_mu_label(environment_field.field_mu)
	
	# Field sigma
	if field_sigma_slider:
		field_sigma_slider.min_value = 0.01
		field_sigma_slider.max_value = 0.5
		field_sigma_slider.value = environment_field.field_sigma
		field_sigma_slider.value_changed.connect(_on_field_sigma_changed)
		_update_field_sigma_label(environment_field.field_sigma)
	
	# Field dt
	if field_dt_slider:
		field_dt_slider.min_value = 0.0
		field_dt_slider.max_value = 0.1
		field_dt_slider.value = environment_field.field_dt
		field_dt_slider.value_changed.connect(_on_field_dt_changed)
		_update_field_dt_label(environment_field.field_dt)
	
	# Field decay
	if field_decay_slider:
		field_decay_slider.min_value = 0.0
		field_decay_slider.max_value = 0.1
		field_decay_slider.value = environment_field.field_decay
		field_decay_slider.value_changed.connect(_on_field_decay_changed)
		_update_field_decay_label(environment_field.field_decay)

	# Field baseline (deposit decay target; affects particle_deposit.glsl)
	if field_baseline_slider:
		field_baseline_slider.min_value = 0.0
		field_baseline_slider.max_value = 1.0
		field_baseline_slider.value = environment_field.field_baseline
		field_baseline_slider.value_changed.connect(_on_field_baseline_changed)
		_update_field_baseline_label(environment_field.field_baseline)

	# Show field visualization
	if show_field_button:
		show_field_button.button_pressed = environment_field.show_field
		show_field_button.toggled.connect(_on_show_field_toggled)
	
	# Field kernel radius (advanced)
	if field_kernel_radius_slider:
		field_kernel_radius_slider.min_value = 1.0
		field_kernel_radius_slider.max_value = 50.0
		field_kernel_radius_slider.value = environment_field.field_kernel_radius
		field_kernel_radius_slider.value_changed.connect(_on_field_kernel_radius_changed)
		_update_field_kernel_radius_label(environment_field.field_kernel_radius)
	
	# Field kernel width (advanced)
	if field_kernel_width_slider:
		field_kernel_width_slider.min_value = 0.5
		field_kernel_width_slider.max_value = 20.0
		field_kernel_width_slider.value = environment_field.field_kernel_width
		field_kernel_width_slider.value_changed.connect(_on_field_kernel_width_changed)
		_update_field_kernel_width_label(environment_field.field_kernel_width)

func _setup_particle_sliders():
	if not particle_system:
		return
	# Gradient strength
	if gradient_strength_slider:
		gradient_strength_slider.min_value = 0.0
		gradient_strength_slider.max_value = 300.0
		if "gradient_strength" in particle_system:
			gradient_strength_slider.value = particle_system.get("gradient_strength")
			gradient_strength_slider.value_changed.connect(_on_gradient_strength_changed)
			_update_gradient_strength_label(particle_system.get("gradient_strength"))
	
	# Repulsion strength
	if repulsion_strength_slider:
		repulsion_strength_slider.min_value = 0.0
		repulsion_strength_slider.max_value = 300.0
		if "repulsion_strength" in particle_system:
			repulsion_strength_slider.value = particle_system.get("repulsion_strength")
			repulsion_strength_slider.value_changed.connect(_on_repulsion_strength_changed)
			_update_repulsion_strength_label(particle_system.get("repulsion_strength"))
	
	# Time scale
	if time_scale_slider:
		time_scale_slider.min_value = 0.0
		time_scale_slider.max_value = 5.0
		if "time_scale" in particle_system:
			time_scale_slider.value = particle_system.get("time_scale")
			time_scale_slider.value_changed.connect(_on_time_scale_changed)
			_update_time_scale_label(particle_system.get("time_scale"))
	
	# Min dist
	if min_dist_slider:
		min_dist_slider.min_value = 0.0
		min_dist_slider.max_value = 50.0
		if "min_dist" in particle_system:
			min_dist_slider.value = particle_system.get("min_dist")
			min_dist_slider.value_changed.connect(_on_min_dist_changed)
			_update_min_dist_label(particle_system.get("min_dist"))
	
	# Deposit amount (on environment_field)
	if environment_field and deposit_amount_slider:
		deposit_amount_slider.min_value = 0.0
		deposit_amount_slider.max_value = 1.0
		deposit_amount_slider.value = environment_field.deposit_amount
		deposit_amount_slider.value_changed.connect(_on_deposit_amount_changed)
		_update_deposit_amount_label(environment_field.deposit_amount)
	
	# Deposit radius (on environment_field)
	if environment_field and deposit_radius_slider:
		deposit_radius_slider.min_value = 0.0
		deposit_radius_slider.max_value = 50.0
		deposit_radius_slider.value = environment_field.deposit_radius
		deposit_radius_slider.value_changed.connect(_on_deposit_radius_changed)
		_update_deposit_radius_label(environment_field.deposit_radius)
	
	# Particle kernel radius (advanced)
	if "particle_kernel_radius" in particle_system and particle_kernel_radius_slider:
		particle_kernel_radius_slider.min_value = 1.0
		particle_kernel_radius_slider.max_value = 500.0
		particle_kernel_radius_slider.value = particle_system.get("particle_kernel_radius")
		particle_kernel_radius_slider.value_changed.connect(_on_particle_kernel_radius_changed)
		_update_particle_kernel_radius_label(particle_system.get("particle_kernel_radius"))
	
	# Particle kernel width (advanced)
	if "particle_kernel_width" in particle_system and particle_kernel_width_slider:
		particle_kernel_width_slider.min_value = 1.0
		particle_kernel_width_slider.max_value = 100.0
		particle_kernel_width_slider.value = particle_system.get("particle_kernel_width")
		particle_kernel_width_slider.value_changed.connect(_on_particle_kernel_width_changed)
		_update_particle_kernel_width_label(particle_system.get("particle_kernel_width"))
	
	# Particle sigma (advanced)
	if "particle_sigma" in particle_system and particle_sigma_slider:
		particle_sigma_slider.min_value = 0.001
		particle_sigma_slider.max_value = 0.2
		particle_sigma_slider.value = particle_system.get("particle_sigma")
		particle_sigma_slider.value_changed.connect(_on_particle_sigma_changed)
		_update_particle_sigma_label(particle_system.get("particle_sigma"))
	
	# Mu base (advanced)
	if "mu_base" in particle_system and mu_base_slider:
		mu_base_slider.min_value = 0.0
		mu_base_slider.max_value = 1.0
		mu_base_slider.value = particle_system.get("mu_base")
		mu_base_slider.value_changed.connect(_on_mu_base_changed)
		_update_mu_base_label(particle_system.get("mu_base"))
	
	# Mu range (advanced) - field influence strength
	if "mu_range" in particle_system and mu_range_slider:
		mu_range_slider.min_value = 0.0
		mu_range_slider.max_value = 0.1
		mu_range_slider.value = particle_system.get("mu_range")
		mu_range_slider.value_changed.connect(_on_mu_range_changed)
		_update_mu_range_label(particle_system.get("mu_range"))

# Field slider handlers
func _on_field_mu_changed(value: float):
	if environment_field:
		environment_field.field_mu = value
		_update_field_mu_label(value)

func _on_field_sigma_changed(value: float):
	if environment_field:
		environment_field.field_sigma = value
		_update_field_sigma_label(value)

func _on_field_dt_changed(value: float):
	if environment_field:
		environment_field.field_dt = value
		_update_field_dt_label(value)

func _on_field_decay_changed(value: float):
	if environment_field:
		environment_field.field_decay = value
		_update_field_decay_label(value)

func _on_field_baseline_changed(value: float):
	if environment_field:
		environment_field.field_baseline = value
		_update_field_baseline_label(value)

func _on_show_field_toggled(pressed: bool):
	if environment_field:
		environment_field.show_field = pressed
		# Visualization is world-space Sprite2D; sync visibility immediately.
		if environment_field.has_method("_apply_show_field_visibility"):
			environment_field.call("_apply_show_field_visibility")

func _on_field_kernel_radius_changed(value: float):
	if environment_field:
		environment_field.field_kernel_radius = value
		_update_field_kernel_radius_label(value)

func _on_field_kernel_width_changed(value: float):
	if environment_field:
		environment_field.field_kernel_width = value
		_update_field_kernel_width_label(value)

# Particle slider handlers
func _on_gradient_strength_changed(value: float):
	if particle_system and "gradient_strength" in particle_system:
		particle_system.set("gradient_strength", value)
		_update_gradient_strength_label(value)

func _on_repulsion_strength_changed(value: float):
	if particle_system and "repulsion_strength" in particle_system:
		particle_system.set("repulsion_strength", value)
		_update_repulsion_strength_label(value)

func _on_time_scale_changed(value: float):
	if particle_system and "time_scale" in particle_system:
		particle_system.set("time_scale", value)
		_update_time_scale_label(value)

func _on_min_dist_changed(value: float):
	if particle_system and "min_dist" in particle_system:
		particle_system.set("min_dist", value)
		_update_min_dist_label(value)

func _on_deposit_amount_changed(value: float):
	if environment_field:
		environment_field.deposit_amount = value
		_update_deposit_amount_label(value)

func _on_deposit_radius_changed(value: float):
	if environment_field:
		# Safety: must be > 0 if CPU fallback deposit is used; GPU path tolerates 0 but produces no deposit
		environment_field.deposit_radius = max(0.0001, value)
		_update_deposit_radius_label(environment_field.deposit_radius)

func _on_particle_kernel_radius_changed(value: float):
	if particle_system and "particle_kernel_radius" in particle_system:
		particle_system.set("particle_kernel_radius", value)
		_update_particle_kernel_radius_label(value)

func _on_particle_kernel_width_changed(value: float):
	if particle_system and "particle_kernel_width" in particle_system:
		particle_system.set("particle_kernel_width", value)
		_update_particle_kernel_width_label(value)

func _on_particle_sigma_changed(value: float):
	if particle_system and "particle_sigma" in particle_system:
		particle_system.set("particle_sigma", value)
		_update_particle_sigma_label(value)

func _on_mu_base_changed(value: float):
	if particle_system and "mu_base" in particle_system:
		particle_system.set("mu_base", value)
		_update_mu_base_label(value)

func _on_mu_range_changed(value: float):
	if particle_system and "mu_range" in particle_system:
		particle_system.set("mu_range", value)
		_update_mu_range_label(value)

# Label update helpers (null-safe)
func _update_field_mu_label(value: float):
	if field_mu_label != null:
		field_mu_label.text = "%.3f" % value

func _update_field_sigma_label(value: float):
	if field_sigma_label != null:
		field_sigma_label.text = "%.3f" % value

func _update_field_dt_label(value: float):
	if field_dt_label != null:
		field_dt_label.text = "%.3f" % value

func _update_field_decay_label(value: float):
	if field_decay_label != null:
		field_decay_label.text = "%.3f" % value

func _update_field_baseline_label(value: float):
	if field_baseline_label != null:
		field_baseline_label.text = "%.3f" % value

func _update_field_kernel_radius_label(value: float):
	if field_kernel_radius_label != null:
		field_kernel_radius_label.text = "%.1f" % value

func _update_field_kernel_width_label(value: float):
	if field_kernel_width_label != null:
		field_kernel_width_label.text = "%.1f" % value

func _update_gradient_strength_label(value: float):
	if gradient_strength_label != null:
		gradient_strength_label.text = "%.1f" % value

func _update_repulsion_strength_label(value: float):
	if repulsion_strength_label != null:
		repulsion_strength_label.text = "%.1f" % value

func _update_time_scale_label(value: float):
	if time_scale_label != null:
		time_scale_label.text = "%.2f" % value

func _update_min_dist_label(value: float):
	if min_dist_label != null:
		min_dist_label.text = "%.1f" % value

func _update_deposit_amount_label(value: float):
	if deposit_amount_label != null:
		deposit_amount_label.text = "%.4f" % value

func _update_deposit_radius_label(value: float):
	if deposit_radius_label != null:
		deposit_radius_label.text = "%.1f" % value

func _update_particle_kernel_radius_label(value: float):
	if particle_kernel_radius_label != null:
		particle_kernel_radius_label.text = "%.1f" % value

func _update_particle_kernel_width_label(value: float):
	if particle_kernel_width_label != null:
		particle_kernel_width_label.text = "%.1f" % value

func _update_particle_sigma_label(value: float):
	if particle_sigma_label != null:
		particle_sigma_label.text = "%.3f" % value

func _update_mu_base_label(value: float):
	if mu_base_label != null:
		mu_base_label.text = "%.3f" % value

func _update_mu_range_label(value: float):
	if mu_range_label != null:
		mu_range_label.text = "%.3f" % value

func _on_range_profile_selected(index: int) -> void:
	_apply_range_profile(index)

func _apply_range_profile(profile: int) -> void:
	## Apply range preset (Tuning or Stress) to all sliders/spinboxes at runtime.
	match profile:
		RangeProfile.TUNING:
			_apply_tuning_ranges()
		RangeProfile.STRESS:
			_apply_stress_ranges()

func _apply_tuning_ranges() -> void:
	## "Tuning" profile: tighter ranges for normal exploration.
	if particle_count_spin:
		particle_count_spin.min_value = 64
		particle_count_spin.max_value = 4096
		particle_count_spin.step = 1
	
	if gradient_strength_slider:
		gradient_strength_slider.min_value = 0.0
		gradient_strength_slider.max_value = 2000.0
		gradient_strength_slider.step = 5.0
	
	if repulsion_strength_slider:
		repulsion_strength_slider.min_value = 0.0
		repulsion_strength_slider.max_value = 2000.0
		repulsion_strength_slider.step = 5.0
	
	if min_dist_slider:
		min_dist_slider.min_value = 0.0
		min_dist_slider.max_value = 150.0
		min_dist_slider.step = 0.5
	
	if time_scale_slider:
		time_scale_slider.min_value = 0.0
		time_scale_slider.max_value = 5.0
		time_scale_slider.step = 0.01
	
	if deposit_amount_slider:
		deposit_amount_slider.min_value = 0.0
		deposit_amount_slider.max_value = 0.02
		deposit_amount_slider.step = 0.00001
	
	if deposit_radius_slider:
		deposit_radius_slider.min_value = 0.5
		deposit_radius_slider.max_value = 80.0
		deposit_radius_slider.step = 0.5
	
	if field_decay_slider:
		field_decay_slider.min_value = 0.0
		field_decay_slider.max_value = 0.05
		field_decay_slider.step = 0.0001
	
	if field_baseline_slider:
		field_baseline_slider.min_value = 0.0
		field_baseline_slider.max_value = 1.0
		field_baseline_slider.step = 0.001
	
	if field_mu_slider:
		field_mu_slider.min_value = 0.0
		field_mu_slider.max_value = 1.0
		field_mu_slider.step = 0.001
	
	if field_sigma_slider:
		field_sigma_slider.min_value = 0.002
		field_sigma_slider.max_value = 0.15
		field_sigma_slider.step = 0.001
	
	if field_dt_slider:
		field_dt_slider.min_value = 0.0
		field_dt_slider.max_value = 0.03
		field_dt_slider.step = 0.0005
	
	if field_kernel_radius_slider:
		field_kernel_radius_slider.min_value = 1.0
		field_kernel_radius_slider.max_value = 80.0
		field_kernel_radius_slider.step = 0.5
	
	if field_kernel_width_slider:
		field_kernel_width_slider.min_value = 0.5
		field_kernel_width_slider.max_value = 30.0
		field_kernel_width_slider.step = 0.5
	
	# Particle Lenia parameters (advanced)
	if particle_kernel_radius_slider:
		particle_kernel_radius_slider.min_value = 10.0
		particle_kernel_radius_slider.max_value = 200.0
		particle_kernel_radius_slider.step = 1.0
	
	if particle_kernel_width_slider:
		particle_kernel_width_slider.min_value = 1.0
		particle_kernel_width_slider.max_value = 50.0
		particle_kernel_width_slider.step = 0.5
	
	if particle_sigma_slider:
		particle_sigma_slider.min_value = 0.001
		particle_sigma_slider.max_value = 0.1
		particle_sigma_slider.step = 0.001
	
	# Field → Particle coupling (advanced)
	if mu_base_slider:
		mu_base_slider.min_value = 0.0
		mu_base_slider.max_value = 0.2
		mu_base_slider.step = 0.001
	
	if mu_range_slider:
		mu_range_slider.min_value = 0.0
		mu_range_slider.max_value = 0.05
		mu_range_slider.step = 0.0005

func _apply_stress_ranges() -> void:
	## "Stress" profile: wider ranges for extreme / debugging.
	if particle_count_spin:
		particle_count_spin.min_value = 1
		particle_count_spin.max_value = 20000
		particle_count_spin.step = 1
	
	if gradient_strength_slider:
		gradient_strength_slider.min_value = 0.0
		gradient_strength_slider.max_value = 20000.0
		gradient_strength_slider.step = 50.0
	
	if repulsion_strength_slider:
		repulsion_strength_slider.min_value = 0.0
		repulsion_strength_slider.max_value = 20000.0
		repulsion_strength_slider.step = 50.0
	
	if min_dist_slider:
		min_dist_slider.min_value = 0.0
		min_dist_slider.max_value = 500.0
		min_dist_slider.step = 1.0
	
	if time_scale_slider:
		time_scale_slider.min_value = 0.0
		time_scale_slider.max_value = 5.0
		time_scale_slider.step = 0.01
	
	if deposit_amount_slider:
		deposit_amount_slider.min_value = 0.0
		deposit_amount_slider.max_value = 0.2
		deposit_amount_slider.step = 0.0001
	
	if deposit_radius_slider:
		deposit_radius_slider.min_value = 0.0
		deposit_radius_slider.max_value = 200.0
		deposit_radius_slider.step = 1.0
	
	if field_decay_slider:
		field_decay_slider.min_value = 0.0
		field_decay_slider.max_value = 0.5
		field_decay_slider.step = 0.001
	
	if field_baseline_slider:
		field_baseline_slider.min_value = -0.5
		field_baseline_slider.max_value = 1.5
		field_baseline_slider.step = 0.001
	
	if field_mu_slider:
		field_mu_slider.min_value = 0.0
		field_mu_slider.max_value = 1.0
		field_mu_slider.step = 0.001
	
	if field_sigma_slider:
		field_sigma_slider.min_value = 0.001
		field_sigma_slider.max_value = 0.5
		field_sigma_slider.step = 0.001
	
	if field_dt_slider:
		field_dt_slider.min_value = 0.0
		field_dt_slider.max_value = 0.1
		field_dt_slider.step = 0.001
	
	if field_kernel_radius_slider:
		field_kernel_radius_slider.min_value = 1.0
		field_kernel_radius_slider.max_value = 200.0
		field_kernel_radius_slider.step = 1.0
	
	if field_kernel_width_slider:
		field_kernel_width_slider.min_value = 0.1
		field_kernel_width_slider.max_value = 80.0
		field_kernel_width_slider.step = 1.0
	
	# Particle Lenia parameters (advanced)
	if particle_kernel_radius_slider:
		particle_kernel_radius_slider.min_value = 5.0
		particle_kernel_radius_slider.max_value = 500.0
		particle_kernel_radius_slider.step = 5.0
	
	if particle_kernel_width_slider:
		particle_kernel_width_slider.min_value = 0.5
		particle_kernel_width_slider.max_value = 100.0
		particle_kernel_width_slider.step = 1.0
	
	if particle_sigma_slider:
		particle_sigma_slider.min_value = 0.0005
		particle_sigma_slider.max_value = 0.5
		particle_sigma_slider.step = 0.001
	
	# Field → Particle coupling (advanced)
	if mu_base_slider:
		mu_base_slider.min_value = 0.0
		mu_base_slider.max_value = 1.0
		mu_base_slider.step = 0.001
	
	if mu_range_slider:
		mu_range_slider.min_value = 0.0
		mu_range_slider.max_value = 0.2
		mu_range_slider.step = 0.001

# Helper to find node with property
func _find_node_with_property(node: Node, property: String) -> Node:
	if property in node:
		return node
	for child in node.get_children():
		var result = _find_node_with_property(child, property)
		if result:
			return result
	return null

#
# NOTE: Reset/Pause intentionally omitted.
# There is no single authoritative reset/pause API in the simulation scripts yet,
# and we avoid inventing new behavior in the UI layer.

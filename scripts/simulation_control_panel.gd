class_name SimulationControlPanel
extends CanvasLayer

## Runtime control panel for tweaking simulation parameters live

@export var environment_field_path: NodePath
@export var particle_system_path: NodePath

var environment_field: EnvironmentField = null
var particle_system: Node = null  # ParticleSystemGPU

# UI References
@onready var panel: Panel = $Control/Panel
@onready var open_button: Button = $Control/OpenButton
@onready var wiring_status: Label = $Control/Panel/MainVBox/HeaderRow/WiringStatus
@onready var collapse_button: Button = $Control/Panel/MainVBox/HeaderRow/CollapseButton
@onready var close_button: Button = $Control/Panel/MainVBox/HeaderRow/CloseButton

@onready var body_scroll: ScrollContainer = $Control/Panel/MainVBox/BodyScroll
@onready var mode_selector: OptionButton = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ModeContainer/ModeSelector
@onready var particle_count_spin: SpinBox = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleCountContainer/ParticleCountSpin
@onready var show_field_button: CheckButton = $Control/Panel/MainVBox/BodyScroll/BodyVBox/TogglesRow/ShowFieldButton
@onready var show_advanced: CheckButton = $Control/Panel/MainVBox/BodyScroll/BodyVBox/TogglesRow/ShowAdvancedButton

@onready var field_container: VBoxContainer = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer
@onready var particle_container: VBoxContainer = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer
@onready var advanced_container: VBoxContainer = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer
@onready var field_advanced: VBoxContainer = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced
@onready var particle_advanced: VBoxContainer = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced

# Field sliders
@onready var field_mu_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldMuContainer/FieldMuSlider
@onready var field_mu_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldMuContainer/FieldMuValue
@onready var field_sigma_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldSigmaContainer/FieldSigmaSlider
@onready var field_sigma_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldSigmaContainer/FieldSigmaValue
@onready var field_dt_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDtContainer/FieldDtSlider
@onready var field_dt_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDtContainer/FieldDtValue
@onready var field_decay_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDecayContainer/FieldDecaySlider
@onready var field_decay_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldDecayContainer/FieldDecayValue
@onready var field_baseline_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldBaselineContainer/FieldBaselineSlider
@onready var field_baseline_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/FieldContainer/FieldBasic/FieldBaselineContainer/FieldBaselineValue
# Field advanced sliders
@onready var field_kernel_radius_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelRadiusContainer/FieldKernelRadiusSlider
@onready var field_kernel_radius_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelRadiusContainer/FieldKernelRadiusValue
@onready var field_kernel_width_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelWidthContainer/FieldKernelWidthSlider
@onready var field_kernel_width_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/FieldAdvanced/FieldKernelWidthContainer/FieldKernelWidthValue

# Particle sliders
@onready var gradient_strength_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/GradientStrengthContainer/GradientStrengthSlider
@onready var gradient_strength_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/GradientStrengthContainer/GradientStrengthValue
@onready var repulsion_strength_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/RepulsionStrengthContainer/RepulsionStrengthSlider
@onready var repulsion_strength_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/RepulsionStrengthContainer/RepulsionStrengthValue
@onready var time_scale_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/TimeScaleContainer/TimeScaleSlider
@onready var time_scale_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/TimeScaleContainer/TimeScaleValue
@onready var min_dist_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/MinDistContainer/MinDistSlider
@onready var min_dist_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/MinDistContainer/MinDistValue
@onready var deposit_amount_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositAmountContainer/DepositAmountSlider
@onready var deposit_amount_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositAmountContainer/DepositAmountValue
@onready var deposit_radius_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositRadiusContainer/DepositRadiusSlider
@onready var deposit_radius_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/ParticleContainer/ParticleBasic/DepositRadiusContainer/DepositRadiusValue

# Particle advanced sliders
@onready var particle_kernel_radius_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelRadiusContainer/ParticleKernelRadiusSlider
@onready var particle_kernel_radius_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelRadiusContainer/ParticleKernelRadiusValue
@onready var particle_kernel_width_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelWidthContainer/ParticleKernelWidthSlider
@onready var particle_kernel_width_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleKernelWidthContainer/ParticleKernelWidthValue
@onready var particle_sigma_slider: HSlider = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleSigmaContainer/ParticleSigmaSlider
@onready var particle_sigma_label: Label = $Control/Panel/MainVBox/BodyScroll/BodyVBox/AdvancedContainer/ParticleAdvanced/ParticleSigmaContainer/ParticleSigmaValue

var _expanded_offset_bottom: float = 0.0
var _collapsed_offset_bottom: float = 0.0
var _is_collapsed: bool = false

var _particle_count_timer: Timer
var _pending_particle_count: int = -1

func _ready():
	_resolve_targets()
	_setup_ui()
	sync_ui_from_sim()

func _resolve_targets() -> void:
	environment_field = null
	particle_system = null

	if environment_field_path != NodePath():
		var n = get_node_or_null(environment_field_path)
		if n is EnvironmentField:
			environment_field = n
	if particle_system_path != NodePath():
		var p = get_node_or_null(particle_system_path)
		if p != null and "simulation_mode" in p:
			particle_system = p

	# Optional fallback: groups (only if paths aren't set)
	if environment_field == null:
		var gf = get_tree().get_first_node_in_group("environment_field")
		if gf is EnvironmentField:
			environment_field = gf
	if particle_system == null:
		var gp = get_tree().get_first_node_in_group("particle_system")
		if gp != null and "simulation_mode" in gp:
			particle_system = gp

func _setup_ui() -> void:
	# Save expanded size; compute collapsed size
	_expanded_offset_bottom = panel.offset_bottom
	_collapsed_offset_bottom = panel.offset_top + 40.0

	# Collapsed open button
	if not open_button.pressed.is_connected(_on_open_pressed):
		open_button.pressed.connect(_on_open_pressed)

	# Close/collapse buttons
	if not close_button.pressed.is_connected(_on_close_pressed):
		close_button.pressed.connect(_on_close_pressed)
	if not collapse_button.pressed.is_connected(_on_collapse_pressed):
		collapse_button.pressed.connect(_on_collapse_pressed)

	# Advanced toggle: one container controls all advanced widgets
	advanced_container.visible = false
	if not show_advanced.toggled.is_connected(_on_show_advanced_toggled):
		show_advanced.toggled.connect(_on_show_advanced_toggled)

	# Mode selector: configure once
	mode_selector.clear()
	mode_selector.add_item("Field only")      # 0
	mode_selector.add_item("Swarm frozen")    # 1
	mode_selector.add_item("Coupled")         # 2
	if not mode_selector.item_selected.is_connected(_on_mode_selected):
		mode_selector.item_selected.connect(_on_mode_selected)

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

	if not show_field_button.toggled.is_connected(_on_show_field_toggled):
		show_field_button.toggled.connect(_on_show_field_toggled)

	# Particle count: debounce to avoid realloc spam
	_particle_count_timer = Timer.new()
	_particle_count_timer.one_shot = true
	_particle_count_timer.wait_time = 0.25
	add_child(_particle_count_timer)
	_particle_count_timer.timeout.connect(_apply_pending_particle_count)
	if not particle_count_spin.value_changed.is_connected(_on_particle_count_value_changed):
		particle_count_spin.value_changed.connect(_on_particle_count_value_changed)

	# Show/hide sections based on availability
	field_container.visible = (environment_field != null)
	particle_container.visible = (particle_system != null)
	mode_selector.visible = (particle_system != null)
	particle_count_spin.editable = (particle_system != null)

	# Fail loudly & disable controls if not wired
	var ok = (environment_field != null) or (particle_system != null)
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

		show_field_button.set_pressed_no_signal(environment_field.show_field)

	if particle_system:
		mode_selector.select(int(particle_system.get("simulation_mode")))
		particle_count_spin.set_value_no_signal(int(particle_system.get("particle_count")))

		_apply_slider(gradient_strength_slider, float(particle_system.get("gradient_strength")), _update_gradient_strength_label)
		_apply_slider(repulsion_strength_slider, float(particle_system.get("repulsion_strength")), _update_repulsion_strength_label)
		_apply_slider(time_scale_slider, float(particle_system.get("time_scale")), _update_time_scale_label)
		_apply_slider(min_dist_slider, float(particle_system.get("min_dist")), _update_min_dist_label)

		_apply_slider(particle_kernel_radius_slider, float(particle_system.get("particle_kernel_radius")), _update_particle_kernel_radius_label)
		_apply_slider(particle_kernel_width_slider, float(particle_system.get("particle_kernel_width")), _update_particle_kernel_width_label)
		_apply_slider(particle_sigma_slider, float(particle_system.get("particle_sigma")), _update_particle_sigma_label)

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
	advanced_container.visible = pressed

func _on_collapse_pressed() -> void:
	_is_collapsed = not _is_collapsed
	if _is_collapsed:
		body_scroll.visible = false
		panel.offset_bottom = _collapsed_offset_bottom
		collapse_button.text = "▸"
	else:
		body_scroll.visible = true
		panel.offset_bottom = _expanded_offset_bottom
		collapse_button.text = "▾"

func _on_close_pressed() -> void:
	panel.visible = false
	open_button.visible = true

func _on_open_pressed() -> void:
	open_button.visible = false
	panel.visible = true
	# restore expanded state
	_is_collapsed = false
	body_scroll.visible = true
	panel.offset_bottom = _expanded_offset_bottom
	collapse_button.text = "▾"

func _on_particle_count_value_changed(value: float) -> void:
	if particle_system == null:
		return
	_pending_particle_count = int(value)
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

func _on_mode_selected(index: int):
	if not particle_system:
		return
	if "simulation_mode" in particle_system:
		particle_system.set("simulation_mode", index)

func _on_advanced_toggled(button_pressed: bool):
	# Backwards-compat shim (old signal hookup). Prefer _on_show_advanced_toggled().
	advanced_container.visible = button_pressed

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
		environment_field.deposit_radius = value
		_update_deposit_radius_label(value)

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

# Label update helpers
func _update_field_mu_label(value: float):
	field_mu_label.text = "%.3f" % value

func _update_field_sigma_label(value: float):
	field_sigma_label.text = "%.3f" % value

func _update_field_dt_label(value: float):
	field_dt_label.text = "%.3f" % value

func _update_field_decay_label(value: float):
	field_decay_label.text = "%.3f" % value

func _update_field_baseline_label(value: float):
	field_baseline_label.text = "%.3f" % value

func _update_field_kernel_radius_label(value: float):
	field_kernel_radius_label.text = "%.1f" % value

func _update_field_kernel_width_label(value: float):
	field_kernel_width_label.text = "%.1f" % value

func _update_gradient_strength_label(value: float):
	gradient_strength_label.text = "%.1f" % value

func _update_repulsion_strength_label(value: float):
	repulsion_strength_label.text = "%.1f" % value

func _update_time_scale_label(value: float):
	time_scale_label.text = "%.2f" % value

func _update_min_dist_label(value: float):
	min_dist_label.text = "%.1f" % value

func _update_deposit_amount_label(value: float):
	deposit_amount_label.text = "%.4f" % value

func _update_deposit_radius_label(value: float):
	deposit_radius_label.text = "%.1f" % value

func _update_particle_kernel_radius_label(value: float):
	particle_kernel_radius_label.text = "%.1f" % value

func _update_particle_kernel_width_label(value: float):
	particle_kernel_width_label.text = "%.1f" % value

func _update_particle_sigma_label(value: float):
	particle_sigma_label.text = "%.3f" % value

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

class_name Player
extends CharacterBody2D

enum Direction {
    LEFT = -1,
    RIGHT = +1,
}

enum State {
    IDLE,
    RUNNING,
    JUMP,
    FALL,
    LANDING,
    WALL_SLIDING,
    WALL_JUMP,
    ATTACK_1,
    ATTACK_2,
    ATTACK_3,
    HURT,
    DYING,
    SLIDING_START,
    SLIDING_LOOP,
    SLIDING_END,
}

const RUN_SPEED: float = 160.0
const ACCELERATION_FLOOR: float = RUN_SPEED / 0.2
const ACCELERATION_AIR: float = RUN_SPEED / 0.1
const JUMP_VELOCITY: float = -360.0
const WALL_JUMP_VELOCITY: Vector2 = Vector2(400, -320.0)
const GROUND_STATES: Array = [State.IDLE, State.RUNNING, State.LANDING, State.ATTACK_1, State.ATTACK_2, State.ATTACK_3]
const KNOCKBACK_AMOUNT: int = 512
const SLIDING_DURATION: float = 0.3
const SLIDING_SPEED: float = 256.0
const LANDING_HEIGHT: float = 100.0
const SLIDING_ENERGY: float = 4.0

@export var can_combo: bool = false
@export var direction: Direction = Direction.RIGHT:
    set(v):
        direction = v
        if not self.is_node_ready():
            await self.ready
        self.graphics.scale.x = v

var default_gravity: float = ProjectSettings.get("physics/2d/default_gravity")
var is_first_tick: bool = false
var is_combo_requested: bool = false
var pending_damage: Damage = null
var fall_from_y: float = 0.0
var interacting_with: Array[Interactable] = []

@onready var graphics: Node2D = $Graphics
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var coyote_timer: Timer = $CoyoteTimer
@onready var jump_request_timer: Timer = $JumpRequestTimer
@onready var hand_checker: RayCast2D = $Graphics/HandChecker
@onready var foot_checker: RayCast2D = $Graphics/FootChecker
@onready var state_machine: StateMachine = $StateMachine
@onready var stats: Stats = Game.player_stats
@onready var invincible_timer: Timer = $InvincibleTimer
@onready var slide_request_timer: Timer = $SlideRequestTimer
@onready var interaction_icon: AnimatedSprite2D = $InteractionIcon
@onready var game_over_screen: Control = $CanvasLayer/GameOverScreen
@onready var pause_screen: Control = $CanvasLayer/PauseScreen

func _ready() -> void:
    self.stand(self.default_gravity, 0.01)

func tick_physics(state: State, delta: float) -> void:
    self.interaction_icon.visible = not self.interacting_with.is_empty()
    if self.invincible_timer.time_left > 0:
        self.graphics.modulate.a = sin(Time.get_ticks_msec() / 20) * 0.5 + 0.5
    else:
        self.graphics.modulate.a = 1
    match state:
        State.IDLE:
            self.move(self.default_gravity, delta)
        State.RUNNING:
            self.move(self.default_gravity, delta)
        State.JUMP:
            self.move(0.0 if self.is_first_tick else self.default_gravity, delta)
        State.FALL:
            self.move(self.default_gravity, delta)
        State.LANDING:
            self.stand(self.default_gravity, delta)
        State.WALL_SLIDING:
            self.move(self.default_gravity / 3, delta)
            self.direction = Direction.LEFT if self.get_wall_normal().x else Direction.RIGHT
        State.WALL_JUMP:
            if self.state_machine.state_time < 0.1:
                self.stand(0.0 if self.is_first_tick else self.default_gravity, delta)
                self.direction = Direction.LEFT if self.get_wall_normal().x else Direction.RIGHT
            else:
                move(self.default_gravity, delta)
        State.ATTACK_1, State.ATTACK_2, State.ATTACK_3:
            self.stand(self.default_gravity, delta)
        State.HURT, State.DYING:
            self.stand(self.default_gravity, delta)
        State.SLIDING_START, State.SLIDING_LOOP:
            self.slide(delta)
        State.SLIDING_END:
            self.stand(self.default_gravity, delta)
    self.is_first_tick = false

func move(gravity: float, delta: float) -> void:
    var movement: float = Input.get_axis("move_left", "move_right")
    var acceleration: float = ACCELERATION_FLOOR if self.is_on_floor() else ACCELERATION_AIR
    self.velocity.x = move_toward(self.velocity.x, movement * RUN_SPEED, acceleration * delta)
    self.velocity.y += gravity * delta

    if not is_zero_approx(movement):
        self.direction = Direction.LEFT if movement < 0 else Direction.RIGHT
    self.move_and_slide()

func stand(gravity: float, delta: float) -> void:
    var acceleration: float = ACCELERATION_FLOOR if self.is_on_floor() else ACCELERATION_AIR
    self.velocity.x = move_toward(self.velocity.x, 0.0, acceleration * delta)
    self.velocity.y += gravity * delta
    self.move_and_slide()

func slide(delta: float) -> void:
    self.velocity.x = self.graphics.scale.x * SLIDING_SPEED
    self.velocity.y = self.default_gravity * delta
    self.move_and_slide()

func die() -> void:
    self.game_over_screen.show_game_over()

func register_interactable(v: Interactable) -> void:
    if self.state_machine.cur_state == State.DYING:
        return
    if v in self.interacting_with:
        return
    self.interacting_with.append(v)

func unregister_interactable(v: Interactable) -> void:
    self.interacting_with.erase(v)

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("jump"):
        jump_request_timer.start()
    if event.is_action_released("jump"):
        jump_request_timer.stop()
        if self.velocity.y < JUMP_VELOCITY / 2:
            self.velocity.y = JUMP_VELOCITY / 2
    if event.is_action_pressed("attack") and self.can_combo:
        self.is_combo_requested = true
    if event.is_action_pressed("slide"):
        self.slide_request_timer.start()
    if event.is_action_pressed("interact") and not self.interacting_with.is_empty():
        self.interacting_with.back().interact()
    if event.is_action_pressed("pause"):
        self.pause_screen.show_pause()

func can_wall_slide() -> bool:
    return self.is_on_wall() and self.hand_checker.is_colliding() and self.foot_checker.is_colliding()

func should_slide() -> bool:
    if self.slide_request_timer.is_stopped():
        return false
    if self.stats.energy < SLIDING_ENERGY:
        return false
    return not self.foot_checker.is_colliding()

func get_next_state(state: State) -> int:
    if self.stats.health == 0:
        return StateMachine.KEEP_CURRENT if state == State.DYING else State.DYING
    if self.pending_damage:
        return State.HURT
    var can_jump: bool = self.is_on_floor() or coyote_timer.time_left > 0
    var should_jump: bool = can_jump and jump_request_timer.time_left > 0
    if should_jump:
        return State.JUMP
    if state in GROUND_STATES and not self.is_on_floor():
        return State.FALL
    var movement: float = Input.get_axis("move_left", "move_right")
    var is_still: bool = is_zero_approx(movement) and is_zero_approx(self.velocity.x)
    match state:
        State.IDLE:
            if Input.is_action_just_pressed("attack"):
                return State.ATTACK_1
            if self.should_slide():
                return State.SLIDING_START
            if not is_still:
                return State.RUNNING
        State.RUNNING:
            if Input.is_action_just_pressed("attack"):
                return State.ATTACK_1
            if self.should_slide():
                return State.SLIDING_START
            if is_still:
                return State.IDLE
        State.JUMP:
            if self.velocity.y >= 0:
                return State.FALL
        State.FALL:
            if self.is_on_floor():
                var height: float = self.global_position.y - self.fall_from_y
                return State.LANDING if height >= LANDING_HEIGHT else State.RUNNING
            if self.can_wall_slide():
                return State.WALL_SLIDING
        State.LANDING:
            if not self.animation_player.is_playing():
                return State.IDLE
        State.WALL_SLIDING:
            if self.jump_request_timer.time_left > 0:
                return State.WALL_JUMP
            if self.is_on_floor():
                return State.IDLE
            if not self.is_on_wall():
                return State.FALL
        State.WALL_JUMP:
            if self.can_wall_slide() and not self.is_first_tick:
                return State.WALL_SLIDING
            if self.velocity.y >= 0:
                return State.FALL
        State.ATTACK_1:
            if not self.animation_player.is_playing():
                return State.ATTACK_2 if self.is_combo_requested else State.IDLE
        State.ATTACK_2:
            if not self.animation_player.is_playing():
                return State.ATTACK_3 if self.is_combo_requested else State.IDLE
        State.ATTACK_3:
            if not self.animation_player.is_playing():
                return State.IDLE
        State.HURT:
            if not self.animation_player.is_playing():
                return State.IDLE
        State.SLIDING_START:
            if not self.animation_player.is_playing():
                return State.SLIDING_LOOP
        State.SLIDING_LOOP:
            if self.state_machine.state_time > SLIDING_DURATION or self.is_on_wall():
                return State.SLIDING_END
        State.SLIDING_END:
            if not self.animation_player.is_playing():
                return State.IDLE
    return StateMachine.KEEP_CURRENT

func transition_state(from: State, to: State) -> void:
    # print("[%s] %s => %s" % [
    #     Engine.get_physics_frames(),
    #     State.keys()[from] if from != -1 else "<Start>",
    #     State.keys()[to],
    # ])
    if from in GROUND_STATES and to in GROUND_STATES:
        self.coyote_timer.stop()
    match to:
        State.IDLE:
            self.animation_player.play("idle")
        State.RUNNING:
            self.animation_player.play("running")
        State.JUMP:
            self.animation_player.play("jump")
            self.velocity.y = JUMP_VELOCITY
            self.coyote_timer.stop()
            self.jump_request_timer.stop()
            SoundManager.play_sfx("Jump")
        State.FALL:
            self.animation_player.play("fall")
            if from in GROUND_STATES:
                self.coyote_timer.start()
            self.fall_from_y = self.global_position.y
        State.LANDING:
            self.animation_player.play("landing")
        State.WALL_SLIDING:
            self.animation_player.play("wall_sliding")
        State.WALL_JUMP:
            self.animation_player.play("jump")
            self.velocity = WALL_JUMP_VELOCITY
            self.velocity.x *= self.get_wall_normal().x
            jump_request_timer.stop()
        State.ATTACK_1:
            self.animation_player.play("attack_1")
            self.is_combo_requested = false
            SoundManager.play_sfx("Attack")
        State.ATTACK_2:
            self.animation_player.play("attack_2")
            self.is_combo_requested = false
        State.ATTACK_3:
            self.animation_player.play("attack_3")
            self.is_combo_requested = false
        State.HURT:
            self.animation_player.play("hurt")
            Input.start_joy_vibration(0, 0, 0.8, 0.8)
            Game.shake_camera(4.0)
            self.stats.health -= self.pending_damage.amount
            var dir: Vector2 = self.pending_damage.source.global_position.direction_to(self.global_position)
            self.velocity = dir * KNOCKBACK_AMOUNT
            self.pending_damage = null
            self.invincible_timer.start()
        State.DYING:
            self.animation_player.play("die")
            self.invincible_timer.stop()
            self.interacting_with.clear()
        State.SLIDING_START:
            self.animation_player.play("sliding_start")
            self.slide_request_timer.stop()
            self.stats.energy -= SLIDING_ENERGY
        State.SLIDING_LOOP:
            self.animation_player.play("sliding_loop")
        State.SLIDING_END:
            self.animation_player.play("sliding_end")
    self.is_first_tick = true

func _on_hurtbox_hurt(hitbox: Hitbox) -> void:
    if self.invincible_timer.time_left > 0:
        return
    self.pending_damage = Damage.new()
    self.pending_damage.amount = 1
    self.pending_damage.source = hitbox.owner

func _on_hitbox_hit(_hurtbox: Variant) -> void:
    Game.shake_camera(2.0)
    Engine.time_scale = 0.01
    await self.get_tree().create_timer(0.1, true, false, true).timeout
    Engine.time_scale = 1.0

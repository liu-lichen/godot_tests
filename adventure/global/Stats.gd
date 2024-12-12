class_name Stats
extends Node

@export var max_health: int = 3

@onready var health:int = max_health:
    set(v):
        health = clampi(v, 0, max_health)

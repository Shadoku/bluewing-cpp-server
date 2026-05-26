class_name SyncConfig
extends Resource

## Seconds between state transmissions when this peer is the owner.
@export_range(0.01, 2.0, 0.01, "suffix:s") var interval: float = 0.05

## Use reliable TCP instead of UDP blasting for state updates.
@export var reliable: bool = false

## Smoothly interpolate incoming state on non-owned copies of this node.
@export var interpolate: bool = true

## How far behind real-time the interpolation renderer sits (seconds).
@export_range(0.0, 1.0, 0.01, "suffix:s") var interp_delay: float = 0.1

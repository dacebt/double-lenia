---

# Particle Lenia (Godot)

A GPU-accelerated particle-based life simulation built in Godot 4, born from curiosity about cellular automata.

## How this happened

I was exploring Conway's Game of Life → fell into Lenia → and got stuck on a question:

*"Why does Lenia use a donut-shaped kernel?"*

The donut excludes the cell itself from its own field calculation. It felt like a leftover from Conway's "count your neighbors" logic. What if we just used a full Gaussian field instead? Something more like physics — fields that extend everywhere, no arbitrary holes.

Turns out this leads to **Particle Lenia**, a variant where discrete particles move through continuous space, each emitting overlapping fields. I didn't know this existed when I started asking the question — I arrived at it by poking at assumptions.

## What emerged

Without programming any specific behaviors:
- Particles self-organize into ring structures
- Multiple distinct "organisms" form and maintain separation
- Nested equilibrium shells appear naturally
- Clusters merge, split, and find stable configurations

## The math

Each particle emits a Gaussian field:
```
U(x) = Σ exp(-|x - pᵢ|² / 2r²) / N
```

Particles move toward regions where field density hits a "sweet spot":
```
G(u) = 2·exp(-(u - μ)² / 2σ²) - 1
```

Repulsion prevents collapse:
```
R = Σ (1 - d/min_dist)² · direction
```

## Built with

- **Godot 4.4** (Forward+ renderer)
- **GPU Compute Shaders** for parallel field calculation
- A conversation between me, Claude, and a coding agent

## What's next

This is Particle Lenia — similar to [Google Research's implementation](https://google-research.github.io/self-organising-systems/particle-lenia/). The next branch explores **wave interference**: giving particles phase values so fields can cancel, not just add. That's where this might become something new.

## Parameters

Tunable in the Godot inspector:
- `particle_count` — number of particles
- `kernel_radius` — field influence range
- `mu` / `sigma` — growth function sweet spot
- `gradient_strength` / `repulsion_strength` — force multipliers
- `time_scale` — simulation speed

## License

MIT

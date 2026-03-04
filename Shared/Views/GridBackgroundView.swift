import SwiftUI

/// Animated grid background with cyan particles that spawn from edges
/// and converge toward the center-bottom area below the title.
struct GridBackgroundView: View {
    private let cellSize: CGFloat = 40
    private let gridColor = Color(red: 51/255, green: 51/255, blue: 51/255).opacity(0.4)
    private let cyanColor = Color(red: 0, green: 1, blue: 1)

    @State private var sim = ParticleSimulation()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    let _ = now
                    sim.advance(size: size, cellSize: cellSize)
                    drawGrid(context: context, size: size)
                    drawParticles(context: context)
                }
            }
            .onAppear {
                sim.initialize(size: geo.size, cellSize: cellSize)
            }
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let cols = Int(size.width / cellSize) + 1
        let rows = Int(size.height / cellSize) + 1

        for col in 0...cols {
            let x = CGFloat(col) * cellSize
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }

        for row in 0...rows {
            let y = CGFloat(row) * cellSize
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    private func drawParticles(context: GraphicsContext) {
        for particle in sim.particles {
            let age = Double(particle.age) / 60.0
            let fadeIn = min(age / 0.3, 1.0)

            // Glowing head
            let headSize: CGFloat = 6
            let headRect = CGRect(
                x: particle.x - headSize / 2,
                y: particle.y - headSize / 2,
                width: headSize,
                height: headSize
            )
            let glowSize: CGFloat = 16
            let glowRect = CGRect(
                x: particle.x - glowSize / 2,
                y: particle.y - glowSize / 2,
                width: glowSize,
                height: glowSize
            )
            context.fill(
                Path(ellipseIn: glowRect),
                with: .color(cyanColor.opacity(0.15 * fadeIn))
            )
            context.fill(
                Path(ellipseIn: headRect),
                with: .color(cyanColor.opacity(fadeIn))
            )

            // Trail
            let count = particle.trail.count
            for (i, point) in particle.trail.enumerated() {
                let progress = Double(i) / Double(max(count - 1, 1))
                let opacity = progress * 0.5 * fadeIn
                let dotSize = 1.5 + progress * 2.5
                let rect = CGRect(
                    x: point.x - dotSize / 2,
                    y: point.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(cyanColor.opacity(opacity))
                )
            }
        }
    }
}

// MARK: - Particle simulation

private class ParticleSimulation {
    struct Particle {
        var x: CGFloat
        var y: CGFloat
        var dx: CGFloat
        var dy: CGFloat
        var trail: [CGPoint]
        var age: Int
    }

    private let trailLength = 40
    private let speed: CGFloat = 4
    private let maxParticles = 30
    private let convergeBias: Double = 0.7

    var particles: [Particle] = []
    private var frameCount = 0
    private var screenSize: CGSize = .zero
    private var targetX: CGFloat = 0
    private var targetY: CGFloat = 0

    func initialize(size: CGSize, cellSize: CGFloat) {
        screenSize = size
        // Target: the ZAM! title (centered, offset -140 from center)
        targetX = size.width / 2
        targetY = size.height / 2 - 140

        // Start with 3 particles from edges
        for _ in 0..<3 {
            particles.append(spawnFromEdge(cellSize: cellSize))
        }
    }

    func advance(size: CGSize, cellSize: CGFloat) {
        screenSize = size
        targetX = size.width / 2
        targetY = size.height / 2 - 140
        frameCount += 1

        // Spawn more particles over time, ramping up
        let spawnRate: Int
        if frameCount < 60 {
            spawnRate = 30       // one every 0.5s
        } else if frameCount < 180 {
            spawnRate = 15       // one every 0.25s
        } else {
            spawnRate = 8        // one every ~0.13s
        }

        if frameCount % spawnRate == 0 && particles.count < maxParticles {
            particles.append(spawnFromEdge(cellSize: cellSize))
        }

        // Remove particles that reached near the target
        particles.removeAll { p in
            let dx = p.x - targetX
            let dy = p.y - targetY
            return sqrt(dx * dx + dy * dy) < cellSize * 1.5 && p.age > 30
        }

        // Advance each particle
        for i in particles.indices {
            particles[i].x += particles[i].dx
            particles[i].y += particles[i].dy
            particles[i].age += 1

            // Despawn if off-screen (no wrapping — they come from edges)
            // But keep them alive if they're just passing through
            let margin: CGFloat = 20
            let outOfBounds =
                particles[i].x < -margin || particles[i].x > size.width + margin ||
                particles[i].y < -margin || particles[i].y > size.height + margin
            if outOfBounds {
                // Respawn from a different edge
                particles[i] = spawnFromEdge(cellSize: cellSize)
                continue
            }

            // Trail
            particles[i].trail.append(CGPoint(x: particles[i].x, y: particles[i].y))
            if particles[i].trail.count > trailLength {
                particles[i].trail.removeFirst(particles[i].trail.count - trailLength)
            }

            // Turn at intersections — biased toward target
            let nearCol = particles[i].x.remainder(dividingBy: cellSize)
            let nearRow = particles[i].y.remainder(dividingBy: cellSize)
            let atIntersection = abs(nearCol) < speed && abs(nearRow) < speed

            if atIntersection {
                // Snap to intersection
                particles[i].x = (particles[i].x / cellSize).rounded() * cellSize
                particles[i].y = (particles[i].y / cellSize).rounded() * cellSize

                let toTargetX = targetX - particles[i].x
                let toTargetY = targetY - particles[i].y

                if Double.random(in: 0...1) < convergeBias {
                    // Biased turn: pick axis that reduces distance to target most
                    let absX = abs(toTargetX)
                    let absY = abs(toTargetY)

                    if absX > absY {
                        // Go horizontal toward target
                        particles[i].dx = toTargetX > 0 ? speed : -speed
                        particles[i].dy = 0
                    } else {
                        // Go vertical toward target
                        particles[i].dx = 0
                        particles[i].dy = toTargetY > 0 ? speed : -speed
                    }
                } else {
                    // Random turn
                    if particles[i].dx != 0 {
                        let sign: CGFloat = Bool.random() ? 1 : -1
                        particles[i].dy = speed * sign
                        particles[i].dx = 0
                    } else {
                        let sign: CGFloat = Bool.random() ? 1 : -1
                        particles[i].dx = speed * sign
                        particles[i].dy = 0
                    }
                }
            }
        }
    }

    private func spawnFromEdge(cellSize: CGFloat) -> Particle {
        let edge = Int.random(in: 0...3) // 0=top, 1=bottom, 2=left, 3=right
        let cols = Int(screenSize.width / cellSize)
        let rows = Int(screenSize.height / cellSize)

        let x: CGFloat
        let y: CGFloat
        let dx: CGFloat
        let dy: CGFloat

        switch edge {
        case 0: // top
            x = CGFloat(Int.random(in: 0...cols)) * cellSize
            y = 0
            dx = 0
            dy = speed
        case 1: // bottom
            x = CGFloat(Int.random(in: 0...cols)) * cellSize
            y = CGFloat(rows) * cellSize
            dx = 0
            dy = -speed
        case 2: // left
            x = 0
            y = CGFloat(Int.random(in: 0...rows)) * cellSize
            dx = speed
            dy = 0
        default: // right
            x = CGFloat(cols) * cellSize
            y = CGFloat(Int.random(in: 0...rows)) * cellSize
            dx = -speed
            dy = 0
        }

        return Particle(x: x, y: y, dx: dx, dy: dy, trail: [], age: 0)
    }
}

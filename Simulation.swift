import Foundation

struct Motion {
    var x: Double = 0
    var z: Double = 0
    var heading: Double = 0
    var speed: Double = 0
}
struct FixedSimulation {
    let step = 1.0 / 60.0
    var previous = Motion()
    var current = Motion()
    var accumulator = 0.0
    var ticks = 0
    var driving = false
    mutating func advance(elapsed: Double, throttle: Double, steering: Double) {
        accumulator += min(max(elapsed, 0), 0.25)
        var iterations = 0
        while accumulator + 1e-12 >= step && iterations < 15 {
            previous = current
            let target = throttle * (driving ? 25.0 : 5.0)
            current.speed += (target - current.speed) * min(1, step * (driving ? 2.8 : 12))
            current.heading += steering * step * (driving ? min(abs(current.speed) / 5, 1.5) : 2.4)
            current.x += sin(current.heading) * current.speed * step
            current.z += cos(current.heading) * current.speed * step
            accumulator -= step
            ticks += 1
            iterations += 1
        }
    }
    var rendered: Motion {
        let alpha = min(max(accumulator / step, 0), 1)
        return Motion(x: previous.x + (current.x-previous.x)*alpha,
                      z: previous.z + (current.z-previous.z)*alpha,
                      heading: previous.heading + (current.heading-previous.heading)*alpha,
                      speed: current.speed)
    }
}

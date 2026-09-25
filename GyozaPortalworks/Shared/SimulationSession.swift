import Foundation
import Observation

/// Drives a simulated CPU in real time: one scan every 10 ms on the main
/// run loop (like a free-cycling S7-1200 or FX5U with a short program), with
/// the displayed state refreshed about 20 times a second.
@MainActor @Observable final class SimulationSession {
    static let scanInterval: TimeInterval = 0.010
    private static let scansPerRefresh = 5

    let cpu: any SimulatedCPU
    /// Changes whenever the display should refresh; monitors read it to redraw.
    private(set) var frame = 0
    private(set) var mode: CPUMode
    private(set) var isRunning = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let origin = ContinuousClock.now
    @ObservationIgnored private var scansSinceRefresh = 0

    init(cpu: any SimulatedCPU) {
        self.cpu = cpu
        self.mode = cpu.mode
    }

    /// Starts scanning. The CPU's clock keeps counting from power-on.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.scan()
            }
        }
        // .common keeps the CPU running while menus are open or views scroll.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
    }

    /// Powers the simulated CPU off: no more scans.
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        refresh()
    }

    func setMode(_ newMode: CPUMode) {
        cpu.setMode(newMode)
        refresh()
    }

    /// Makes a user action (a switch flipped, a value modified) show at once.
    func refresh() {
        scansSinceRefresh = 0
        mode = cpu.mode
        frame &+= 1
    }

    /// Milliseconds since power-on.
    var clock: Int64 {
        let elapsed = ContinuousClock.now - origin
        return elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    private func scan() {
        cpu.scan(clock: clock)
        scansSinceRefresh += 1
        if scansSinceRefresh >= Self.scansPerRefresh || cpu.mode != mode {
            refresh()
        }
    }
}

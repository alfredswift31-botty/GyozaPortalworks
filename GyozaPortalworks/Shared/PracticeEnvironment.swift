import Foundation

/// The two engineering tools the app mirrors.
nonisolated enum PracticeEnvironment: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case tiaPortal
    case gxWorks3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiaPortal: return "TIA Portal"
        case .gxWorks3: return "GX Works3"
        }
    }

    var vendor: String {
        switch self {
        case .tiaPortal: return "Siemens"
        case .gxWorks3: return "Mitsubishi Electric"
        }
    }

    var controller: String {
        switch self {
        case .tiaPortal: return "S7-1200 · CPU 1214C DC/DC/DC"
        case .gxWorks3: return "MELSEC iQ-F · FX5U-32MR/ES"
        }
    }

    var dialect: LanguageDialect {
        switch self {
        case .tiaPortal: return .siemens
        case .gxWorks3: return .melsec
        }
    }

    var simulatorName: String {
        switch self {
        case .tiaPortal: return "S7-PLCSIM"
        case .gxWorks3: return "GX Simulator3"
        }
    }

    /// Where the real tool starts its simulator.
    var startSimulationHint: String {
        switch self {
        case .tiaPortal: return "Online › Simulation › Start (Ctrl+Shift+X)"
        case .gxWorks3: return "Debug › Simulation › Start Simulation"
        }
    }
}

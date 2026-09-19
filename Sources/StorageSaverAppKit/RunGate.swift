import Foundation
import StorageSaverCore

/// Why an automatic run did not happen, in the order the gate checks them.
public enum SkipReason: String, Codable, Equatable {
    case storeUnavailable
    case configUnreadable
    case policyInvalid
    case automaticOff
    case busy
    case problemUnacknowledged
    case danglingRun
    case noPriorAppRun
    case keepMessagesSet
    case prerequisites
    case messagesRunning
    case tooSoonAfterLaunch
    case tooSoonAfterSettingsChange
    case ranRecently

    public var explanation: String {
        switch self {
        case .storeUnavailable: return "the Messages store is not readable"
        case .configUnreadable: return "the settings file is unreadable"
        case .policyInvalid: return "the settings are out of range"
        case .automaticOff: return "automatic runs are off"
        case .busy: return "another run or preview is in progress"
        case .problemUnacknowledged: return "a problem run has not been acknowledged (see Health)"
        case .danglingRun: return "a previous run did not finish (see Health)"
        case .noPriorAppRun: return "no manual run has completed yet"
        case .keepMessagesSet: return "Messages › Settings › Keep messages is not set to Forever"
        case .prerequisites: return "a prerequisite is not met (see Health)"
        case .messagesRunning: return "waiting for Messages to quit"
        case .tooSoonAfterLaunch: return "the app just started"
        case .tooSoonAfterSettingsChange: return "settings were just changed"
        case .ranRecently: return "an automatic run finished recently"
        }
    }
}

public enum AutoRunDecision: Equatable {
    case run
    case skip(SkipReason)
}

public struct RunGateInputs: Equatable {
    public var storeReady = true
    public var configUnreadable = false
    public var policyValid = true
    public var automaticRuns = false
    public var busy = false
    public var unacknowledgedProblem = false
    public var danglingRun = false
    public var hasPriorAppRun = false
    public var keepMessagesSet = false
    public var prerequisiteBlockers: [String] = []
    public var messagesRunning = false
    public var onlyWhileMessagesClosed = false
    public var launchedAt: Date
    public var lastSettingsChange: Date?
    public var lastAutomaticRunEnded: Date?
    public var now: Date

    public init(launchedAt: Date, now: Date) { self.launchedAt = launchedAt; self.now = now }
}

/// The pure decision behind every automatic run. Ordered so the first
/// reason shown is the one the user can act on.
public enum RunGate {
    public static let minimumTimeAfterLaunch: TimeInterval = 10 * 60
    public static let minimumTimeAfterSettingsChange: TimeInterval = 15 * 60
    public static let minimumTimeBetweenAutomaticRuns: TimeInterval = 5 * 3600

    public static func decide(_ i: RunGateInputs) -> AutoRunDecision {
        if !i.storeReady { return .skip(.storeUnavailable) }
        if i.configUnreadable { return .skip(.configUnreadable) }
        if !i.policyValid { return .skip(.policyInvalid) }
        if !i.automaticRuns { return .skip(.automaticOff) }
        if i.busy { return .skip(.busy) }
        if i.unacknowledgedProblem { return .skip(.problemUnacknowledged) }
        if i.danglingRun { return .skip(.danglingRun) }
        if !i.hasPriorAppRun { return .skip(.noPriorAppRun) }
        if i.keepMessagesSet { return .skip(.keepMessagesSet) }
        if !i.prerequisiteBlockers.isEmpty { return .skip(.prerequisites) }
        if i.onlyWhileMessagesClosed && i.messagesRunning { return .skip(.messagesRunning) }
        if i.now.timeIntervalSince(i.launchedAt) < minimumTimeAfterLaunch { return .skip(.tooSoonAfterLaunch) }
        if let c = i.lastSettingsChange, i.now.timeIntervalSince(c) < minimumTimeAfterSettingsChange { return .skip(.tooSoonAfterSettingsChange) }
        if let e = i.lastAutomaticRunEnded, i.now.timeIntervalSince(e) < minimumTimeBetweenAutomaticRuns { return .skip(.ranRecently) }
        return .run
    }
}

import Foundation

public struct CLIOptions {
    public var help = false
    public var version = false
    public var devices = false
    public var deviceID: String?
    public var tail: Int?
    public var follow = true
    public var matches: [String] = []
    public var excludes: [String] = []
    public var matchAll = false
    public var ignoreCase = false
    public var timestamps = true
    public var json = false
    public var exitOnDisconnect = false

    public init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw CLIError("Missing value for \(flag)") }
                return arguments[index]
            }
            switch flag {
            case "-h", "--help": help = true
            case "-v", "--version": version = true
            case "--devices": devices = true
            case "--device": deviceID = try value()
            case "--tail":
                guard let count = Int(try value()), count >= 0 else { throw CLIError("--tail requires a nonnegative integer") }
                tail = count
            case "-f", "--follow": follow = true
            case "--no-follow": follow = false
            case "-m", "--match": matches.append(try value())
            case "-M", "--unmatch": excludes.append(try value())
            case "--match-all": matchAll = true
            case "-i", "--ignore-case": ignoreCase = true
            case "--no-timestamps": timestamps = false
            case "--json": json = true
            case "-x", "--exit-on-disconnect": exitOnDisconnect = true
            default: throw CLIError("Unknown option: \(flag). Use --help for usage.")
            }
            index += 1
        }
        if !follow && tail == nil { tail = 100 }
        if matchAll && matches.isEmpty { throw CLIError("--match-all requires at least one --match") }
        if json && !timestamps { throw CLIError("--no-timestamps applies to text output, not --json") }
    }

    public func includes(_ text: String) -> Bool {
        func contains(_ term: String) -> Bool {
            text.range(of: term, options: ignoreCase ? [.caseInsensitive, .literal] : [.literal]) != nil
        }
        if excludes.contains(where: contains) { return false }
        return matches.isEmpty || (matchAll ? matches.allSatisfy(contains) : matches.contains(where: contains))
    }
}

public struct CLIError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

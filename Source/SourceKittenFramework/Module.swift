import Foundation
import Yams

/// Represents source module to be documented.
public struct Module {
    /// Module Name.
    public let name: String
    /// Compiler arguments required by SourceKit to process the source files in this Module.
    public let compilerArguments: [String]
    /// Source files to be documented in this Module.
    public let sourceFiles: [String]

    public static let results: Exec.Results? = nil

    /// Documentation for this Module. Typically expensive computed property.
    public var docs: [SwiftDocs] {
        var fileIndex = 1
        let sourceFilesCount = sourceFiles.count
        return sourceFiles.sorted().compactMap {
            let filename = $0.bridge().lastPathComponent
            if let file = File(path: $0) {
                fputs("Parsing \(filename) (\(fileIndex)/\(sourceFilesCount))\n", stderr)
                fileIndex += 1
                return SwiftDocs(file: file, arguments: compilerArguments)
            }
            fputs("Could not parse `\(filename)`. Please open an issue at https://github.com/jpsim/SourceKitten/issues with the file contents.\n", stderr)
            return nil
        }
    }

    /**
     Failable initializer to create a Module from a Swift Package Manager build record.

     Use this initializer when the package has already been built and the `.build` directory exists.

     - parameter spmName: Module name.  Will use some non-Test module that is part of the
                          package if `nil`.
     - parameter path:    Path of the directory containing the SPM `.build` directory.
                          Uses the current directory by default.
     */
    public init?(spmName: String? = nil, inPath path: String = FileManager.default.currentDirectoryPath) {
        let yamlPath = URL(fileURLWithPath: path).appendingPathComponent(".build/debug.yaml").path
        guard let yaml = try? Yams.compose(yaml: String(contentsOfFile: yamlPath, encoding: .utf8)),
            let commands = (yaml as Node?)?["commands"]?.mapping?.values else {
            fputs("SPM build manifest does not exist at `\(yamlPath)` or does not match expected format.\n", stderr)
            return nil
        }

        func matchModuleName(node: Node) -> Bool {
            guard let nodeModuleName = node.swiftModuleName else { return false }
            if let spmName = spmName {
                return nodeModuleName == spmName
            }
            let inputs = node["inputs"]?.array(of: String.self) ?? []
            return inputs.allSatisfy({ !$0.contains(".build/checkouts/") }) && !nodeModuleName.hasSuffix("Tests")
        }

        guard let moduleCommand = commands.first(where: matchModuleName) else {
            fputs("Could not find SPM module '\(spmName ?? "(any)")'. Here are the modules available:\n", stderr)
            let availableModules = commands.compactMap(\.swiftModuleName)
            fputs("\(availableModules.map({ "  - " + $0 }).joined(separator: "\n"))\n", stderr)
            return nil
        }

        guard let moduleName = moduleCommand.swiftModuleName,
              let compilerArguments = moduleCommand.swiftCompilerArguments else {
            fputs("SPM build manifest '\(yamlPath)` does not match expected format.\n", stderr)
            return nil
        }

        self.init(name: moduleName, compilerArguments: compilerArguments)
    }

    /**
     Failable initializer to create a Module by building a Swift Package Manager project.

     Use this initializer if the package has not been built or may have changed since last built.

     - parameter spmArguments: Additional arguments to pass to `swift build`
     - parameter spmName: Module name.  Will use some non-Test module that is part of the
                          package if `nil`.
     - parameter path:    Path of the directory containing the `Package.swift` file.
                          Uses the current directory by default.
     */
    public init?(spmArguments: [String], spmName: String? = nil, inPath path: String = FileManager.default.currentDirectoryPath) {
        fputs("Running swift build\n", stderr)
        let buildResults = Exec.run("/usr/bin/env", ["swift", "build"] + spmArguments, currentDirectory: path, stderr: .merge)
        guard buildResults.terminationStatus == 0 else {
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swift-build-\(UUID().uuidString).log")
            _ = try? buildResults.data.write(to: file)
            fputs("Build failed, saved `swift build` log file: \(file.path)\n", stderr)
            return nil
        }

        self.init(spmName: spmName, inPath: path)
    }

    /**
    Failable initializer to create a Module by the arguments necessary pass in to `xcodebuild` to build it.
    Optionally pass in a `moduleName` and `path`.

    - parameter xcodeBuildArguments: The arguments necessary pass in to `xcodebuild` to build this Module.
    - parameter name:                Module name. Will be parsed from `xcodebuild` output if nil.
    - parameter path:                Path to run `xcodebuild` from. Uses current path by default.
    */
    public init?(xcodeBuildArguments: [String], name: String? = nil, inPath path: String = FileManager.default.currentDirectoryPath) {
        let buildSettings = XcodeBuild.showBuildSettings(arguments: xcodeBuildArguments, inPath: path)

        let name = name
            // Check for user-defined "SWIFT_MODULE_NAME", otherwise use "PRODUCT_MODULE_NAME".
            ?? buildSettings?.firstBuildSettingValue { $0.SWIFT_MODULE_NAME ?? $0.PRODUCT_MODULE_NAME }
            ?? moduleName(fromArguments: xcodeBuildArguments)

        // Executing normal build
        fputs("文秋 \(results)", stdout)
        if Self.results == nil {
            Self.results = XcodeBuild.build(arguments: xcodeBuildArguments, inPath: path)
        }
        if Self.results.terminationStatus != 0 {
            fputs("Could not successfully run `xcodebuild`.\n", stderr)
            fputs("Please check the build arguments.\n", stderr)
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcodebuild-\(NSUUID().uuidString).log")
            _ = try? Self.results.data.write(to: file)
            fputs("Saved `xcodebuild` log file: \(file.path)\n", stderr)
            return nil
        }
        if let output = Self.results.string,
            let arguments = parseCompilerArguments(xcodebuildOutput: output, language: .swift, moduleName: name),
            let moduleName = moduleName(fromArguments: arguments) {
            self.init(name: moduleName, compilerArguments: arguments)
            return
        }
        // Check New Build System is used
        fputs("Checking xcodebuild -showBuildSettings\n", stderr)
        if let projectTempRoot = buildSettings?.firstBuildSettingValue(for: { $0.PROJECT_TEMP_ROOT }),
            let arguments = checkNewBuildSystem(in: projectTempRoot, moduleName: name),
            let moduleName = moduleName(fromArguments: arguments) {
            self.init(name: moduleName, compilerArguments: arguments)
            return
        }
        // Executing `clean build` is a fallback.
        let xcodeBuildOutput = XcodeBuild.cleanBuild(arguments: xcodeBuildArguments, inPath: path).string ?? ""
        guard let arguments = parseCompilerArguments(xcodebuildOutput: xcodeBuildOutput, language: .swift, moduleName: name) else {
            fputs("Could not parse compiler arguments from `xcodebuild` output.\n", stderr)
            fputs("Please confirm that `xcodebuild` is building a Swift module.\n", stderr)
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcodebuild-\(NSUUID().uuidString).log")
            _ = try? xcodeBuildOutput.data(using: .utf8)?.write(to: file)
            fputs("Saved `xcodebuild` log file: \(file.path)\n", stderr)
            return nil
        }
        guard let moduleName = moduleName(fromArguments: arguments) else {
            fputs("Could not parse module name from compiler arguments.\n", stderr)
            return nil
        }
        self.init(name: moduleName, compilerArguments: arguments)
    }

    /**
    Initializer to create a Module by name and compiler arguments.

    - parameter name:              Module name.
    - parameter compilerArguments: Compiler arguments required by SourceKit to process the source files in this Module.
    */
    public init(name: String, compilerArguments: [String]) {
        self.name = name
        self.compilerArguments = compilerArguments.expandingResponseFiles
        sourceFiles = self.compilerArguments.filter({
            $0.bridge().isSwiftFile() && $0.isFile
        }).map {
            return URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    }
}

// MARK: CustomStringConvertible

extension Module: CustomStringConvertible {
    /// A textual representation of `Module`.
    public var description: String {
        return "Module(name: \(name), compilerArguments: \(compilerArguments), sourceFiles: \(sourceFiles))"
    }
}

// MARK: XcodeBuildSetting Conveniences

private extension Collection where Element == XcodeBuildSetting {
    /// Iterates through the `XcodeBuildSetting`s and returns the first value returned by the getter closure.
    ///
    /// For example, if we want the value of the first `XcodeBuildSetting` with a `"PROJECT_TEMP_ROOT"` value:
    ///
    ///     let buildSettings: [XcodeBuildSetting] = ...
    ///     let projectTempRoot = buildSettings.firstBuildSettingValue { $0.projectTempRoot }
    ///
    /// - Parameter getterClosure: A closure that returns a dynamic member.
    /// - Returns: The first value returned by the getter closure.
    func firstBuildSettingValue(for getterClosure: (XcodeBuildSetting) -> String?) -> String? {
        return lazy.compactMap(getterClosure).first
    }
}

// MARK: Yams.Node helpers for SwiftPM

// The yaml structure changed in Xcode 15.3 / SwiftPM 5.10.  This extension decodes both formats.
private extension Node {
    // SwiftPM < 5.10: 'module-name' string
    // SwiftPM   5.10: buried inside compiler args
    var swiftModuleName: String? {
        if let moduleNameNode = self["module-name"] {
            return moduleNameNode.string
        }
        if let description = self["description"]?.string,
           description.hasPrefix("Compiling Swift Module"),
           let arguments = self["args"]?.array(of: String.self) {
            return moduleName(fromArguments: arguments)
        }
        return nil
    }

    // SwiftPM < 5.10: 'sources' array of Swift files
    // SwiftPM   5.10: 'inputs' array of various things including Swift files
    var swiftSources: [String]? {
        (self["sources"] ?? self["inputs"])?
            .array(of: String.self)
            .filter { $0.isSwiftFile() }
    }

    // SwiftPM < 5.10: 'other-args' and 'import-paths' arrays
    // SwiftPM   5.10: 'args' is the entire command line that needs filtering
    //   for SourceKit.  Additionally it contains a response file that may or
    //   may not contain the list of source files - guessing a window in the
    //   way we use this unofficial interface to SwiftPM.  Use the separate
    //   'inputs' node, but we must remove the response file in case it *does*
    //   contain the files which would cause duplicate file processing...
    var swiftOtherCompilerArguments: [String]? {
        if let buildCommandArguments = self["args"]?
            .array(of: String.self)
            .filter({ !$0.hasPrefix("@") }) {
            // Drop the initial "/usr/bin/swiftc"
            return filterForSourceKit(arguments: Array(buildCommandArguments.dropFirst()))
        }

        guard let imports = self["import-paths"]?.array(of: String.self),
              let otherArguments = self["other-args"]?.array(of: String.self),
              let moduleName = swiftModuleName else {
            return nil
        }

        var arguments = ["-module-name", moduleName]
        arguments.append(contentsOf: otherArguments)
        arguments.append(contentsOf: ["-I"])
        arguments.append(contentsOf: imports)
        return arguments
    }

    var swiftCompilerArguments: [String]? {
        guard let sources = swiftSources,
              let otherCompilerArguments = swiftOtherCompilerArguments else {
            return nil
        }

        return sources + otherCompilerArguments
    }
}

import XCTest

/// The Xcode project is the only thing that builds this app. There is no
/// package globbing a `Sources` directory as there is on the Mac side: every
/// file is listed by hand in `project.pbxproj`, which is also how files get
/// added here. Three ways that list goes wrong:
///
/// * the same file listed twice. Xcode is of two minds about this. It skips
///   the second copy with a "Skipping duplicate build file" warning and builds
///   happily, which is how `DevotionalView.swift` stayed duplicated for
///   months; and it also refuses the same project outright with "Multiple
///   commands produce … DevotionalView.stringsdata", which is a bewildering
///   thing to meet in a project nobody knowingly broke;
/// * a file on disk that no target compiles. Nothing reports this at all: an
///   unreferenced view is simply absent from the app, and a test file nobody
///   registered passes forever by never running;
/// * a listed file that is no longer on disk. Xcode does stop for this one,
///   so all that is added here is saying which file and which target.
final class XcodeProjectSourcesTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The directories each hand-maintained target owns, and what it compiles
    /// from outside them. `Shared` belongs to the app and the widget both, so
    /// it is named rather than walked.
    private static let handMaintained: [(name: String, directories: [String], shared: Set<String>)] = [
        ("Lamp Bible", ["Lamp Bible"], ["WidgetSharedModels.swift"]),
        ("Lamp BibleTests", ["Lamp BibleTests"], []),
        ("Lamp BibleUITests", ["Lamp BibleUITests"], []),
    ]

    // MARK: - The guards

    func testNoTargetCompilesTheSameFileTwice() throws {
        let project = try projectFile()
        for (target, files) in try compiledFiles(in: project) {
            var seen: Set<String> = []
            let twice = files.filter { !seen.insert($0).inserted }.sorted()
            XCTAssertEqual(
                twice, [],
                """
                \(target) lists these files in Compile Sources more than once. \
                Delete the spare PBXBuildFile and PBXFileReference.
                """
            )
        }
    }

    func testEveryTargetCompilesEveryFileInItsOwnDirectories() throws {
        let compiled = try compiledFiles(in: try projectFile())
        for target in Self.handMaintained {
            let listed = Set(try XCTUnwrap(compiled[target.name], "\(target.name) has no Compile Sources phase"))
            var onDisk = target.shared
            for directory in target.directories {
                onDisk.formUnion(try swiftFileNames(under: directory))
            }
            XCTAssertEqual(
                onDisk.subtracting(listed).sorted(), [],
                "add these to the \(target.name) target in Xcode — nothing is compiling them"
            )
            XCTAssertEqual(
                listed.subtracting(onDisk).sorted(), [],
                "\(target.name) lists these but they are not on disk"
            )
        }
    }

    /// The widget is left out of the reconciliation above because Xcode keeps
    /// its group in sync with the folder itself, so there is no hand-written
    /// list to drift. If another target is ever converted the same way, it
    /// belongs here and not in `handMaintained`.
    func testOnlyTheWidgetIsKeptInSyncByXcode() throws {
        XCTAssertEqual(try synchronizedTargets(in: try projectFile()), ["LampBibleWidgetExtension"])
    }

    /// The guards above pass trivially against a project they failed to read,
    /// so this is the one test that fails when the parsing breaks rather than
    /// when the project does.
    func testTheProjectAndTheWorkingTreeBothParse() throws {
        let compiled = try compiledFiles(in: try projectFile())
        XCTAssertGreaterThan(try XCTUnwrap(compiled["Lamp Bible"]).count, 50)
        XCTAssertGreaterThan(try swiftFileNames(under: "Lamp Bible").count, 50)
        XCTAssertEqual(Set(compiled.keys), [
            "Lamp Bible", "Lamp BibleTests", "Lamp BibleUITests", "LampBibleWidgetExtension",
        ])
    }

    // MARK: - Reading the project

    private func projectFile() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Lamp Bible.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
    }

    /// Target name to the names of the files its Compile Sources phase names,
    /// in the order they are listed and with repeats kept.
    private func compiledFiles(in project: String) throws -> [String: [String]] {
        let fileName = try fileNameOfBuildFile(in: project)
        var phases: [String: [String]] = [:]
        for phase in try capture(
            #"([0-9A-Fa-f]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)\n\t\t\};"#,
            in: project, acrossLines: true
        ) {
            phases[phase[1]] = try capture(#"([0-9A-Fa-f]{24}) /\* [^*]*? in Sources \*/"#, in: phase[2])
                .compactMap { fileName[$0[1]] }
        }

        var compiled: [String: [String]] = [:]
        for target in try nativeTargets(in: project) {
            guard let phase = try capture(#"([0-9A-Fa-f]{24}) /\* Sources \*/"#, in: target.body).first else { continue }
            compiled[target.name] = phases[phase[1]]
        }
        return compiled
    }

    /// Resolved through the file reference rather than read out of the
    /// `/* … */` comment beside it: that comment is Xcode's, and a project
    /// edited by hand is exactly where it goes stale.
    private func fileNameOfBuildFile(in project: String) throws -> [String: String] {
        var pathOfReference: [String: String] = [:]
        for reference in try capture(
            #"([0-9A-Fa-f]{24}) /\* [^*]* \*/ = \{isa = PBXFileReference;[^\n]*? path = "?([^";\n]+)"?;"#,
            in: project
        ) {
            pathOfReference[reference[1]] = (reference[2] as NSString).lastPathComponent
        }
        var names: [String: String] = [:]
        for buildFile in try capture(
            #"([0-9A-Fa-f]{24}) /\* [^*]* \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-Fa-f]{24})"#,
            in: project
        ) {
            names[buildFile[1]] = pathOfReference[buildFile[2]]
        }
        return names
    }

    private func nativeTargets(in project: String) throws -> [(name: String, body: String)] {
        try capture(
            #"[0-9A-Fa-f]{24} /\* [^*]* \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};"#,
            in: project, acrossLines: true
        ).compactMap { target in
            guard let name = try? capture(#"\n\t\t\tname = "?([^";\n]+)"?;"#, in: target[1]).first?[1] else { return nil }
            return (name, target[1])
        }
    }

    private func synchronizedTargets(in project: String) throws -> Set<String> {
        Set(try nativeTargets(in: project)
            .filter { $0.body.contains("fileSystemSynchronizedGroups") }
            .map(\.name))
    }

    private func swiftFileNames(under directory: String) throws -> Set<String> {
        let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var names: Set<String> = []
        while let file = walker?.nextObject() as? URL {
            if file.pathExtension == "swift" { names.insert(file.lastPathComponent) }
        }
        XCTAssertFalse(names.isEmpty, "found no Swift files under \(directory) — is the path still right?")
        return names
    }

    private func capture(_ pattern: String, in text: String, acrossLines: Bool = false) throws -> [[String]] {
        let expression = try NSRegularExpression(
            pattern: pattern, options: acrossLines ? [.dotMatchesLineSeparators] : []
        )
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

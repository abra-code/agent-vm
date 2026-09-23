// Sources/AgentVMKit/Sessions/RiskRules.swift
//
// Which changed paths deserve a human's attention before the project is used again on the
// host. An agent contained in a box can still leave files that run later, unboxed: git hooks
// and config, build scripts, package install scripts, editor tasks, and - most likely of all -
// the configuration of the agents themselves (`.mcp.json`, `.claude/`, `AGENTS.md`), which the
// next unboxed agent run would load. These flags are a review aid, not a security boundary.

import Foundation

public struct RiskFlag: Codable, Equatable, Hashable, Sendable {
    public enum Severity: String, Codable, Comparable, Sendable {
        case info, medium, high

        private var rank: Int {
            switch self {
            case .info: return 0
            case .medium: return 1
            case .high: return 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            return lhs.rank < rhs.rank
        }
    }

    /// Stable identifier of the rule, for programs.
    public let rule: String
    public let severity: Severity
    /// One sentence for the person reviewing the change.
    public let reason: String
}

/// Matches a path relative to the project root (components separated by "/").
enum PathMatcher: Sendable {
    /// Exactly this relative path.
    case path(String)
    /// This folder and everything inside it.
    case folder(String)
    /// The last component equals this name, at any depth.
    case name(String)
    /// The last component ends with this suffix, at any depth.
    case suffix(String)
    /// Any component (a folder or the entry itself) equals this name, at any depth.
    case component(String)
    /// Inside a git folder at any depth (the project's `.git`, a submodule's
    /// `.git/modules/<name>`, a nested repository's `<folder>/.git`): a component after the
    /// `.git` component equals this name.
    case insideGit(String)
    /// Inside a git folder at any depth, the last component equals this name.
    case gitFile(String)

    func matches(_ relative: String, components: [Substring]) -> Bool {
        switch self {
        case let .path(path):
            return relative == path
        case let .folder(folder):
            return RelativePath.isWithin(relative, folder)
        case let .name(name):
            return components.last.map { $0 == name } ?? false
        case let .suffix(suffix):
            return components.last.map { $0.hasSuffix(suffix) } ?? false
        case let .component(name):
            return components.contains { $0 == name }
        case let .insideGit(name):
            guard let git = components.firstIndex(of: ".git") else {
                return false
            }
            return components[(git + 1)...].contains { $0 == name }
        case let .gitFile(name):
            return components.count > 1 && components.last == Substring(name) && components.dropLast().contains(".git")
        }
    }
}

struct PathRule: Sendable {
    let id: String
    let severity: RiskFlag.Severity
    let reason: String
    let matchers: [PathMatcher]
}

public enum RiskRules {
    /// Path-based rules, most specific first. Every matching rule contributes a flag.
    static let pathRules: [PathRule] = [
        // Runs automatically on the next git operation on the host.
        PathRule(id: "git-hook", severity: .high,
                 reason: "git hook: runs automatically on the next git operation",
                 matchers: [.insideGit("hooks"), .folder(".husky")]),
        PathRule(id: "git-config", severity: .high,
                 reason: "git configuration can run programs (core.hooksPath, core.fsmonitor, core.sshCommand, core.pager, diff.external, filter drivers)",
                 matchers: [.gitFile("config"), .gitFile("config.worktree"), .gitFile("attributes"), .name(".gitattributes"),
                            .name(".gitmodules")]),
        PathRule(id: "git-dir", severity: .high,
                 reason: "git folder or gitfile added or replaced: git commands run inside it (shell prompts included) use its hooks and configuration",
                 matchers: [.name(".git")]),

        // The agents' own configuration: loaded by the next agent run, boxed or not.
        PathRule(id: "agent-config", severity: .high,
                 reason: "AI agent configuration: the next agent run loads it (MCP servers, hooks, commands, permissions)",
                 matchers: [.name(".mcp.json"), .component(".claude"), .component(".codex"), .name("opencode.json"),
                            .component(".opencode"), .component(".cursor"), .component(".gemini"), .component(".windsurf"),
                            .name(".cursorrules")]),
        PathRule(id: "agent-instructions", severity: .high,
                 reason: "instructions read by AI agents: text here steers every future agent run",
                 matchers: [.name("CLAUDE.md"), .name("AGENTS.md"), .name("GEMINI.md"), .name(".clinerules")]),

        // Runs in CI or when the folder is opened.
        PathRule(id: "ci-workflow", severity: .high,
                 reason: "CI workflow: runs with repository secrets on the next push",
                 matchers: [.folder(".github/workflows"), .folder(".github/actions"), .name(".gitlab-ci.yml"),
                            .folder(".circleci"), .name("Jenkinsfile")]),
        PathRule(id: "auto-run-on-open", severity: .high,
                 reason: "runs or configures commands when the folder is opened or entered (direnv, mise, dev containers, editor tasks)",
                 matchers: [.name(".envrc"), .name("mise.toml"), .name(".mise.toml"), .folder(".devcontainer"),
                            .path(".vscode/tasks.json"), .path(".vscode/settings.json"), .path(".vscode/launch.json"),
                            .name(".pre-commit-config.yaml")]),
        PathRule(id: "interpreter-auto-load", severity: .high,
                 reason: "loaded automatically by Python or pytest when they start in this folder",
                 matchers: [.name("sitecustomize.py"), .name("usercustomize.py"), .suffix(".pth"), .name("conftest.py")]),
        PathRule(id: "launch-item", severity: .high,
                 reason: "launchd or login item: starts programs automatically if installed",
                 matchers: [.component("LaunchAgents"), .component("LaunchDaemons")]),

        // Runs when the project is built or its dependencies are installed.
        PathRule(id: "build-script", severity: .medium,
                 reason: "build or task definition: runs when the project is built",
                 matchers: [.name("Makefile"), .name("GNUmakefile"), .suffix(".mk"), .name("CMakeLists.txt"), .suffix(".cmake"),
                            .name("configure"), .name("build.rs"), .name("Justfile"), .name("justfile"), .name("Taskfile.yml"),
                            .name("Rakefile"), .name("meson.build"), .name("BUILD"), .name("BUILD.bazel"), .name("WORKSPACE"),
                            .name("build.gradle"), .name("build.gradle.kts"), .name("settings.gradle"),
                            .name("settings.gradle.kts"), .name("gradle-wrapper.properties"), .name("pom.xml")]),
        PathRule(id: "package-manifest", severity: .medium,
                 reason: "package manifest or package-manager configuration: install scripts and sources run or load on install",
                 matchers: [.name("package.json"), .name(".npmrc"), .name(".yarnrc"), .name(".yarnrc.yml"), .name("pnpm-workspace.yaml"),
                            .name("setup.py"), .name("setup.cfg"), .name("pyproject.toml"), .name("Podfile"), .name("Package.swift"),
                            .name("Cargo.toml"), .folder(".cargo"), .name("Gemfile"), .name("go.mod"), .name("pip.conf"),
                            .name(".pnpmfile.cjs"), .name(".env")]),
        PathRule(id: "xcode-project", severity: .medium,
                 reason: "Xcode project, scheme or build settings: build phases and scheme actions run shell scripts",
                 matchers: [.suffix(".pbxproj"), .suffix(".xcscheme"), .suffix(".xcconfig"), .suffix(".xctestplan")]),
        PathRule(id: "editor-config", severity: .medium,
                 reason: "editor or IDE configuration: can define tasks, run configurations and extensions",
                 matchers: [.folder(".vscode"), .folder(".idea"), .folder(".zed"), .folder(".fleet")]),
        PathRule(id: "double-click-runnable", severity: .medium,
                 reason: "runs when double-clicked in Finder",
                 matchers: [.suffix(".command"), .suffix(".tool"), .suffix(".app"), .suffix(".workflow"), .suffix(".terminal"),
                            .suffix(".scpt"), .suffix(".applescript")]),
    ]

    /// Flags for one changed entry. `kind` and the modes describe the change; `symlinkTarget` is
    /// the new target when the entry is (now) a symlink.
    static func flags(for relative: String,
                      kind: ChangeKind,
                      type: EntryType,
                      mode: UInt16?,
                      previousMode: UInt16?,
                      symlinkTarget: String?,
                      linkCount: UInt16?) -> [RiskFlag] {
        let components = RelativePath.components(relative)
        var result: [RiskFlag] = []

        for rule in pathRules where rule.matchers.contains(where: { $0.matches(relative, components: components) }) {
            // Git's own sample hooks are inert.
            if rule.id == "git-hook" && relative.hasSuffix(".sample") {
                continue
            }
            result.append(RiskFlag(rule: rule.id, severity: rule.severity, reason: rule.reason))
        }

        if kind != .deleted {
            if type == .symlink, let target = symlinkTarget {
                if escapesProject(link: relative, target: target) {
                    result.append(RiskFlag(rule: "symlink-escape", severity: .high,
                                           reason: "symlink pointing outside the project (\(target)): host tools that follow it read or write elsewhere"))
                } else {
                    result.append(RiskFlag(rule: "symlink", severity: .medium,
                                           reason: "symlink inside the project (\(target))"))
                }
            }
            if type == .file, let mode {
                let executable = mode & 0o111 != 0
                let wasExecutable = (previousMode ?? 0) & 0o111 != 0
                if mode & 0o6000 != 0 {
                    result.append(RiskFlag(rule: "setuid", severity: .high,
                                           reason: "setuid or setgid bit set"))
                }
                if executable && (kind == .added || !wasExecutable || kind == .modified || kind == .typeChanged) {
                    result.append(RiskFlag(rule: "executable", severity: .medium,
                                           reason: "executable file added or changed: files written by the agent carry no quarantine attribute, so Gatekeeper will not check them"))
                }
            }
            if type == .file, kind == .added, let linkCount, linkCount > 1 {
                result.append(RiskFlag(rule: "hard-link", severity: .medium,
                                       reason: "new hard link: the same file is reachable under another name"))
            }
        }

        // Every change to a dotfile or dot-folder that no specific rule covered: these are
        // where tools keep configuration that runs code.
        if result.isEmpty, components.contains(where: { $0.hasPrefix(".") && $0 != ".git" }) {
            result.append(RiskFlag(rule: "dotfile", severity: .info,
                                   reason: "hidden configuration file or folder changed"))
        }
        return result
    }

    /// True when a symlink at `link` (relative to the project) with `target` resolves, lexically,
    /// outside the project: an absolute target, or `..` climbing above the root.
    static func escapesProject(link: String, target: String) -> Bool {
        if target.hasPrefix("/") || target.hasPrefix("~") {
            return true
        }
        var depth = link.split(separator: "/").count - 1 // folders above the link inside the project
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            if component == ".." {
                depth -= 1
                if depth < 0 {
                    return true
                }
            } else if component != "." {
                depth += 1
            }
        }
        return false
    }
}

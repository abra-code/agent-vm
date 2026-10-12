// Sources/agent-vm/ConnectScreen.swift
//
// What connect's lists show around their rows when they take the whole window: the AgentVM
// banner, and under it what the choices are for (the folder shared). Without cursor control
// (TERM=dumb) a list is a numbered menu, which has no screen and is given a title that says it
// all.

import Foundation
import TerminalUI

enum ConnectScreen {
    /// The letters of the banner, each as six lines of one width.
    private static let letters: [[String]] = [
        [#"    _    "#,
         #"   / \   "#,
         #"  / _ \  "#,
         #" / ___ \ "#,
         #"/_/   \_\"#,
         #"         "#],
        [#"       "#,
         #"  __ _ "#,
         #" / _` |"#,
         #"| (_| |"#,
         #" \__, |"#,
         #" |___/ "#],
        [#"      "#,
         #"  ___ "#,
         #" / _ \"#,
         #"|  __/"#,
         #" \___|"#,
         #"      "#],
        [#"       "#,
         #" _ __  "#,
         #"| '_ \ "#,
         #"| | | |"#,
         #"|_| |_|"#,
         #"       "#],
        [#" _   "#,
         #"| |_ "#,
         #"| __|"#,
         #"| |_ "#,
         #" \__|"#,
         #"     "#],
        [#"__     __"#,
         #"\ \   / /"#,
         #" \ \ / / "#,
         #"  \ V /  "#,
         #"   \_/   "#,
         #"         "#],
        [#" __  __ "#,
         #"|  \/  |"#,
         #"| |\/| |"#,
         #"| |  | |"#,
         #"|_|  |_|"#,
         #"        "#],
    ]

    /// "AgentVM" in letters six lines tall, 51 columns wide.
    static let banner: [String] = (0..<6).map { line in
        letters.map { $0[line] }.joined()
    }

    /// The line under the banner: the folder the session shares.
    static func context(project: String?) -> String {
        return project.map { "project " + ConnectRunner.tilde($0) } ?? "no folder shared"
    }

    /// A list of connect's. On a terminal with cursor control it takes the whole window, under
    /// the banner and `context`; `escape` says what Escape does there ("quit" or "back").
    /// Without, it is a numbered menu titled `plainTitle` (default: `title`).
    static func picker(_ title: String, plainTitle: String? = nil, context: String?, sections: [PickerSection], selected: String?,
                       setting: PickerSetting? = nil, escape: String = "quit", terminal: Terminal) -> Picker {
        guard terminal.style.cursorControl else {
            return Picker(title: plainTitle ?? title, sections: sections, selected: selected, setting: setting)
        }
        return Picker(title: title, sections: sections, selected: selected, setting: setting,
                      screen: PickerScreen(banner: banner, name: "AgentVM", context: context, escape: escape))
    }
}

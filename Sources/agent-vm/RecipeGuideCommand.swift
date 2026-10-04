// Sources/agent-vm/RecipeGuideCommand.swift
//
// `agent-vm recipe guide`: prints Recipes/WRITING-RECIPES.md, the guide an AI agent follows to
// write a recipe, so that one sentence is enough to start it: "Run `agent-vm recipe guide` and
// follow it to write a recipe that installs ...".

import AgentVMKit
import ArgumentParser
import Foundation

extension RecipeCommand {
    struct Guide: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the guide to writing a recipe, written for an AI agent.",
            discussion: """
                The guide is whole and needs nothing else: the format, what steps can rely on, \
                the loop of `recipe check` and a scratch build, when to ask the person, and the \
                shipped recipes to copy from. It is the file Recipes/WRITING-RECIPES.md next to \
                the agent-vm program; --path prints where that is.
                """)

        @Flag(name: .long, help: "Print the guide's path instead of its text.")
        var path = false

        func run() throws {
            // Read in both cases: a path to a file that is not there helps nobody.
            let url = RecipeGuide.url()
            let text = try RecipeGuide.text(at: url)
            if path, let url {
                print(url.path)
                return
            }
            // As it is: the guide is agent-vm's own file, and its tables and code blocks must
            // arrive unchanged.
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }
}

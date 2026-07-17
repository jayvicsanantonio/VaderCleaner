// SmartInsightsPromptTests.swift
// Pins the Smart Insights prompt wording: it names the item and asks the on-device model about deletion safety.

import XCTest
@testable import VaderCleaner

final class SmartInsightsPromptTests: XCTestCase {

    func test_prompt_includesItemNameAndDeletionIntent() {
        let prompt = SmartInsightsPrompt.text(for: "User Cache Files")
        XCTAssertTrue(prompt.contains("User Cache Files"), "Prompt should name the item so the model can identify it.")
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("delete"), "Prompt should ask about deletion safety.")
    }

    func test_prompt_escapesNothingButKeepsNameVerbatim() {
        // A name with spaces and mixed case must survive into the prompt as-is.
        let prompt = SmartInsightsPrompt.text(for: "Xcode Junk")
        XCTAssertTrue(prompt.contains("\"Xcode Junk\""))
    }

    func test_instructions_frameTheDeletionSafetyTask() {
        XCTAssertTrue(SmartInsightsPrompt.instructions.localizedCaseInsensitiveContains("delete"),
                      "Instructions should orient the model toward deletion safety.")
        XCTAssertTrue(SmartInsightsPrompt.instructions.localizedCaseInsensitiveContains("concise"),
                      "Instructions should ask for a concise answer that fits the popover.")
    }
}

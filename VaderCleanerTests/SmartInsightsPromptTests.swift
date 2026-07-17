// SmartInsightsPromptTests.swift
// Pins the Smart Insights prompt wording per topic: each names the item and frames the right question (delete, uninstall, run, disable, remove).

import XCTest
@testable import VaderCleaner

final class SmartInsightsPromptTests: XCTestCase {

    func test_fileOrFolder_prompt_namesItemAndAsksAboutDeletion() {
        let prompt = SmartInsightsTopic.fileOrFolder.prompt(for: "User Cache Files")
        XCTAssertTrue(prompt.contains("\"User Cache Files\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("delete"))
    }

    func test_application_prompt_framesAppUsage() {
        let prompt = SmartInsightsTopic.application.prompt(for: "Discord")
        XCTAssertTrue(prompt.contains("\"Discord\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("app"))
    }

    func test_maintenanceTask_prompt_framesRunning() {
        let prompt = SmartInsightsTopic.maintenanceTask.prompt(for: "Rebuild Spotlight Index")
        XCTAssertTrue(prompt.contains("\"Rebuild Spotlight Index\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("task"))
    }

    func test_privacyData_prompt_framesRemoval() {
        let prompt = SmartInsightsTopic.privacyData.prompt(for: "Cookies")
        XCTAssertTrue(prompt.contains("\"Cookies\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("remove"))
    }

    func test_appExtension_prompt_framesExtension() {
        let prompt = SmartInsightsTopic.appExtension.prompt(for: "AdBlock")
        XCTAssertTrue(prompt.contains("\"AdBlock\""))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("extension"))
    }

    func test_everyCategory_hasADisplayLabel() {
        for category in SmartInsightCategory.allCases {
            XCTAssertFalse(category.label.isEmpty, "\(category) needs a display label for its pill.")
        }
    }

    func test_eachTopic_hasConciseInstructionsAndLoadingNoun() {
        for topic: SmartInsightsTopic in [.fileOrFolder, .application, .appExtension, .maintenanceTask, .loginItem, .privacyData] {
            XCTAssertTrue(topic.instructions.localizedCaseInsensitiveContains("concise"),
                          "\(topic) instructions should ask for a concise answer that fits the popover.")
            XCTAssertFalse(topic.loadingNoun.isEmpty, "\(topic) should provide a loading-line noun.")
        }
    }
}

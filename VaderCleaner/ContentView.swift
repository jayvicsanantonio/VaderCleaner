// ContentView.swift
// Root view — NavigationSplitView with sidebar listing all 11 sections and placeholder detail views.

import SwiftUI

struct ContentView: View {
    @State private var selectedSection: NavigationSection? = .smartScan

    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            if let section = selectedSection {
                PlaceholderDetailView(section: section)
            } else {
                PlaceholderDetailView(section: .smartScan)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct PlaceholderDetailView: View {
    let section: NavigationSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("Coming Soon")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(section.title)
    }
}

#Preview {
    ContentView()
}

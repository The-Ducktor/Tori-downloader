//
//  ContentView.swift
//  Tori
//
//  Created by Jackson Powell on 7/8/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]

    var body: some View {
        DownloadManagerView().animation(.default, value: UUID())
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}

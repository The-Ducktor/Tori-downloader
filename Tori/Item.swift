//
//  Item.swift
//  Tori
//
//  Created by Jackson Powell on 7/8/25.
//

import Foundation
import SwiftData
import Combine

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}


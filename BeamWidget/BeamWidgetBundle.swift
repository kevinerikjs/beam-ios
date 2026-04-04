//
//  BeamWidgetBundle.swift
//  BeamWidget
//
//  Created by Kevin on 05.04.2026.
//

import WidgetKit
import SwiftUI

@main
struct BeamWidgetBundle: WidgetBundle {
    var body: some Widget {
        BeamWidget()
        BeamWidgetControl()
        BeamWidgetLiveActivity()
    }
}

//
//  BeamWidgetLiveActivity.swift
//  BeamWidget
//
//  Created by Kevin on 05.04.2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct BeamWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct BeamWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BeamWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension BeamWidgetAttributes {
    fileprivate static var preview: BeamWidgetAttributes {
        BeamWidgetAttributes(name: "World")
    }
}

extension BeamWidgetAttributes.ContentState {
    fileprivate static var smiley: BeamWidgetAttributes.ContentState {
        BeamWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: BeamWidgetAttributes.ContentState {
         BeamWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: BeamWidgetAttributes.preview) {
   BeamWidgetLiveActivity()
} contentStates: {
    BeamWidgetAttributes.ContentState.smiley
    BeamWidgetAttributes.ContentState.starEyes
}

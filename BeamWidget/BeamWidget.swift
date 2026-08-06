tuff // BeamWidget.swift
// Lock screen and home screen widgets for one-tap stream start.
//
// Supports:
//   - .accessoryCircular    (lock screen circular button)
//   - .accessoryRectangular (lock screen wide row)
//
// Tapping any widget opens the app via beam://start and triggers auto-stream.

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct BeamWidgetEntry: TimelineEntry {
    let date: Date
}

struct BeamWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BeamWidgetEntry {
        BeamWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (BeamWidgetEntry) -> Void) {
        completion(BeamWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BeamWidgetEntry>) -> Void) {
        completion(Timeline(entries: [BeamWidgetEntry(date: .now)], policy: .never))
    }
}

// MARK: - Widget Views

struct BeamAccessoryCircularView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("BeamIcon")
                .resizable()
                .scaledToFit()
                .padding(6)
        }
    }
}

struct BeamAccessoryRectangularView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("BeamIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start Beam")
                    .font(.system(size: 14, weight: .bold))
                Text("Stream your Mac screen")
                    .font(.system(size: 11))
                    .opacity(0.7)
            }
            Spacer()
        }
    }
}

// MARK: - Entry View

struct BeamWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: BeamWidgetProvider.Entry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                BeamAccessoryCircularView()
            default:
                BeamAccessoryRectangularView()
            }
        }
        .widgetURL(URL(string: "beam://start"))
    }
}

// MARK: - Widget

struct BeamWidget: Widget {
    let kind: String = "BeamWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BeamWidgetProvider()) { entry in
            if #available(iOS 17.0, *) {
                BeamWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                BeamWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Beam")
        .description("Start streaming your Mac screen with one tap.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

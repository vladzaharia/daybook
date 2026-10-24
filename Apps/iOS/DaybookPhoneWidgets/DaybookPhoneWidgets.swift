import SwiftUI
import WidgetKit

@main
struct DaybookPhoneWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordConversationControl()
        RecorderWidget()
    }
}

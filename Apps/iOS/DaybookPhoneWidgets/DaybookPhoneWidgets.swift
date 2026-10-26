import SwiftUI
import WidgetKit

@main
struct DaybookPhoneWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecorderLiveActivity()
        RecordConversationControl()
        RecorderWidget()
    }
}

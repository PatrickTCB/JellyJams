import SwiftUI
import AVKit


#if os(iOS)
/// A system AirPlay / output-route button that presents the OS device picker and
/// routes the active `AVAudioSession`.
///
/// `AVRoutePickerView` (AVKit) is the modern, iOS-available control for this.
/// Apple's own `MPVolumeView` route button has been removed on iOS in favour of
/// this view, and its `routePickerButtonStyle` customization is tvOS-only. SwiftUI
/// has no native equivalent, so the `UIView` is wrapped in a `UIViewRepresentable`.
///
/// Because playback on this target is driven by ``PlayerController``'s `.playback`
/// `AVAudioSession`, the system routes the picker's selection to the stream that
/// is already playing, with no changes to that controller.
struct AirPlayPicker: View {
     var body: some View {
         RoutePicker()
               .frame(width: 40, height: 30)
               .accessibilityLabel("AirPlay")
       }

     private struct RoutePicker: UIViewRepresentable {
         func makeUIView(context: Context) -> AVRoutePickerView {
             let view = AVRoutePickerView(frame: .zero)
             view.prioritizesVideoDevices = false
             return view
           }

          // The picker is a one-time setup; nothing needs re-syncing per render.
         func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
       }
}
#endif

#import "event_sink.hpp"

#import <os/log.h>

static os_log_t echoLog = os_log_create("com.nate.airgestures", "echo");

namespace ag {

EchoSink::EchoSink(DisplayHandler display) : display_(std::move(display)) {}

void EchoSink::onGesture(const GestureState& state) {
    const bool stillNoHand = state.kind == GestureKind::None && lastKind_ == GestureKind::None;
    if (stillNoHand) {
        return;
    }

    if (state.kind != lastKind_) {
        os_log(echoLog, "gesture: %{public}s", gestureName(state.kind));
        lastKind_ = state.kind;
    }

    if (display_) {
        display_(state);
    }
}

}  // namespace ag

#import "menu_app.h"

#include <memory>

#include "camera_source.h"
#include "event_sink.hpp"
#include "gesture.hpp"
#include "vision_tracker.h"

static NSString* const idleTitle = @"AG";

@interface AGMenuApp () {
    // Declared so the tracker is destroyed first, then the camera, engine and sink it uses.
    std::unique_ptr<ag::EchoSink> _sink;
    std::unique_ptr<ag::GestureEngine> _engine;
    std::unique_ptr<ag::CameraSource> _camera;
    std::unique_ptr<ag::VisionTracker> _tracker;
    NSStatusItem* _statusItem;
    NSMenuItem* _toggleItem;
    NSMenuItem* _echoItem;
    BOOL _tracking;
}
@end

@implementation AGMenuApp

// ---- NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [self buildPipeline];
    [self buildMenu];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    _tracker->stop();
}

// ---- Actions

- (void)toggleTracking:(id)sender {
    if (_tracking) {
        _tracker->stop();
        _tracking = NO;
        _toggleItem.title = @"Start Tracking";
        _echoItem.title = @"Stopped";
        _statusItem.button.title = idleTitle;
    } else {
        _tracker->start();
        _tracking = YES;
        _toggleItem.title = @"Stop Tracking";
        _echoItem.title = @"Looking for a hand...";
    }
}

// ---- Setup

- (void)buildPipeline {
    const ag::Config config = ag::sanitized(ag::Config{});

    // The sink runs on the camera queue, so hop to the main thread before touching the menu.
    __weak AGMenuApp* weakSelf = self;
    _sink = std::make_unique<ag::EchoSink>([weakSelf](const ag::GestureState& state) {
        const ag::GestureState stateCopy = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf showGesture:stateCopy];
        });
    });

    _engine = std::make_unique<ag::GestureEngine>(config);
    _camera = std::make_unique<ag::CameraSource>();
    _tracker = std::make_unique<ag::VisionTracker>(*_camera);

    ag::GestureEngine* engine = _engine.get();
    ag::IActionSink* sink = _sink.get();
    _tracker->setHandCallback([engine, sink](const std::optional<ag::Hand>& hand) {
        const ag::GestureState state = engine->update(hand);
        sink->onGesture(state);
    });
}

- (void)buildMenu {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = idleTitle;

    _toggleItem = [[NSMenuItem alloc] initWithTitle:@"Start Tracking"
                                             action:@selector(toggleTracking:)
                                      keyEquivalent:@"s"];
    _toggleItem.target = self;

    _echoItem = [[NSMenuItem alloc] initWithTitle:@"Stopped" action:nil keyEquivalent:@""];
    _echoItem.enabled = NO;

    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit AirGestures"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];

    NSMenu* menu = [[NSMenu alloc] init];
    [menu addItem:_echoItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:_toggleItem];
    [menu addItem:quitItem];
    _statusItem.menu = menu;
}

// ---- Echo

- (void)showGesture:(ag::GestureState)state {
    if (!_tracking) {
        return;
    }

    NSString* symbol = @"AG";
    switch (state.kind) {
        case ag::GestureKind::None:
            symbol = @"AG";
            break;
        case ag::GestureKind::Open:
            symbol = @"✋";
            break;
        case ag::GestureKind::Pinch:
            symbol = @"🤏";
            break;
    }
    _statusItem.button.title = symbol;

    if (state.kind == ag::GestureKind::None) {
        _echoItem.title = @"Looking for a hand...";
    } else {
        _echoItem.title = [NSString stringWithFormat:@"%s at (%.2f, %.2f)",
                                                     ag::gestureName(state.kind),
                                                     static_cast<double>(state.x),
                                                     static_cast<double>(state.y)];
    }
}

@end

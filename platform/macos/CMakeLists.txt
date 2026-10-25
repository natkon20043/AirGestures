add_executable(AirGestures MACOSX_BUNDLE
  camera_source.mm
  vision_tracker.mm
  event_sink.mm
  menu_app.mm
  main.mm
)

target_link_libraries(AirGestures PRIVATE
  ag_core
  "-framework AVFoundation"
  "-framework CoreMedia"
  "-framework CoreVideo"
  "-framework Vision"
  "-framework AppKit"
  "-framework CoreGraphics"
  "-framework ApplicationServices"
)

# ARC only for Objective-C++ files
target_compile_options(AirGestures PRIVATE
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

set_target_properties(AirGestures PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
)
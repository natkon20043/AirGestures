#!/bin/sh
# Runs AirGestures with Xcode's Swift (swiftly's older Swift can't build against this SDK).
# Usage: ./run.sh [--events | --stream | --joints]
exec xcrun swift run AirGestures "$@"

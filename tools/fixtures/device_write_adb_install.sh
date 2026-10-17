#!/bin/sh
# POSITIVE-CONTROL FIXTURE -- this file is supposed to FAIL the §4.2 blacklist
# scan. tools/verify_all.sh section 14 greps it separately and fails the gate if
# it does NOT match, so a broken or over-excluded grep cannot pass in false.
# Nothing here runs: it is a string sample, never executed.
adb install -r /tmp/some-game.apk
adb shell settings put system show_touches 1
adb tcpip 5555

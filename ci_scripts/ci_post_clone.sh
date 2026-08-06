#!/bin/sh
# Xcode Cloud post-clone hook.
#
# Info.plist declares BeamFeedbackSecret as $(BEAM_FEEDBACK_SECRET) so the value stays out of a
# public repository. Nothing supplies that build setting on its own, so without this script the
# key builds out empty and the feedback endpoint stops being able to tell an official build's
# report from anyone else's. (The server is fail-open, so reports still arrive either way; what
# is lost is the verified-build badge.)
#
# Xcode Cloud exposes workflow environment variables to this script but not to xcodebuild's
# build settings, so the value is written into Info.plist here instead. Local builds do not run
# this: pass the setting to xcodebuild directly, see README.
#
# Absent variable is not an error. Contributor builds and forks have no secret and must still
# build; they simply ship without the badge, which is the intended behaviour.

set -e

PLIST="$CI_PRIMARY_REPOSITORY_PATH/Beam/Info.plist"

if [ -z "$BEAM_FEEDBACK_SECRET" ]; then
  echo "BEAM_FEEDBACK_SECRET not set; building without the feedback verification badge."
  exit 0
fi

if [ ! -f "$PLIST" ]; then
  echo "warning: $PLIST not found, skipping feedback secret injection."
  exit 0
fi

plutil -replace BeamFeedbackSecret -string "$BEAM_FEEDBACK_SECRET" "$PLIST"
echo "Injected BeamFeedbackSecret (${#BEAM_FEEDBACK_SECRET} chars)."

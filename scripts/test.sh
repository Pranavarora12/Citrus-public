#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./scripts/build.sh
# A plain command-line executable avoids LaunchServices app registration in headless tests.
cp build/Citrus.app/Contents/MacOS/Citrus build/citrus-tests
./build/citrus-tests --self-test

./build/citrus-tests --image-tools-audit "$PWD/build/image-tool-audit"

./build/citrus-tests --video-tools-audit "$PWD/build/video-tool-audit"

./build/citrus-tests --audio-trim-audit "$PWD/build/audio-trim-audit"

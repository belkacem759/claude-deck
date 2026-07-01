#!/bin/bash
# Build and run the ClaudeDeck test suite.
set -euo pipefail
cd "$(dirname "$0")"

clang -fobjc-arc -O1 -Wall -Werror \
    -framework Foundation \
    Sources/ClaudeDeckCore.m Tests/tests.m \
    -o claudedeck-tests

status=0
./claudedeck-tests || status=$?
rm -f claudedeck-tests
exit $status

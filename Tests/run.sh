#!/bin/bash
# Runs the priority logic tests. No Xcode test target: the logic file is Foundation-only,
# so it is compiled together with the tests by swiftc.
set -euo pipefail

cd "$(dirname "$0")/.."

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -parse-as-library \
  AudioPriorityBar/Services/PriorityLogic.swift \
  Tests/PriorityLogicTests.swift \
  -o "$out/priority-logic-tests"

"$out/priority-logic-tests"

#!/bin/bash

function info {
  echo "[$(basename "${0}")] [INFO] ${1}"
}

function die {
  echo "[$(basename "${0}")] [ERROR] ${1}"
  exit 1
}

# Verify xcpretty is installed
if ! command -v xcpretty > /dev/null; then
  if [[ "${CI}" != "true" ]]; then
    die "Please install xcpretty: https://github.com/supermarin/xcpretty#installation"
  fi

  info "Installing xcpretty..."
  gem install xcpretty --no-document || die "Executing \`gem install xcpretty\` failed"
fi

# Execute tests (iPhone 11 @ iOS 13.7)
info "Executing Basic Integration tests (iPhone 11 @ iOS 13.7)..."

xcodebuild test \
  -workspace "Stripe.xcworkspace" \
  -scheme "Basic Integration" \
  -configuration "Debug" \
  -sdk "iphonesimulator" \
  -destination "platform=iOS Simulator,name=iPhone 11,OS=13.7" \
  -derivedDataPath build-ci-tests \
  | xcpretty

exit_code="${PIPESTATUS[0]}"

if [[ "${exit_code}" != 0 ]]; then
  die "xcodebuild exited with non-zero status code: ${exit_code}"
fi

# Execute tests (iPhone 11 @ iOS latest)
info "Executing integration tests (iPhone 11 @ iOS latest)..."

xcodebuild test \
  -workspace "Stripe.xcworkspace" \
  -scheme "IntegrationTester" \
  -configuration "Debug" \
  -sdk "iphonesimulator" \
  -destination "platform=iOS Simulator,name=iPhone 11,OS=latest" \
  -derivedDataPath build-ci-tests \
  | xcpretty

# Execute PaymentSheet tests (iPhone 12 @ iOS latest)
info "Executing PaymentSheet tests (iPhone 12 @ iOS latest)..."

xcodebuild test \
  -workspace "Stripe.xcworkspace" \
  -scheme "PaymentSheet Example" \
  -configuration "Debug" \
  -sdk "iphonesimulator" \
  -destination "platform=iOS Simulator,name=iPhone 12,OS=latest" \
  -derivedDataPath build-ci-tests \
  | xcpretty

exit_code="${PIPESTATUS[0]}"

if [[ "${exit_code}" != 0 ]]; then
  die "xcodebuild exited with non-zero status code: ${exit_code}"
fi

info "All good!"

# Personal Log (iOS)

A SwiftUI app for logging habits and food and for browsing a daily personal health report with AI notes. It talks to a
Supabase backend whose address and keys are entered in the app's Settings on the phone, so this repository holds no
data and no credentials.

Built by GitHub Actions (`.github/workflows/ios.yml`): XcodeGen generates the project from `ios/project.yml`; with the
App Store Connect secrets the build is signed in the cloud and uploaded to TestFlight.

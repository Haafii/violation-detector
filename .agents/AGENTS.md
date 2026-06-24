# Project-specific Custom Rules

## Post-Modification Workflow (Auto-Release & Push)
Whenever any code modifications/bug fixes are completed and successfully verified:
1. **Compile both Split-ABI and Universal release APKs**:
   - Run: `flutter build apk --release --split-per-abi`
   - Run: `flutter build apk --release`
2. **Move files to target Desktop folder**:
   - Ensure `/Users/hafismuhammed/Desktop/ViolationDetector_APK/` exists.
   - Copy the split APKs and universal APK:
     - `app-arm64-v8a-release.apk`
     - `app-armeabi-v7a-release.apk`
     - `app-x86_64-release.apk`
     - `app-release.apk` (also copied and renamed as `violation-detector.apk`)
3. **Stage, commit, and push all modifications to GitHub**:
   - Run: `git add .`
   - Commit with a descriptive message outlining the fixes.
   - Push to `origin main`.

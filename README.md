# Eternal iOS

Original iOS app shell named **Eternal**. It launches directly into the main interface and contains no key/authentication screen.

## Build an IPA without a Mac

This project includes `.github/workflows/build-ipa.yml`.

1. Open the repository's **Actions** tab.
2. Open **Build Eternal IPA** and choose **Run workflow**.
3. When the run finishes, download the **Eternal-IPA** artifact.
4. Extract the artifact ZIP; it contains `Eternal.ipa`.

The produced IPA is unsigned. It must be signed with your own Apple development certificate/account before installing on an iPhone.

## Local Xcode build

Open `Eternal.xcodeproj`, select your signing team, and build to a device. The app bundle identifier defaults to `com.eternal.mobile`.

## Scope

This is a fresh Eternal app shell. It does not include Delta's proprietary binaries, assets, or licensing code, and its Execute control is a local placeholder rather than a Roblox injection/executor engine.

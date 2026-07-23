# Paragon Time Clock — build repo

This repo builds the **Android app** in the cloud. You don't need Flutter or any
tools installed — GitHub does the compiling and hands you an installable APK.

## How to build (one click)

1. Go to the **Actions** tab of this repo.
2. Pick **"Build Paragon Time Clock APK"** on the left.
3. Click **"Run workflow"** → **Run workflow**.
4. Wait ~10 minutes. When it finishes (green check), open the run and download the
   **ppc-timeclock-apk** artifact at the bottom. Unzip it → `app-debug.apk`.
5. Sideload that APK onto a tester's Android phone.

The build also runs automatically on every push to `main`.

## Before the real build

Edit `lib/config.dart` and set:
- `supabaseAnon` — the anon key (Supabase → Settings → API Keys)
- `employeeId` — the tester's UUID (from the dashboard Crew panel)

(`supabaseUrl` and the shop geofence are already set.)

## What's inside

- `lib/` — the app: background geofence punch, offline queue, Supabase insert.
- `pubspec.yaml` — dependencies.
- `.github/workflows/build-apk.yml` — the cloud build recipe (scaffolds the Android
  project, applies permissions + Gradle config, builds the APK, uploads it).

Backend is already live (Supabase project **Workdays**). This repo is only the app.

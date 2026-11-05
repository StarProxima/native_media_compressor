#!/bin/bash
# Switches the example app to AGP 8 and Kotlin Gradle Plugin 2.x, so CI also
# builds the plugin the way older apps include it.
set -euo pipefail
cd "$(dirname "$0")/../../example/android"

sed -i.bak \
  -e 's/"com.android.application") version "[^"]*"/"com.android.application") version "8.11.1"/' \
  -e 's/"org.jetbrains.kotlin.android") version "[^"]*"/"org.jetbrains.kotlin.android") version "2.2.20"/' \
  settings.gradle.kts
sed -i.bak -e 's/^    id("com.android.application")$/    id("com.android.application")\
    id("kotlin-android")/' app/build.gradle.kts
sed -i.bak -e 's#distributions/gradle-[^-]*-all.zip#distributions/gradle-8.14-all.zip#' \
  gradle/wrapper/gradle-wrapper.properties
rm -f settings.gradle.kts.bak app/build.gradle.kts.bak gradle/wrapper/gradle-wrapper.properties.bak

grep -n 'version "' settings.gradle.kts
grep -n 'kotlin-android' app/build.gradle.kts
grep -n 'distributionUrl' gradle/wrapper/gradle-wrapper.properties

# JNI and reflection address generated peers and runtime classes by name.
-keep class com.example.hackernewsreader.swift.** { *; }
-keep class org.swift.swiftkit.** { *; }
-keep class com.example.hackernewsreader.PlatformServices { *; }

# Upstream thread-safety annotations carry optional desktop-only JFR labels.
-dontwarn jdk.jfr.Description
-dontwarn jdk.jfr.Label

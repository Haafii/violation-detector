# Flutter + ML Kit ProGuard rules

# ── Flutter Play Store deferred components (not used, suppress R8 warnings) ─
-dontwarn com.google.android.play.core.**

# ── ML Kit text recognition optional language models ────────────────────────
# These are referenced by the plugin but only needed if using those scripts.
# We only use Latin (English / Indian plates), so suppress the warnings.
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# ── Keep ML Kit text recognition classes ────────────────────────────────────
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }

# ── TFLite / ultralytics_yolo ────────────────────────────────────────────────
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**

# ── Flutter standard rules ───────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# PDFBox-Android ProGuard Rules
-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter
-dontwarn javax.xml.stream.**
-dontwarn java.awt.**

-keep class com.tom_roush.pdfbox.** { *; }
-keep class org.apache.fontbox.** { *; }

# If you use specific features, you might need more, but these should fix the build error.

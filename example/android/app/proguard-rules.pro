# Example app ProGuard rules
# These are often needed even if the plugin has consumer rules, 
# especially if the app itself adds minify/shrink logic.

-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter
-dontwarn javax.xml.stream.**
-dontwarn java.awt.**

-keep class com.tom_roush.pdfbox.** { *; }
-keep class org.apache.fontbox.** { *; }

import 'package:flutter/widgets.dart';

/// Supported languages for PDF viewer
enum PdfViewerLanguage {
  /// English language
  english,

  /// Arabic language (RTL)
  arabic,
}

/// Localizations for PDF viewer UI strings
class PdfLocalizations {
  final PdfViewerLanguage language;

  const PdfLocalizations(this.language);

  /// Factory constructor to create from Locale
  factory PdfLocalizations.fromLocale(Locale locale) {
    if (locale.languageCode == 'ar') {
      return const PdfLocalizations(PdfViewerLanguage.arabic);
    }
    return const PdfLocalizations(PdfViewerLanguage.english);
  }

  /// Whether the current language is RTL
  bool get isRTL => language == PdfViewerLanguage.arabic;

  /// Translation map for all supported languages
  static const Map<PdfViewerLanguage, Map<String, String>> _localizedValues = {
    PdfViewerLanguage.english: {
      'bookmarks': 'Bookmarks',
      'noBookmarksYet': 'No bookmarks yet',
      'close': 'Close',
      'delete': 'Delete',
      'pageNumber': 'Page {n}',
      'addText': 'Add Text',
      'enterTextHere': 'Enter text here',
      'addBookmark': 'Add Bookmark',
      'enterBookmarkName': 'Enter bookmark name',
      'bookmarkName': 'Bookmark Name',
      'save': 'Save',
      'cancel': 'Cancel',
      'add': 'Add',
      'bookmarkAdded': 'Bookmark added',
      'bookmarkRemoved': 'Bookmark removed',
      'error': 'Error: {error}',
      'notSupported': '{platform} is not supported',
      'toolbarSettings': 'Toolbar Settings',
      'position': 'Position',
      'theme': 'Theme',
      'transparency': 'Transparency',
      'top': 'Top',
      'bottom': 'Bottom',
      'floating': 'Floating',
      'pan': 'Pan',
      'draw': 'Draw',
      'highlight': 'Highlight',
      'underline': 'Underline',
      'undo': 'Undo',
      'redo': 'Redo',
      'clearAll': 'Clear All',
      'fullScreen': 'Full Screen',
      'zoomIn': 'Zoom In',
      'zoomOut': 'Zoom Out',
      'viewBookmarks': 'View Bookmarks',
      'search': 'Search',
      'searching': 'Searching...',
      'next': 'Next',
      'previous': 'Previous',
      'results': '{current}/{total}',
      'clearSearch': 'Clear Search',
      'selectColor': 'Select Color',
      'customColor': 'Custom Color',
      'deleteText': 'Delete Text',
      'textSize': 'Text Size',
      'strokeWidth': 'Thickness',
    },
    PdfViewerLanguage.arabic: {
      'bookmarks': 'الصفحات المحفوظه',
      'noBookmarksYet': 'لا يوجد صفحات محفوظه',
      'close': 'إغلاق',
      'delete': 'حذف',
      'pageNumber': 'صفحة {n}',
      'addText': 'إضافة نص',
      'enterTextHere': 'أدخل النص هنا',
      'addBookmark': "اضافة صفحة ك مرجع",
      'enterBookmarkName': "أدخل اسم الصفحة",
      'bookmarkName': 'اسم الصفحة',
      'save': 'حفظ',
      'cancel': 'إلغاء',
      'add': 'إضافة',
      'bookmarkAdded': "تمت إضافة الصفحة ك مرجع",
      'bookmarkRemoved': 'تمت إزالة الصفحة ك مرجع',
      'error': 'خطأ: {error}',
      'notSupported': '{platform} غير مدعوم',
      'toolbarSettings': 'إعدادات شريط الأدوات',
      'position': 'الموقع',
      'theme': 'المظهر',
      'transparency': 'الشفافية',
      'top': 'أعلى',
      'bottom': 'أسفل',
      'floating': 'عائم',
      'pan': 'تحريك',
      'draw': 'رسم',
      'highlight': 'تحديد',
      'underline': 'تسطير',
      'undo': 'تراجع',
      'redo': 'إعادة',
      'clearAll': 'مسح الكل',
      'fullScreen': 'ملء الشاشة',
      'zoomIn': 'تكبير',
      'zoomOut': 'تصغير',
      'viewBookmarks': 'عرض المراجع',
      'search': 'بحث',
      'searching': 'جاري البحث...',
      'next': 'التالي',
      'previous': 'السابق',
      'results': '{current}/{total}',
      'clearSearch': 'مسح البحث',
      'selectColor': 'اختر اللون',
      'customColor': 'لون مخصص',
      'deleteText': 'حذف النص',
      'textSize': 'حجم النص',
      'strokeWidth': 'السُمك',
    },
  };

  /// Helper to get string by key
  String _getString(String key) {
    return _localizedValues[language]![key] ??
        _localizedValues[PdfViewerLanguage.english]![key]!;
  }

  // Bookmarks Dialog Strings
  String get bookmarks => _getString('bookmarks');
  String get noBookmarksYet => _getString('noBookmarksYet');
  String get close => _getString('close');
  String get delete => _getString('delete');
  String pageNumber(int page) =>
      _getString('pageNumber').replaceAll('{n}', '${page + 1}');

  // Text Annotation Strings
  String get addText => _getString('addText');
  String get enterTextHere => _getString('enterTextHere');

  // Bookmark Management Strings
  String get addBookmark => _getString('addBookmark');
  String get enterBookmarkName => _getString('enterBookmarkName');
  String get bookmarkName => _getString('bookmarkName');

  // Common Action Strings
  String get save => _getString('save');
  String get cancel => _getString('cancel');
  String get add => _getString('add');

  // Feedback Messages
  String get bookmarkAdded => _getString('bookmarkAdded');
  String get bookmarkRemoved => _getString('bookmarkRemoved');

  // Error Messages
  String errorMessage(String error) =>
      _getString('error').replaceAll('{error}', error);
  String platformNotSupported(String platform) =>
      _getString('notSupported').replaceAll('{platform}', platform);

  // Toolbar Settings Strings
  String get toolbarSettings => _getString('toolbarSettings');
  String get position => _getString('position');
  String get theme => _getString('theme');
  String get transparency => _getString('transparency');
  String get top => _getString('top');
  String get bottom => _getString('bottom');
  String get floating => _getString('floating');
  String get pan => _getString('pan');
  String get draw => _getString('draw');
  String get highlight => _getString('highlight');
  String get underline => _getString('underline');
  String get undo => _getString('undo');
  String get redo => _getString('redo');
  String get clearAll => _getString('clearAll');
  String get fullScreen => _getString('fullScreen');
  String get zoomIn => _getString('zoomIn');
  String get zoomOut => _getString('zoomOut');
  String get viewBookmarks => _getString('viewBookmarks');

  // Search Strings
  String get search => _getString('search');
  String get searching => _getString('searching');
  String get next => _getString('next');
  String get previous => _getString('previous');
  String searchResults(int current, int total) => _getString(
    'results',
  ).replaceAll('{current}', '$current').replaceAll('{total}', '$total');
  String get clearSearch => _getString('clearSearch');
  String get selectColor => _getString('selectColor');
  String get customColor => _getString('customColor');
  String get deleteText => _getString('deleteText');
  String get textSize => _getString('textSize');
  String get strokeWidth => _getString('strokeWidth');

  /// Get localization from context or return default English
  static PdfLocalizations of(BuildContext context) {
    // Try to get from InheritedWidget first
    final provider = context
        .dependOnInheritedWidgetOfExactType<PdfLocalizationsProvider>();
    if (provider != null) {
      return provider.localizations;
    }

    // Fallback to default English
    return const PdfLocalizations(PdfViewerLanguage.english);
  }
}

/// InheritedWidget to provide localizations throughout the widget tree
class PdfLocalizationsProvider extends InheritedWidget {
  final PdfLocalizations localizations;

  const PdfLocalizationsProvider({
    super.key,
    required this.localizations,
    required super.child,
  });

  @override
  bool updateShouldNotify(PdfLocalizationsProvider oldWidget) {
    return localizations.language != oldWidget.localizations.language;
  }

  /// Get localizations from context
  static PdfLocalizations of(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<PdfLocalizationsProvider>();
    if (provider != null) {
      return provider.localizations;
    }

    // Fallback to English
    return const PdfLocalizations(PdfViewerLanguage.english);
  }
}

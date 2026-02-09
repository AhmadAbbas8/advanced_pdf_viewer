//
//  ObjCExceptionHandler.h
//  advanced_pdf_viewer
//
//  Objective-C exception handler for catching exceptions that Swift cannot catch
//

#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionHandler : NSObject

/// Safely attempts to get page text, catching Objective-C exceptions
+ (nullable NSString *)safelyGetPageString:(PDFPage *)page;

/// Safely attempts to create selection, catching Objective-C exceptions
+ (nullable PDFSelection *)safelyCreateSelectionFromPoint:(CGPoint)start 
                                                  toPoint:(CGPoint)end 
                                                   onPage:(PDFPage *)page;

/// Safely attempts to get selection for line, catching Objective-C exceptions  
+ (nullable PDFSelection *)safelyGetSelectionForLineAtPoint:(CGPoint)point 
                                                     onPage:(PDFPage *)page;

@end

NS_ASSUME_NONNULL_END

//
//  ObjCExceptionHandler.m
//  advanced_pdf_viewer
//
//  Objective-C exception handler implementation
//

#import "ObjCExceptionHandler.h"

@implementation ObjCExceptionHandler

+ (nullable NSString *)safelyGetPageString:(PDFPage *)page {
  @try {
    return page.string;
  } @catch (NSException *exception) {
    NSLog(@"Exception getting page string (likely image-only PDF): %@",
          exception);
    return nil;
  }
}

+ (nullable PDFSelection *)safelyCreateSelectionFromPoint:(CGPoint)start
                                                  toPoint:(CGPoint)end
                                                   onPage:(PDFPage *)page {
  @try {
    return [page selectionFromPoint:start toPoint:end];
  } @catch (NSException *exception) {
    NSLog(@"Exception creating selection (likely image-only PDF): %@",
          exception);
    return nil;
  }
}

+ (nullable PDFSelection *)safelyGetSelectionForLineAtPoint:(CGPoint)point
                                                     onPage:(PDFPage *)page {
  @try {
    return [page selectionForLineAtPoint:point];
  } @catch (NSException *exception) {
    NSLog(@"Exception getting line selection (likely image-only PDF): %@",
          exception);
    return nil;
  }
}

@end

// 
// Copyright (c) 2012 FadingRed LLC
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// 

#include <sys/stat.h>

#import "FRLocalizationWindowController.h"
#import "FRUntranslatedCountCell.h"
#import "FRLocalizationBundleAdditions.h"
#import "FRLocalizationBundleAdditions__.h"
#import "FRTranslationContainer__.h"
#import "FRTranslationInfo__.h"
#import "FRBundleAdditions.h"
#import "FRFileManagerArchivingAdditions.h"
#import "FRStrings.h"

#define COMMENT [NSColor colorWithCalibratedWhite:0.70 alpha:1]
#define TRANSLATION [NSColor colorWithCalibratedRed:0.75 green:0.72 blue:0.65 alpha:1.00]
#define TRANSLATION_COMPLETE [NSColor colorWithCalibratedRed:0.00 green:0.29 blue:0.55 alpha:1.00]
#define TRANSLATION_INCOMPLETE [NSColor colorWithCalibratedRed:0.69 green:0.19 blue:0.27 alpha:1.00]
#define UNKNOWN [NSColor colorWithCalibratedWhite:1.00 alpha:1]
#define UNKNOWN_BACKGROUND [NSColor colorWithCalibratedRed:0.72 green:0.12 blue:0.20 alpha:1.00]

static NSString * gSystemLanguage = nil;
static NSString * const kPathKey = @"path"; 
static NSString * const kDisplayNameKey = @"displayName"; 
static NSString * const kFileNameKey = @"fileName"; 
static NSString * const kBundleKey = @"bundleName"; 
static NSString * const FRLocalizationTypePreferenceKey = @"FRLocalizationType";
static void * const FRStringsFileCollectionDidChangeContext = @"FRStringsFileCollectionDidChangeContext";
static void * const FRStringsFileDidChangeContext = @"FRStringsFileDidChangeContext";
static void * const FRSelectedContainerDidChangeContext = @"FRSelectedContainerDidChangeContext";
static void * const FRSelectedLanguageDidChangeContext = @"FRSelectedLanguageDidChangeContext";
static const NSTimeInterval kSaveTimeout = 0.5;
static const NSSize kTextContainerInset = { .width = 15, .height = 10 };
NSString * const FRLocalizationErrorDomain = @"FRLocalizationErrorDomain";

@protocol FRApplicationDelegateOptional <NSObject>
- (void)sendStringsFilesToDevice:(NSArray *)objects;
@end

@interface FRLocalizationWindowController ()
- (void)loadLanguages;
- (void)loadStringsFiles;
- (void)loadTextView;
- (void)updateSendButtonVisibility;
- (void)updateContainersPopupVisibility;
- (void)persistSelectedLanguage;
- (void)processEditing:(NSNotification *)notification;
- (void)colorTextInRange:(NSRange)range ofString:(NSMutableAttributedString *)string;
- (void)addAttributesForLineInRange:(NSRange)range ofString:(NSMutableAttributedString *)string
						andContinue:(BOOL *)shouldContinue;
@end

@implementation FRLocalizationWindowController

+ (void)initialize {
	if (self == [FRLocalizationWindowController class]) {
		NSArray *languages = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
		gSystemLanguage = ([languages count]) ? [languages objectAtIndex:0] : GREENWICH_DEFAULT_LANGUAGE;
		[[NSUserDefaults standardUserDefaults] registerDefaults:
		 [NSDictionary dictionaryWithObjectsAndKeys:
		  gSystemLanguage, FRLocalizationTypePreferenceKey, nil]];
	}
}


#pragma mark -
#pragma mark init/dealloc
// ----------------------------------------------------------------------------------------------------
// init/dealloc
// ----------------------------------------------------------------------------------------------------

- (id)init {
	if ((self = [super initWithWindowNibName:@"Localization"])) {
		// placeholder
	}
	return self;
}

#if !__OBJC_GC__
- (void)dealloc {
	[stringsFiles setContent:nil];
	[stringsFiles removeObserver:self forKeyPath:@"arrangedObjects"];
	[saveTimer invalidate];
}
#endif


#pragma mark -
#pragma mark loading
// ----------------------------------------------------------------------------------------------------
// loading
// ----------------------------------------------------------------------------------------------------

- (void)addContainer:(FRTranslationContainer *)container {
	[self window]; // make sure the nib is loaded so we can access containers
	[containers addObject:container];
	[self updateContainersPopupVisibility];
}

- (void)awakeFromNib {
	[[self window] center];
	
	initialLanguagePosition = [languagesPopup frame].origin.x;
	[self updateContainersPopupVisibility];
	
	[textView setFont:[NSFont fontWithName:@"Menlo" size:12]];
	[textView setTextContainerInset:kTextContainerInset];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(processEditing:)
												 name:NSTextStorageDidProcessEditingNotification
											   object:[textView textStorage]];
	
	[tableView sizeLastColumnToFit];
	[tableView setSortDescriptors:
	 [NSArray arrayWithObject:
	  [[NSSortDescriptor alloc] initWithKey:kDisplayNameKey ascending:YES]]];
	
	NSKeyValueObservingOptions options =
		NSKeyValueObservingOptionNew |
		NSKeyValueObservingOptionOld |
		NSKeyValueObservingOptionInitial;
	[stringsFiles addObserver:self forKeyPath:@"arrangedObjects"
					  options:options context:FRStringsFileCollectionDidChangeContext];
	
	[containers addObserver:self forKeyPath:@"selectedObjects"
				   options:NSKeyValueObservingOptionInitial context:FRSelectedContainerDidChangeContext];
	[languages addObserver:self forKeyPath:@"selectedObjects"
				   options:NSKeyValueObservingOptionInitial context:FRSelectedLanguageDidChangeContext];
}


#pragma mark -
#pragma mark properties
// ----------------------------------------------------------------------------------------------------
// properties
// ----------------------------------------------------------------------------------------------------

- (void)setConnectionActive:(BOOL)connectionActive {
	[self window]; // ensure outlets are connected
	[sendToDeviceButton setEnabled:connectionActive];
}

- (void)setConnectionMessageString:(NSString *)string {
	[self window]; // ensure outlets are connected
	[connectionMessageTextField setStringValue:string];
}

#pragma mark -
#pragma mark observations
// ----------------------------------------------------------------------------------------------------
// observations
// ----------------------------------------------------------------------------------------------------

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
						change:(NSDictionary *)change context:(void *)context {
	
	if (context == FRStringsFileCollectionDidChangeContext) {
		id removed = [change objectForKey:NSKeyValueChangeOldKey];
		id added = [change objectForKey:NSKeyValueChangeNewKey];
		if (removed == [NSNull null]) { removed = nil; }
		if (added == [NSNull null]) { added = nil; }
		[removed removeObserver:self
		   fromObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [removed count])]
					 forKeyPath:@"untranslatedCount"];
		[added addObserver:self
			 toObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [added count])]
					 forKeyPath:@"untranslatedCount"
						options:0
						context:FRStringsFileDidChangeContext];
	}
	else if (context == FRStringsFileDidChangeContext) {
		[tableView setNeedsDisplay];
	}
	else if (context == FRSelectedContainerDidChangeContext) {
		[self updateSendButtonVisibility];
		[self loadLanguages];
	}
	else if (context == FRSelectedLanguageDidChangeContext) {
		[self loadStringsFiles];
		[self persistSelectedLanguage];
	}
	else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}


#pragma mark -
#pragma mark helpers
// ----------------------------------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------------------------------

- (void)saveSelectedStringsFile {
	FRTranslationInfo *info = [[stringsFiles selectedObjects] lastObject];
	if (info) {
		NSString *path = info.path;
		NSError *error = nil;
		BOOL written = FALSE;
		FRStringsFormat format = FRStringsFormatQuoted;
		NSData *data = [[textView string] dataUsingEncoding:NSUTF16StringEncoding];
		FRStrings *strings = [[FRStrings alloc] initWithData:data usedFormat:&format error:&error];
		if (strings) {
			written = [strings writeToFile:path format:FRStringsFormatQuoted error:&error];
		}
		if (!written) {
			[[self window] presentError:error];
		}
	}
}

- (void)loadLanguages {
	FRTranslationContainer *container = [[containers selectedObjects] lastObject];
	NSMutableArray *languagesArray = [[container launagues] mutableCopy];
	NSString *defaultLanguage = [[NSUserDefaults standardUserDefaults] objectForKey:FRLocalizationTypePreferenceKey];
	
	if (![languagesArray containsObject:defaultLanguage]) {
		[languagesArray addObject:defaultLanguage];
	}
	if (![languagesArray containsObject:gSystemLanguage]) {
		[languagesArray addObject:gSystemLanguage];
	}
	
	[languages setContent:languagesArray];
	[languages rearrangeObjects];
	[languages setSelectedObjects:
	 [NSArray arrayWithObjects:defaultLanguage, nil]];
}

- (void)loadStringsFiles {
	FRTranslationContainer *container = [[containers selectedObjects] lastObject];
	NSArray *content = nil;
	if (container) {
		NSString *language = [[languages selectedObjects] lastObject];
		NSError *error = nil;
		if ((content = [container infoItemsForLanguage:language error:&error]) == nil) {
			[NSApp presentError:error];
		}
	}
	[stringsFiles setContent:content];
	[self loadTextView];
}

- (void)loadTextView {
	NSString *contents = nil;
	FRTranslationInfo *info = [[stringsFiles selectedObjects] lastObject];
	NSError *error = nil;
	if (info) {
		NSData *data = [NSData dataWithContentsOfFile:info.path options:0 error:&error];
		if (data) {
			FRStringsFormat format = FRStringsFormatQuoted;
			FRStrings *strings = [[FRStrings alloc] initWithData:data usedFormat:&format error:&error];
			contents = [strings contentsInFormat:FRStringsFormatQuoted];
		}
		if (!contents) {
			[[self window] presentError:error];
		}
	}
	[textView setString:contents ? contents : @""];
}

- (void)updateSendButtonVisibility {
	[sendToDeviceButton setHidden:
	 ![[[containers selectedObjects] lastObject] isSynced]];
}

- (void)updateContainersPopupVisibility {
	NSRect languagesFame = [languagesPopup frame];
	if ([[containers arrangedObjects] count] <= 1) {
		languagesFame.origin.x = [containersPopup frame].origin.x;
		[containersPopup setHidden:YES];
	}
	else {
		languagesFame.origin.x = initialLanguagePosition;
		[containersPopup setHidden:NO];
	}
	[languagesPopup setFrame:languagesFame];
}

- (void)persistSelectedLanguage {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSString *language = [[languages selectedObjects] lastObject];
	if (language) {
		[defaults setObject:language forKey:FRLocalizationTypePreferenceKey];
	}
}


#pragma mark -
#pragma mark actions
// ----------------------------------------------------------------------------------------------------
// actions
// ----------------------------------------------------------------------------------------------------

#if REDFOUNDATION_LEOPARD_BASE
- (void)saveDidEnd:(NSSavePanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	void (^completion)(NSInteger) = (__bridge id)contextInfo;
	completion(returnCode);
}
#endif

- (IBAction)packageStringsFiles:(id)sender {
	NSSavePanel *panel = [NSSavePanel savePanel];
	[panel setTitle:FRLocalizedString(@"Save Location", nil)];
	[panel setMessage:FRLocalizedString(@"Please choose a location to save your translation package", nil)];
	[panel setPrompt:FRLocalizedString(@"Save", nil)];
	[panel setExtensionHidden:TRUE];
	[panel setAllowedFileTypes:[NSArray arrayWithObject:@"tbz"]];

	void (^completion)(NSInteger) = ^(NSInteger returnCode) {
		if (returnCode == NSFileHandlingPanelOKButton) {
			NSError *error = nil;
			NSFileManager *fileManager = [NSFileManager defaultManager];
			char *tmpname = NULL;
			asprintf(&tmpname, "%s/translation.XXXXXX", [NSTemporaryDirectory() UTF8String]);
			mktemp(tmpname);
			NSString *temp = [[NSString stringWithUTF8String:tmpname] stringByAppendingPathComponent:
							  [[NSBundle mainBundle] name]];
			free(tmpname);

			// make the folder that the strings files will be packaged into
			if (![fileManager createDirectoryAtPath:temp
						withIntermediateDirectories:YES
										 attributes:nil
											  error:&error]) {
				NSLog(@"Problem creating destination folder with error: %@", error);
			}
			
			// copy strings files to the folder that will be packaged
			for (FRTranslationInfo *info in [stringsFiles arrangedObjects]) {
				NSString *path = info.path;
				NSString *bundle = info.bundleName;
				NSString *fileName = info.fileName;
				if (![bundle length]) { bundle = [[NSBundle mainBundle] name]; }
				NSString *destinationDirectory = [temp stringByAppendingPathComponent:bundle];
				NSString *destinationPath = [destinationDirectory stringByAppendingPathComponent:fileName];
				BOOL result =
					[fileManager createDirectoryAtPath:destinationDirectory
						   withIntermediateDirectories:YES
											attributes:nil
												 error:&error] &&
					[fileManager copyItemAtPath:path
										 toPath:destinationPath
										  error:&error];
				if (!result) {
					NSLog(@"Problem copying strings files with error: %@", error);
				}
			}
			
			// package the folder into a .tbz for emailing
			NSString *archiveDestination = [[panel URL] path];
			[fileManager removeItemAtPath:archiveDestination error:NULL];
#if REDFOUNDATION_LEOPARD_BASE
			BOOL result = [fileManager compressFileAtPath:temp to:archiveDestination error:&error];
#else
			BOOL result = [fileManager compressItemAtPath:temp to:archiveDestination error:&error];
#endif
			if (!result) {
				NSLog(@"Problem archiving strings files package with error: %@", error);
			} else {
				if (![fileManager removeItemAtPath:temp error:&error]) {
					NSLog(@"Problem removing file package temp directory with error: %@", error);
				}
			}
		}
	};

    // the desktop is available through expanding ~ whether using sandboxing or not.
    // with sandboxing, it's available through the application's container.
#if REDFOUNDATION_LEOPARD_BASE
	[panel beginSheetForDirectory:[@"~/Desktop" stringByExpandingTildeInPath]
							 file:@"translation"
				   modalForWindow:[self window]
					modalDelegate:self
				   didEndSelector:@selector(saveDidEnd:returnCode:contextInfo:)
					  contextInfo:[completion copy]];
#else
	[panel setDirectoryURL:[NSURL fileURLWithPath:[@"~/Desktop" stringByExpandingTildeInPath]]];
	[panel setNameFieldStringValue:@"translation"];
	[panel beginSheetModalForWindow:[self window]
				  completionHandler:completion];
#endif
}

- (IBAction)sendToDevice:(id)sender {
	id delegate = [NSApp delegate];
	if ([delegate respondsToSelector:@selector(sendStringsFilesToDevice:)]) {
		[delegate sendStringsFilesToDevice:[stringsFiles arrangedObjects]];
	}

}

#pragma mark -
#pragma mark tableView delegate
// ----------------------------------------------------------------------------------------------------
// tableView delegate
// ----------------------------------------------------------------------------------------------------

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)row {
	if ([[aTableColumn identifier] isEqualToString:@"index"]) {
		return [NSString stringWithFormat:@"%i", row + 1];
	} else {
		return nil;
	}
}

- (void)tableView:(NSTableView *)tv willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
	if ([cell isKindOfClass:[FRUntranslatedCountCell class]]) {
		id object = [[stringsFiles arrangedObjects] objectAtIndex:row];
		if ([object respondsToSelector:@selector(untranslatedCount)]) {
			[cell setUntranslated:[object untranslatedCount]];
		}
		else { [cell setUntranslated:0]; }
	}
}

- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex {
	[self saveSelectedStringsFile];
	return TRUE;
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	[self loadTextView];
}


#pragma mark -
#pragma mark text delegate
// ----------------------------------------------------------------------------------------------------
// text delegate
// ----------------------------------------------------------------------------------------------------

- (void)textDidChange:(NSNotification *)aNotification {
	[saveTimer invalidate];
	saveTimer = [NSTimer scheduledTimerWithTimeInterval:kSaveTimeout
												 target:self selector:@selector(saveSelectedStringsFile)
											   userInfo:nil repeats:NO];
}

- (void)processEditing:(NSNotification *)notification {
	NSTextStorage *contents = [textView textStorage];
	[self colorTextInRange:[contents editedRange] ofString:contents];
}

- (void)colorTextInRange:(NSRange)range ofString:(NSMutableAttributedString *)attributedString {
	NSString *string = [attributedString string];
	NSUInteger stringLength = [string length];
	NSRange subrange = NSMakeRange(range.location, 0);
	
	// find the start of the string
	while (subrange.location > 0) {
		char character = [string characterAtIndex:subrange.location-1];
		if (character == '\n') { break; }
		else {
			subrange.location--;
			subrange.length++;
		}
	}
		
	// find the ends of strings and add attributes. stop once we've gotten past the end of the requested range and
	// the add attributes method doesn't request continuing to the next line.
	while (subrange.location + subrange.length < stringLength) {
		BOOL shouldContinue = FALSE;
		char character = [string characterAtIndex:subrange.location + subrange.length];
		subrange.length++;
		
		if (character == '\n') {
			[self addAttributesForLineInRange:subrange ofString:attributedString andContinue:&shouldContinue];
			subrange.location += subrange.length;
			subrange.length = 0;
			shouldContinue = shouldContinue || subrange.location + subrange.length < range.location + range.length;
			if (shouldContinue == FALSE) {
				break;
			}
		}
	}
}

- (void)addAttributesForLineInRange:(NSRange)range ofString:(NSMutableAttributedString *)attributedString
						andContinue:(BOOL *)shouldContinue {
	
	NSAssert(range.length >= 1, @"Expected range to have a length");
	NSParameterAssert(shouldContinue);
	
	NSString *string = [attributedString string];
	BOOL colored = FALSE;

	// remove background color
	[attributedString removeAttribute:NSBackgroundColorAttributeName range:range];

	if ([string characterAtIndex:range.location + range.length - 1] == '\n') {
		range.length--;
	}
	
	if (range.length) {
		if (range.length >= 4) { // check for comment. needs at least: /**/
			char startSlash = [string characterAtIndex:range.location + 0];
			char startStar = [string characterAtIndex:range.location + 1];
			char endSlash = [string characterAtIndex:range.location + range.length - 1];
			char endStar = [string characterAtIndex:range.location + range.length - 2];
			if (startSlash == '/' && startStar == '*' && endSlash == '/' && endStar == '*') {
				NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
											COMMENT, NSForegroundColorAttributeName, nil];
				[attributedString addAttributes:attributes range:range];
				colored = TRUE;
				*shouldContinue = TRUE;
			}
		}
		
		if (range.length >= 8) { // check for string. needs at least: "" = "";
			char startQuote = [string characterAtIndex:range.location + 0];
			char endSemicolon = [string characterAtIndex:range.location + range.length - 1];
			char endQuote = [string characterAtIndex:range.location + range.length - 2];
			if (startQuote == '"' && endQuote == '"' && endSemicolon == ';') {
				
				NSString *equalityCheck = @"\" = \"";
				NSRange equalityRange = [string rangeOfString:equalityCheck options:0 range:range];
				if (equalityRange.location != NSNotFound) {
					equalityRange.location += 1;
					equalityRange.length -= 2;

					NSRange rangeNoSemicolon = range;
					NSRange lhs = range;
					NSRange rhs = range;
					rangeNoSemicolon.length -= 1;
					lhs.length = equalityRange.location - rangeNoSemicolon.location;
					rhs.location = equalityRange.location + equalityRange.length;
					rhs.length =
						(rangeNoSemicolon.location + rangeNoSemicolon.length) -
						(equalityRange.location + equalityRange.length);
					
					NSString *rhsString = [string substringWithRange:rhs];
					BOOL translated = [string compare:rhsString options:0 range:lhs] != NSOrderedSame;
					if (!translated) {
						// go back through the previous line and look for a ==
						NSUInteger thisLineStart = range.location;
						NSRange previousLine = NSMakeRange(NSNotFound, 0);
						if (thisLineStart > 0) {
							previousLine = [string rangeOfString:@"\n" options:NSBackwardsSearch
														   range:NSMakeRange(0, thisLineStart-1)];
						}
						if (previousLine.location != NSNotFound) {
							NSUInteger previousLineStart = previousLine.location + previousLine.length;
							NSRange search = NSMakeRange(previousLineStart, thisLineStart - previousLineStart);
							translated = [string rangeOfString:@"==" options:0 range:search].location != NSNotFound;
						}
						
					}

					NSColor *lhsColor = TRANSLATION_COMPLETE;
					NSColor *rhsColor = TRANSLATION_COMPLETE;
					
					if (!translated) {
						rhsColor = TRANSLATION_INCOMPLETE;
					}

					NSDictionary *attributes = nil;
					attributes = [NSDictionary dictionaryWithObjectsAndKeys:
								  TRANSLATION, NSForegroundColorAttributeName, nil];
					[attributedString addAttributes:attributes range:range];
					attributes = [NSDictionary dictionaryWithObjectsAndKeys:
								  rhsColor, NSForegroundColorAttributeName, nil];
					[attributedString addAttributes:attributes range:rhs];
					attributes = [NSDictionary dictionaryWithObjectsAndKeys:
								  lhsColor, NSForegroundColorAttributeName, nil];
					[attributedString addAttributes:attributes range:lhs];
					colored = TRUE;
				}
			}
		}
	}
	
	if (!colored) {
		NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
									UNKNOWN, NSForegroundColorAttributeName,
									UNKNOWN_BACKGROUND, NSBackgroundColorAttributeName, nil];
		[attributedString addAttributes:attributes range:range];
	}
}

@end

//
//  TOAppRater.m
//
//  Copyright 2014-2020 Timothy Oliver. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
//  IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "TOAppRater.h"
#import <UIKit/UIKit.h>
#import <StoreKit/StoreKit.h>

/** The key values used to persist our latest state in user defaults. */
NSString * const kTOAppRaterNumberOfRatingsSettingsKey = @"TOAppRater.NumberOfRatings";
NSString * const kTOAppRaterLastUpdatedSettingsKey     = @"TOAppRater.LastUpdatedDate";
NSString * const kTOAppRaterLastPromptedSettingsKey    = @"TOAppRater.LastPromptedDate";

/** The amount of time between each query to the App Store to refresh the ratings count. */
NSTimeInterval const kTOAppRaterAppStoreQueryTimeInterval = (24.0f * 60.0f * 60.0f);

/** The amount of time between each prompt to the user to submit an in-app review. */
NSTimeInterval const kTOAppRaterReviewPromptTimeInterval = (24.0f * 60.0f * 60.0f);

/** The App Store API call to retrieve the number of reviews. */
NSString * const kTOAppRaterSearchAPIURL = @"https://itunes.apple.com/lookup?id={APPID}&country={COUNTRY}";

/** The App Store app URL straight to an app's review page. */
NSString * const kTOAppRaterReviewURL = @"https://itunes.apple.com/app/id{APPID}?action=write-review";

/** The NSNotification that will be broadcast when the value has been updated. */
NSString * const TOAppRaterDidUpdateNotification = @"TOAppRaterDidUpdateNotification";

static NSString *_appID; /* App Store ID for this app. */
static NSString *_localizedMessage = nil; /* Cached copy of the localized message. */

@implementation TOAppRater

+ (void)setAppID:(NSString *)appID
{
    _appID = appID;
}

+ (NSString *)appID { return _appID; }

+ (BOOL)timeIntervalHasPassedForKey:(NSString *)settingsKey timeInterval:(NSTimeInterval)timeInterval
{
    // Get the current time, and compare it to the stored time offset by the interval
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval previousUpdateTime = [[NSUserDefaults standardUserDefaults] floatForKey:settingsKey];
    return (currentTime >= (previousUpdateTime + timeInterval) - FLT_EPSILON);
}

+ (NSURL *)searchAPIURL
{
    NSString *countryCode = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    NSString *searchURL = kTOAppRaterSearchAPIURL;
    searchURL = [searchURL stringByReplacingOccurrencesOfString:@"{APPID}" withString:_appID];
    searchURL = [searchURL stringByReplacingOccurrencesOfString:@"{COUNTRY}" withString:countryCode ? countryCode : @"US"];
    return [NSURL URLWithString:searchURL];
}

+ (void)updateRatingsCountWithAPIData:(NSData *)data
{
    // Attempt to parse the data into a readable dictionary
    NSError *error = nil;
    NSDictionary *searchResults = [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:&error];
    if (searchResults == nil || error != nil) {
        #ifdef DEBUG
        NSLog(@"TOAppRater: %@", error.localizedDescription);
        #endif
        return;
    }

    // Extract the number of ratings, or return out if the value wasn't found
    NSDictionary *results = [searchResults[@"results"] firstObject];
    NSNumber *numberOfRatings = results[@"userRatingCountForCurrentVersion"];
    if (numberOfRatings == nil) {
        #ifdef DEBUG
        NSLog(@"TOAppRater: Was unable to locate number of ratings in JSON payload. The response was malformed.");
        #endif
        return;
    }
    
    // Update the state on the main queue
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        // Clear the cached localized message, so a new one will be generated next time
        _localizedMessage = nil;

        // Update user defaults
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setInteger:numberOfRatings.integerValue forKey:kTOAppRaterNumberOfRatingsSettingsKey];
        [defaults setFloat:currentTime forKey:kTOAppRaterLastUpdatedSettingsKey];

        // Broadcast that there was an update
        [[NSNotificationCenter defaultCenter] postNotificationName:TOAppRaterDidUpdateNotification object:nil];
    }];
}

+ (void)checkForUpdates
{
    // Throw an inconsistency exception if this was called without setting an ID.
    if (_appID == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"An app ID must be specified before calling this method."];
    }
    
    // Don't proceed if a sufficient amount of time hasn't passed yet.
    if ([[self class] timeIntervalHasPassedForKey:kTOAppRaterLastUpdatedSettingsKey
                                     timeInterval:kTOAppRaterAppStoreQueryTimeInterval] == NO) { return; }

    // Generate a URL with the appropriate parameters provided
    NSURL *url = [[self class] searchAPIURL];
    
    id completionBlock = ^(NSData *data, NSURLResponse *response, NSError *error) {
        // Print an error if the API call didn't succeed
        if (error || data.length == 0) {
            #ifdef DEBUG
            NSLog(@"TOAppRater: Unable to load JSON data from iTunes Search API - %@", error.localizedDescription);
            #endif
            return;
        }

        // Parse the JSON and update the state as needed
        [[self class] updateRatingsCountWithAPIData:data];
    };
    
    // Perform the API call
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:completionBlock] resume];
}

+ (NSString *)localizedUsersRatedString
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // If the initial request hasn't happened yet, simply return nil for now
    NSNumber *numberOfRatingsObject = [defaults objectForKey:kTOAppRaterNumberOfRatingsSettingsKey];
    if (numberOfRatingsObject == nil) {
        return nil;
    }
    
    // If we already have a cached version of the message, just return that
    if (_localizedMessage) {
        return _localizedMessage;
    }
    
    // Extract the number of ratings
    NSInteger numberOfRatings = MAX(numberOfRatingsObject.integerValue, 0);
    
    // Depending on the number of ratings, pick the appropriate string.
    NSString *localizableKey = nil;
    if (numberOfRatings == 0)       { localizableKey = @"TOAppRater.NoRatingsYet"; }
    else if (numberOfRatings == 1)  { localizableKey = @"TOAppRater.OneRating"; }
    else if (numberOfRatings < 50)  { localizableKey = @"TOAppRater.LowRatingsCount"; }
    else { localizableKey = @"TOAppRater.HighRatingsCount"; }
    
    // Convert the key to the localized string, and insert the number if needed
    NSBundle *resourceBundle = [[self class] bundle];
    NSString *localizedString = NSLocalizedStringFromTableInBundle(localizableKey,
                                                                   @"TOAppRaterLocalizable",
                                                                   resourceBundle, nil);
    NSString *ratedString = [NSString stringWithFormat:localizedString, numberOfRatings];
    
    // Cache this string so we can refer to it next time.
    _localizedMessage = ratedString;
    
    return ratedString;
}

+ (SKStoreProductViewController *)productViewController
{
    SKStoreProductViewController *controller = [[SKStoreProductViewController alloc] init];
    [controller loadProductWithParameters:@{SKStoreProductParameterITunesItemIdentifier: @(_appID.integerValue)}
                          completionBlock:nil];
    return controller;
}

+ (void)rateApp
{
#if TARGET_IPHONE_SIMULATOR
    NSLog(@"TOAppRater: Cannot open App Store on iOS Simulator");
    return;
#else
    NSString *rateURLString = [kTOAppRaterReviewURL stringByReplacingOccurrencesOfString:@"{APPID}" withString:_appID];
    NSURL *rateURL = [NSURL URLWithString:rateURLString];
    
    UIApplication *application = [UIApplication sharedApplication];
    if (@available(iOS 10.0, *)) {
        [application openURL:rateURL options:@{} completionHandler:nil];
    }
    else {
        #pragma GCC diagnostic push
        #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        [application openURL:rateURL];
        #pragma GCC diagnostic pop
    }
#endif
}

+ (void)promptForRating
{
    // Only allow on iOS 10.3 and above
    if (@available(iOS 10.3, *)) { }
    else { return; }

    // While this is the officially recommended way of asking for reviews by Apple,
    // certain users have given 1-star reviews because it prompted too often.
    // As such, we store the last time the prompt was attempted, and space it out
    // over a much longer time period.

    // Don't continue if we haven't passed the time frame yet
    if ([[self class] timeIntervalHasPassedForKey:kTOAppRaterLastPromptedSettingsKey
                                     timeInterval:kTOAppRaterReviewPromptTimeInterval] == NO) { return; }

    // Perform the review prompt
    if (@available(iOS 10.3, *)) {
        [SKStoreReviewController requestReview];
    }

    // Save the current time so we can compare to that one next time.
    [[NSUserDefaults standardUserDefaults] setFloat:[[NSDate date] timeIntervalSince1970]
                                              forKey:kTOAppRaterLastPromptedSettingsKey];
}

+ (NSBundle *)bundle
{
    // Depending on how this library was imported, we need to determine the resource bundle
    // where its localizable strings are stored.
    NSBundle *classBundle = [NSBundle bundleForClass:self.class];
    NSURL *resourceBundleURL = [classBundle URLForResource:@"TOAppRaterBundle" withExtension:@"bundle"];
    
    // If we were able to determine the bundle URL, create a bundle off it
    NSBundle *resourceBundle = nil;
    if (resourceBundleURL) { resourceBundle = [[NSBundle alloc] initWithURL:resourceBundleURL]; }
    else { resourceBundle = classBundle; }
    
    return resourceBundle;
}

@end

// ApolloSubredditSidebar.xm
//
// Fleshes out Apollo's subreddit Sidebar screen (SubredditSidebarViewController)
// with the structured content new-Reddit shows, all sourced from one
// /r/{sub}/api/widgets fetch:
//
//   • Stats header  — the id-card's subscriber + currently-viewing counts, using
//                     the subreddit's OWN custom labels ("Season Ticket Holders"
//                     / "In Attendance", "Members" / "Online", …). Replaces
//                     Apollo's hardcoded 2-stat "SUBSCRIBERS / ACTIVE" header.
//   • Search by Flair — colored flair chips (folded in from the flair feature).
//   • Related Communities — community-list widgets: each linked sub with its
//                     icon + subscriber count, tap opens the sub.
//   • (Stage B) link-button groups, menu/bookmarks, table-of-contents tabs.
//
// Architecture: a registry-based injector wraps the sidebar scrollNode's
// layoutSpecBlock ONCE and composes an ordered array of section nodes above the
// original spec. The scrollNode is automaticallyManagesContentSize, so Texture
// owns all sizing — no frame math. (Mirrors the proven pattern from the flair
// feature, generalized to many sections.)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "ApolloCommon.h"
#import "ApolloState.h"

#pragma mark - Texture interfaces (runtime-bound)

typedef NS_ENUM(unsigned char, ApolloSBStackDirection) {
    ApolloSBStackVertical = 0,
    ApolloSBStackHorizontal = 1,
};
// ASStackLayoutJustifyContent
enum { ApolloSBJustifyStart = 0, ApolloSBJustifyCenter = 1, ApolloSBJustifyEnd = 2, ApolloSBJustifySpaceBetween = 3, ApolloSBJustifySpaceAround = 4 };
// ASStackLayoutAlignItems
enum { ApolloSBAlignStart = 0, ApolloSBAlignEnd = 1, ApolloSBAlignCenter = 2, ApolloSBAlignStretch = 3 };

static const NSUInteger kApolloSBControlEventTouchUpInside = 1 << 4;
static const NSUInteger kApolloSBFlexWrapWrap = 1;

// ASSizeRange
struct CDStruct_90e057aa { CGSize min; CGSize max; };

@class ASLayoutSpec;

// ASDimension { ASDimensionUnit unit (NSInteger: 0=auto,1=points,2=fraction); CGFloat value; }
typedef struct { NSInteger unit; CGFloat value; } ApolloSBDimension;
static inline ApolloSBDimension ApolloSBPoints(CGFloat v) { return (ApolloSBDimension){1, v}; }
static inline ApolloSBDimension ApolloSBAutoDim(void) { return (ApolloSBDimension){0, 0}; }

@interface ApolloSBLayoutElementStyle : NSObject
@property (nonatomic) CGSize preferredSize;
@property (nonatomic) CGFloat flexGrow;
@property (nonatomic) CGFloat flexShrink;
@property (nonatomic) ApolloSBDimension maxHeight;
@end

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (void)setNeedsLayout;
- (UIView *)view;
- (ApolloSBLayoutElementStyle *)style;
@property (nonatomic) BOOL automaticallyManagesSubnodes;
@property (nonatomic) BOOL clipsToBounds;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nullable, nonatomic, copy) ASLayoutSpec *(^layoutSpecBlock)(ASDisplayNode *node, struct CDStruct_90e057aa constrainedSize);
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASControlNode : ASDisplayNode
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)controlEvents;
@end

@interface ASButtonNode : ASControlNode
- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(NSUInteger)state;
@property (nonatomic) UIEdgeInsets contentEdgeInsets;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nullable, nonatomic, strong) UIImage *image;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic, copy) UIColor *placeholderColor;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloSBStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

#pragma mark - Class accessors

static Class ApolloSBNodeClass(void)    { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASDisplayNode"); }); return c; }
static Class ApolloSBTextClass(void)    { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASTextNode"); }); return c; }
static Class ApolloSBButtonClass(void)  { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASButtonNode"); }); return c; }
static Class ApolloSBControlClass(void) { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASControlNode"); }); return c; }
static Class ApolloSBImageClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASNetworkImageNode"); }); return c; }
static Class ApolloSBStackClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASStackLayoutSpec"); }); return c; }
static Class ApolloSBInsetClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASInsetLayoutSpec"); }); return c; }

#pragma mark - Swift ivar helpers

static NSString *ApolloSBDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) return nil;
    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";
        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }
    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF"); });
    return sBridge ? sBridge(w0, w1) : nil;
}

static ptrdiff_t ApolloSBIvarOffset(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static id ApolloSBReadObjectIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSBIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return (__bridge id)(*(void **)(base + offset));
}

static NSString *ApolloSBReadSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSBIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return ApolloSBDecodeSwiftString(*(uint64_t *)(base + offset), *(uint64_t *)(base + offset + 0x08));
}

#pragma mark - Small utilities

static UIColor *ApolloSBColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 4) return nil;
    NSString *cleaned = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (cleaned.length != 6) return nil;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:cleaned] scanHexInt:&value]) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:1.0];
}

static NSString *ApolloSBFormatCount(long long n) {
    if (n >= 1000000) return [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
    if (n >= 1000)    return [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    return [NSString stringWithFormat:@"%lld", n];
}

static NSString *ApolloSBString(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }
static long long ApolloSBLongLong(id v) { return [v isKindOfClass:[NSNumber class]] ? [v longLongValue] : 0; }

// Strip subreddit-emoji :tokens: from flair / label text for display.
static NSString *ApolloSBStripEmojiTokens(NSString *raw) {
    if (raw.length == 0) return raw;
    static NSRegularExpression *regex; static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+-]+:" options:0 error:NULL]; });
    NSString *s = [regex stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s containsString:@"  "]) s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return s.length > 0 ? s : raw;
}

#pragma mark - Tap targets

// Generic link tap: reddit hosts route natively; everything else opens Apollo's
// in-app web browser.
@interface ApolloSBLinkTapTarget : NSObject
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, weak) UIViewController *hostVC;
- (void)linkTapped:(id)sender;
@end
@implementation ApolloSBLinkTapTarget
- (void)linkTapped:(id)sender {
    NSURL *url = self.urlString.length ? [NSURL URLWithString:self.urlString] : nil;
    if (!url) return;
    ApolloLog(@"[Sidebar] link tapped -> %@", self.urlString);
    if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
        if (self.hostVC) ApolloPresentWebURLFromViewController(self.hostVC, url);
    }
}
@end

// Flair chip tap: builds a flair_name:"…" search restricted to the sub.
@interface ApolloSBFlairTapTarget : NSObject
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *searchText;
- (void)chipTapped:(id)sender;
@end
@implementation ApolloSBFlairTapTarget
- (void)chipTapped:(id)sender {
    if (self.subredditName.length == 0 || self.searchText.length == 0) return;
    NSURLComponents *c = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/search", self.subredditName]];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"flair_name:\"%@\"", self.searchText]],
        [NSURLQueryItem queryItemWithName:@"restrict_sr" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"new"],
    ];
    if (c.URL) ApolloRouteResolvedURLViaApolloScheme(c.URL);
}
@end

// Table-of-contents chip tap: scrolls the sidebar to the target section.
@interface ApolloSBTOCTapTarget : NSObject
@property (nonatomic, weak) ASDisplayNode *scrollNode;
@property (nonatomic, weak) ASDisplayNode *targetSection;
- (void)tocTapped:(id)sender;
@end
@implementation ApolloSBTOCTapTarget
- (void)tocTapped:(id)sender {
    ASDisplayNode *scroll = self.scrollNode, *target = self.targetSection;
    if (!scroll || !target) return;
    UIView *sv = scroll.view, *tv = target.view;
    if (![sv isKindOfClass:[UIScrollView class]] || !tv || !tv.superview) return;
    UIScrollView *scrollView = (UIScrollView *)sv;
    [scrollView layoutIfNeeded];
    CGRect r = [tv.superview convertRect:tv.frame toView:scrollView]; // content-space y
    CGFloat top = scrollView.adjustedContentInset.top;
    CGFloat minY = -top;
    CGFloat maxY = MAX(minY, scrollView.contentSize.height - scrollView.bounds.size.height + scrollView.adjustedContentInset.bottom);
    CGFloat y = MAX(minY, MIN(r.origin.y - top - 8.0, maxY));
    [scrollView setContentOffset:CGPointMake(0, y) animated:YES];
}
@end

// "Show more"/"Show less" toggle for the (height-clipped) description bio.
static const CGFloat kApolloSBBioCollapsedHeight = 52.0; // ~2 lines, then "Show more"
static char kApolloSBBioExpandedKey; // @YES (expanded) on the markdown node, else absent

@interface ApolloSBBioToggleTarget : NSObject
@property (nonatomic, weak) ASDisplayNode *markdownNode;
@property (nonatomic, weak) ASDisplayNode *scrollNode;
@property (nonatomic, weak) ASButtonNode *button;
- (void)toggle:(id)sender;
@end
@implementation ApolloSBBioToggleTarget
- (void)toggle:(id)sender {
    ASDisplayNode *md = self.markdownNode, *scroll = self.scrollNode;
    if (!md) return;
    BOOL expanded = (objc_getAssociatedObject(md, &kApolloSBBioExpandedKey) == nil); // was collapsed -> expand
    objc_setAssociatedObject(md, &kApolloSBBioExpandedKey, expanded ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    md.style.maxHeight = expanded ? ApolloSBAutoDim() : ApolloSBPoints(kApolloSBBioCollapsedHeight);
    [self.button setTitle:(expanded ? @"Show less" : @"Show more")
                 withFont:[UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold]
                withColor:UIColor.secondaryLabelColor forState:0];
    [md setNeedsLayout];
    [scroll setNeedsLayout];
}
@end

#pragma mark - Widgets fetch (raw root dict, cached)

static NSString *ApolloSBEscapedSubreddit(NSString *name) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [name stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: name;
}

static NSCache<NSString *, NSDictionary *> *ApolloSBWidgetsCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    return cache;
}

static void ApolloSBFetchWidgets(NSString *subredditName, void (^completion)(NSDictionary *root)) {
    if (subredditName.length == 0) { completion(nil); return; }
    NSString *cacheKey = subredditName.lowercaseString;
    NSDictionary *cached = [ApolloSBWidgetsCache() objectForKey:cacheKey];
    if (cached) { completion(cached.count ? cached : nil); return; }

    NSString *escaped = ApolloSBEscapedSubreddit(subredditName);
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/widgets?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/api/widgets.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    if (token.length > 0) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloSidebar/1.0") forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        ApolloLog(@"[Sidebar] widgets fetch r/%@ status=%ld items=%lu err=%@",
                  subredditName, (long)status, (unsigned long)[root[@"items"] count], error.localizedDescription ?: @"nil");
        if (root.count) {
            [ApolloSBWidgetsCache() setObject:root forKey:cacheKey];
        } else if (status == 200) {
            [ApolloSBWidgetsCache() setObject:@{} forKey:cacheKey]; // cache the miss
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(root); });
    }] resume];
}

#pragma mark - Section node builders

static const CGFloat kApolloSBSectionTitleSize = 20.0;
static const CGFloat kApolloSBCommunityIconDiameter = 34.0;

static ASTextNode *ApolloSBMakeTitleNode(NSString *title) {
    ASTextNode *node = [[ApolloSBTextClass() alloc] init];
    node.attributedText = [[NSAttributedString alloc] initWithString:(title ?: @"") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:kApolloSBSectionTitleSize weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    return node;
}

// --- Stats (id-card) -------------------------------------------------------

// One stat column: small grey uppercase label on top, big bold count below
// (matching the native header it replaces).
static ASDisplayNode *ApolloSBMakeStatColumn(NSString *label, NSString *value) {
    ASTextNode *labelNode = [[ApolloSBTextClass() alloc] init];
    labelNode.attributedText = [[NSAttributedString alloc] initWithString:[label uppercaseString] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
        NSKernAttributeName: @(0.4),
    }];
    ASTextNode *countNode = [[ApolloSBTextClass() alloc] init];
    countNode.attributedText = [[NSAttributedString alloc] initWithString:(value ?: @"—") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    ASDisplayNode *col = [[ApolloSBNodeClass() alloc] init];
    col.automaticallyManagesSubnodes = YES;
    col.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:3.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignCenter
                                                         children:@[labelNode, countNode]];
    };
    return col;
}

static ASDisplayNode *ApolloSBBuildStatsSection(NSArray<ASDisplayNode *> *columns) {
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:12.0
                                                   justifyContent:ApolloSBJustifySpaceAround alignItems:ApolloSBAlignCenter
                                                         children:columns];
    };
    return container;
}

// --- Flair -----------------------------------------------------------------

static ASDisplayNode *ApolloSBBuildFlairSection(NSString *title, NSArray *order, NSDictionary *templates,
                                                NSString *subredditName, NSMutableArray *tapTargets) {
    NSMutableArray *chipNodes = [NSMutableArray array];
    for (NSString *templateID in order) {
        NSDictionary *tpl = [templates[templateID] isKindOfClass:[NSDictionary class]] ? templates[templateID] : nil;
        NSString *text = ApolloSBString(tpl[@"text"]);
        if (text.length == 0) continue;
        UIColor *background = ApolloSBColorFromHex(tpl[@"backgroundColor"]);
        BOOL lightText = [ApolloSBString(tpl[@"textColor"]) isEqualToString:@"light"];
        UIColor *textColor = background ? (lightText ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0]) : UIColor.labelColor;

        ASButtonNode *chip = [[ApolloSBButtonClass() alloc] init];
        [chip setTitle:ApolloSBStripEmojiTokens(text) withFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] withColor:textColor forState:0];
        chip.backgroundColor = background ?: [UIColor colorWithWhite:0.5 alpha:0.25];
        chip.cornerRadius = 13.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(5.0, 12.0, 5.0, 12.0);

        ApolloSBFlairTapTarget *target = [[ApolloSBFlairTapTarget alloc] init];
        target.subredditName = subredditName;
        target.searchText = text;
        [tapTargets addObject:target];
        [chip addTarget:target action:@selector(chipTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
        [chipNodes addObject:chip];
    }
    if (chipNodes.count == 0) return nil;

    ASTextNode *titleNode = ApolloSBMakeTitleNode(title.length ? title : @"Search by Flair");
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *cloud = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:chipNodes];
        cloud.flexWrap = kApolloSBFlexWrapWrap;
        cloud.lineSpacing = 8.0;
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:12.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:@[titleNode, cloud]];
    };
    return container;
}

// --- Community list (Related Communities) ----------------------------------

static ASControlNode *ApolloSBBuildCommunityRow(NSDictionary *community, UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSString *name = ApolloSBString(community[@"name"]);
    if (name.length == 0) return nil;
    NSString *iconURL = ApolloSBString(community[@"communityIcon"]) ?: ApolloSBString(community[@"iconUrl"]);
    long long subs = ApolloSBLongLong(community[@"subscribers"]);

    ASNetworkImageNode *icon = [[ApolloSBImageClass() alloc] init];
    if (iconURL.length) icon.URL = [NSURL URLWithString:iconURL];
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.clipsToBounds = YES;
    icon.cornerRadius = kApolloSBCommunityIconDiameter / 2.0;
    icon.placeholderColor = [UIColor secondarySystemFillColor];
    icon.style.preferredSize = CGSizeMake(kApolloSBCommunityIconDiameter, kApolloSBCommunityIconDiameter);

    ASTextNode *nameNode = [[ApolloSBTextClass() alloc] init];
    nameNode.attributedText = [[NSAttributedString alloc] initWithString:[@"r/" stringByAppendingString:name] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    ASTextNode *subsNode = [[ApolloSBTextClass() alloc] init];
    subsNode.attributedText = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ members", ApolloSBFormatCount(subs)] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
    }];

    ApolloSBLinkTapTarget *target = [[ApolloSBLinkTapTarget alloc] init];
    target.urlString = [NSString stringWithFormat:@"https://www.reddit.com/r/%@", name];
    target.hostVC = hostVC;
    [tapTargets addObject:target];

    ASControlNode *row = [[ApolloSBControlClass() alloc] init];
    row.automaticallyManagesSubnodes = YES;
    [row addTarget:target action:@selector(linkTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
    row.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *textCol = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:1.0
                                                                         justifyContent:ApolloSBJustifyCenter alignItems:ApolloSBAlignStart children:@[nameNode, subsNode]];
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:10.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignCenter children:@[icon, textCol]];
    };
    return row;
}

static ASDisplayNode *ApolloSBBuildCommunityListSection(NSString *title, NSArray *communities, UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *c in communities) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        ASControlNode *row = ApolloSBBuildCommunityRow(c, hostVC, tapTargets);
        if (row) [rows addObject:row];
    }
    if (rows.count == 0) return nil;

    ASTextNode *titleNode = ApolloSBMakeTitleNode(title.length ? title : @"Related Communities");
    NSMutableArray *children = [NSMutableArray arrayWithObject:titleNode];
    [children addObjectsFromArray:rows];

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:12.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
    };
    return container;
}

// --- Link-button groups (button + menu widgets) ----------------------------

static ASButtonNode *ApolloSBMakeLinkPill(NSString *text, NSString *urlString, UIColor *fill, UIColor *textColor,
                                          UIViewController *hostVC, NSMutableArray *tapTargets) {
    ASButtonNode *btn = [[ApolloSBButtonClass() alloc] init];
    [btn setTitle:(text ?: @"") withFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
        withColor:(textColor ?: UIColor.labelColor) forState:0];
    btn.backgroundColor = fill ?: [UIColor colorWithWhite:0.5 alpha:0.18];
    btn.cornerRadius = 12.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(11.0, 14.0, 11.0, 14.0);

    ApolloSBLinkTapTarget *t = [[ApolloSBLinkTapTarget alloc] init];
    t.urlString = urlString;
    t.hostVC = hostVC;
    [tapTargets addObject:t];
    [btn addTarget:t action:@selector(linkTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
    return btn;
}

// links: array of {text, url, fill?(UIColor), textColor?(UIColor)}
static ASDisplayNode *ApolloSBBuildLinkGroupSection(NSString *title, NSArray<NSDictionary *> *links,
                                                    UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSMutableArray *pills = [NSMutableArray array];
    for (NSDictionary *link in links) {
        NSString *text = ApolloSBString(link[@"text"]);
        NSString *url = ApolloSBString(link[@"url"]);
        if (text.length == 0 || url.length == 0) continue;
        UIColor *fill = [link[@"fill"] isKindOfClass:[UIColor class]] ? link[@"fill"] : nil;
        UIColor *tc = [link[@"textColor"] isKindOfClass:[UIColor class]] ? link[@"textColor"] : nil;
        [pills addObject:ApolloSBMakeLinkPill(text, url, fill, tc, hostVC, tapTargets)];
    }
    if (pills.count == 0) return nil;

    NSMutableArray *children = [NSMutableArray array];
    if (title.length) [children addObject:ApolloSBMakeTitleNode(title)];
    [children addObjectsFromArray:pills];

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:8.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
    };
    return container;
}

static NSArray *ApolloSBLinksFromButtonWidget(NSDictionary *w) {
    NSMutableArray *links = [NSMutableArray array];
    for (NSDictionary *b in (NSArray *)w[@"buttons"]) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = ApolloSBString(b[@"text"]);
        NSString *url = ApolloSBString(b[@"url"]);
        if (text.length == 0 || url.length == 0) continue;
        NSMutableDictionary *d = [@{ @"text": text, @"url": url } mutableCopy];
        UIColor *fill = ApolloSBColorFromHex(ApolloSBString(b[@"fillColor"]) ?: ApolloSBString(b[@"color"]));
        UIColor *tc = ApolloSBColorFromHex(ApolloSBString(b[@"textColor"]));
        if (fill) d[@"fill"] = fill;
        if (tc) d[@"textColor"] = tc;
        [links addObject:d];
    }
    return links;
}

static NSArray *ApolloSBLinksFromMenuWidget(NSDictionary *w) {
    NSMutableArray *links = [NSMutableArray array];
    for (NSDictionary *e in (NSArray *)w[@"data"]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        if ([e[@"children"] isKindOfClass:[NSArray class]]) {
            for (NSDictionary *c in e[@"children"]) {
                if (![c isKindOfClass:[NSDictionary class]]) continue;
                NSString *text = ApolloSBString(c[@"text"]), *url = ApolloSBString(c[@"url"]);
                if (text.length && url.length) [links addObject:@{ @"text": text, @"url": url }];
            }
        } else {
            NSString *text = ApolloSBString(e[@"text"]), *url = ApolloSBString(e[@"url"]);
            if (text.length && url.length) [links addObject:@{ @"text": text, @"url": url }];
        }
    }
    return links;
}

#pragma mark - Registry-based multi-section injector

@interface ApolloSBSection : NSObject
@property (nonatomic) NSInteger order;
@property (nonatomic, strong) ASDisplayNode *node;
@property (nonatomic) UIEdgeInsets insets;
@property (nonatomic, copy) NSString *tocTitle; // nil => not shown in the table-of-contents
@end
@implementation ApolloSBSection
@end

static char kApolloSBSectionsKey;     // NSMutableArray<ApolloSBSection*> on scrollNode
static char kApolloSBWrappedKey;      // BOOL: layoutSpecBlock already wrapped
static char kApolloSBTapTargetsKey;   // NSMutableArray on the VC (retains tap targets)
static char kApolloSBInstalledKey;    // BOOL on the VC
static char kApolloSBCollapseHeaderKey; // BOOL on the header node

// Apollo's original spec (collapsed stats header + description/bio markdown) is
// spliced into the section stack at this order — just under our stats (order 0),
// above the TOC (30) and all widget sections.
static const NSInteger kApolloSBOrigSpecOrder = 25;

static void ApolloSBInstallSection(ASDisplayNode *scrollNode, ApolloSBSection *section) {
    if (!scrollNode || !scrollNode.layoutSpecBlock || !section.node) return;

    NSMutableArray *sections = objc_getAssociatedObject(scrollNode, &kApolloSBSectionsKey);
    if (!sections) {
        sections = [NSMutableArray array];
        objc_setAssociatedObject(scrollNode, &kApolloSBSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [sections addObject:section];
    [sections sortUsingComparator:^NSComparisonResult(ApolloSBSection *a, ApolloSBSection *b) {
        return a.order < b.order ? NSOrderedAscending : (a.order > b.order ? NSOrderedDescending : NSOrderedSame);
    }];
    [scrollNode addSubnode:section.node];

    if (![objc_getAssociatedObject(scrollNode, &kApolloSBWrappedKey) boolValue]) {
        objc_setAssociatedObject(scrollNode, &kApolloSBWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ASLayoutSpec *(^origBlock)(ASDisplayNode *, struct CDStruct_90e057aa) = scrollNode.layoutSpecBlock;
        __weak ASDisplayNode *weakScroll = scrollNode;
        scrollNode.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *node, struct CDStruct_90e057aa cs) {
            ASDisplayNode *strongScroll = weakScroll;
            NSMutableArray *children = [NSMutableArray array];
            ASLayoutSpec *origSpec = origBlock ? origBlock(node, cs) : nil; // Apollo's (collapsed) header + description/bio
            BOOL origInserted = NO;
            for (ApolloSBSection *s in (NSArray *)objc_getAssociatedObject(strongScroll, &kApolloSBSectionsKey)) {
                if (!s.node) continue;
                // The bio/description (origSpec) sits in the bio slot — under the stats + TOC.
                if (!origInserted && origSpec && s.order > kApolloSBOrigSpecOrder) {
                    [children addObject:origSpec];
                    origInserted = YES;
                }
                [children addObject:[ApolloSBInsetClass() insetLayoutSpecWithInsets:s.insets child:s.node]];
            }
            if (origSpec && !origInserted) [children addObject:origSpec];
            return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:0.0
                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
        };
    }
    [scrollNode setNeedsLayout];
}

// Builds the table-of-contents chip row from the sections already registered on
// the scroll node (those with a tocTitle). Tapping a chip scroll-jumps to it.
static ASDisplayNode *ApolloSBBuildTOC(NSArray<ApolloSBSection *> *sections, ASDisplayNode *scrollNode, NSMutableArray *tapTargets) {
    NSMutableArray *chips = [NSMutableArray array];
    for (ApolloSBSection *s in sections) {
        if (s.tocTitle.length == 0 || !s.node) continue;
        ASButtonNode *chip = [[ApolloSBButtonClass() alloc] init];
        [chip setTitle:s.tocTitle withFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] withColor:UIColor.labelColor forState:0];
        chip.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
        chip.cornerRadius = 14.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(6.0, 13.0, 6.0, 13.0);

        ApolloSBTOCTapTarget *t = [[ApolloSBTOCTapTarget alloc] init];
        t.scrollNode = scrollNode;
        t.targetSection = s.node;
        [tapTargets addObject:t];
        [chip addTarget:t action:@selector(tocTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
        [chips addObject:chip];
    }
    if (chips.count < 2) return nil; // a single tab isn't worth a TOC

    ASTextNode *titleNode = [[ApolloSBTextClass() alloc] init];
    titleNode.attributedText = [[NSAttributedString alloc] initWithString:@"Jump to a Section" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *row = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                                    justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:chips];
        row.flexWrap = kApolloSBFlexWrapWrap;
        row.lineSpacing = 8.0;
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:10.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:@[titleNode, row]];
    };
    return container;
}

#pragma mark - Section ordering

typedef NS_ENUM(NSInteger, ApolloSBOrder) {
    ApolloSBOrderStats   = 0,
    ApolloSBOrderTOC     = 20,  // "Jump to a Section" sits above the bio
    ApolloSBOrderFlair   = 100,
    ApolloSBOrderMenu    = 150,
    ApolloSBOrderContent = 200,
};

static void ApolloSBAddSection(UIViewController *vc, ASDisplayNode *scrollNode, ASDisplayNode *node, NSInteger order, NSString *tocTitle, UIEdgeInsets insets) {
    if (!node) return;
    ApolloSBSection *s = [[ApolloSBSection alloc] init];
    s.order = order;
    s.node = node;
    s.insets = insets;
    s.tocTitle = tocTitle;
    ApolloSBInstallSection(scrollNode, s);
}

#pragma mark - Sidebar VC hook

// Builds all sidebar sections. Called only once Apollo's nodes are ready (see
// ApolloSBTryBuild). vc/root/subredditName/tapTargets come from the VC hook.
static void ApolloSBBuildSidebarSections(UIViewController *vc, NSDictionary *root, NSString *subredditName, NSMutableArray *tapTargets) {
    ASDisplayNode *scrollNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "scrollNode");
    if (!scrollNode || !scrollNode.layoutSpecBlock) return;

    // Collapse Apollo's native 2-stat header — we render our own stats instead.
    id hn = ApolloSBReadObjectIvar(vc, "headerNode");
    if (hn) {
        objc_setAssociatedObject(hn, &kApolloSBCollapseHeaderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(ASDisplayNode *)hn setNeedsLayout];
    }

    id rdkSub = ApolloSBReadObjectIvar(vc, "subreddit");
    ASDisplayNode *markdownNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "markdownNode");

    // ---- Collapsible bio: clip the description markdown to ~2 lines + "Show more". ----
    NSString *mdSource = markdownNode ? ApolloSBReadSwiftStringIvar(markdownNode, "source") : nil;
    if (mdSource.length == 0 && markdownNode) mdSource = ApolloSBReadSwiftStringIvar(markdownNode, "sourceHTML");
    if (markdownNode && mdSource.length > 250) {
        markdownNode.clipsToBounds = YES;
        markdownNode.style.maxHeight = ApolloSBPoints(kApolloSBBioCollapsedHeight);
        objc_setAssociatedObject(markdownNode, &kApolloSBBioExpandedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ASButtonNode *moreBtn = [[ApolloSBButtonClass() alloc] init];
        [moreBtn setTitle:@"Show more" withFont:[UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold] withColor:UIColor.secondaryLabelColor forState:0];
        ApolloSBBioToggleTarget *bt = [[ApolloSBBioToggleTarget alloc] init];
        bt.markdownNode = markdownNode; bt.scrollNode = scrollNode; bt.button = moreBtn;
        [tapTargets addObject:bt];
        [moreBtn addTarget:bt action:@selector(toggle:) forControlEvents:kApolloSBControlEventTouchUpInside];
        ASDisplayNode *moreContainer = [[ApolloSBNodeClass() alloc] init];
        moreContainer.automaticallyManagesSubnodes = YES;
        moreContainer.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
            return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:0.0
                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:@[moreBtn]];
        };
        ApolloSBAddSection(vc, scrollNode, moreContainer, kApolloSBOrigSpecOrder + 1, nil, UIEdgeInsetsMake(8, 16, 0, 16));
    }

    NSDictionary *items = [root[@"items"] isKindOfClass:[NSDictionary class]] ? root[@"items"] : nil;
    NSDictionary *layout = [root[@"layout"] isKindOfClass:[NSDictionary class]] ? root[@"layout"] : nil;

    // ---- Stats: Subscribers (custom id-card label when present) + Created date. ----
    NSString *idCardID = ApolloSBString(layout[@"idCardWidget"]);
    NSDictionary *idCard = [items[idCardID] isKindOfClass:[NSDictionary class]] ? items[idCardID] : nil;
    long long idCardSubs = idCard ? ApolloSBLongLong(idCard[@"subscribersCount"]) : -1;
    long long rdkSubs = rdkSub ? (long long)((unsigned long long(*)(id, SEL))objc_msgSend)(rdkSub, sel_registerName("totalSubscribers")) : -1;
    long long subsCount = idCardSubs > 0 ? idCardSubs : MAX(rdkSubs, 0LL);
    NSString *subsLabel = ApolloSBString(idCard[@"subscribersText"]);
    if (subsLabel.length == 0) subsLabel = @"Subscribers";
    NSString *createdStr = nil;
    if (rdkSub) {
        NSDate *created = ((NSDate *(*)(id, SEL))objc_msgSend)(rdkSub, sel_registerName("createdUTC"));
        if ([created isKindOfClass:[NSDate class]]) {
            static NSDateFormatter *fmt; static dispatch_once_t once;
            dispatch_once(&once, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"MMM yyyy"; });
            createdStr = [fmt stringFromDate:created];
        }
    }
    NSMutableArray *cols = [NSMutableArray array];
    [cols addObject:ApolloSBMakeStatColumn(subsLabel, subsCount > 0 ? ApolloSBFormatCount(subsCount) : @"—")];
    if (createdStr.length) [cols addObject:ApolloSBMakeStatColumn(@"Created", createdStr)];
    ApolloSBAddSection(vc, scrollNode, ApolloSBBuildStatsSection(cols), ApolloSBOrderStats, nil, UIEdgeInsetsMake(18, 16, 6, 16));

    // ---- Flair ("Search by Flair") ----
    for (NSString *wid in items) {
        NSDictionary *w = items[wid];
        if (![w[@"kind"] isEqual:@"post-flair"]) continue;
        NSArray *order = [w[@"order"] isKindOfClass:[NSArray class]] ? w[@"order"] : nil;
        NSDictionary *templates = [w[@"templates"] isKindOfClass:[NSDictionary class]] ? w[@"templates"] : nil;
        if (order.count == 0 || templates.count == 0) continue;
        ASDisplayNode *flair = ApolloSBBuildFlairSection(ApolloSBString(w[@"shortName"]), order, templates, subredditName, tapTargets);
        ApolloSBAddSection(vc, scrollNode, flair, ApolloSBOrderFlair, @"Flair", UIEdgeInsetsMake(20, 16, 0, 16));
        break;
    }

    // ---- Menu / Community Bookmarks (topbar menu widget) ----
    NSArray *topbarOrder = [layout[@"topbar"] isKindOfClass:[NSDictionary class]] ? layout[@"topbar"][@"order"] : nil;
    NSString *menuID = [topbarOrder isKindOfClass:[NSArray class]] ? topbarOrder.firstObject : nil;
    NSDictionary *menuWidget = [items[menuID] isKindOfClass:[NSDictionary class]] ? items[menuID] : nil;
    if (!menuWidget) {
        for (NSString *wid in items) { if ([items[wid][@"kind"] isEqual:@"menu"]) { menuWidget = items[wid]; break; } }
    }
    if (menuWidget) {
        NSArray *menuLinks = ApolloSBLinksFromMenuWidget(menuWidget);
        ASDisplayNode *menuSection = ApolloSBBuildLinkGroupSection(@"Community Bookmarks", menuLinks, vc, tapTargets);
        ApolloSBAddSection(vc, scrollNode, menuSection, ApolloSBOrderMenu, @"Bookmarks", UIEdgeInsetsMake(20, 16, 0, 16));
    }

    // ---- button + community-list widgets (sidebar.order first, then any leftovers). ----
    NSArray *sidebarOrder = [layout[@"sidebar"] isKindOfClass:[NSDictionary class]] ? layout[@"sidebar"][@"order"] : nil;
    NSMutableArray *iterIDs = [NSMutableArray array];
    if ([sidebarOrder isKindOfClass:[NSArray class]]) [iterIDs addObjectsFromArray:sidebarOrder];
    for (NSString *wid in items) if (![iterIDs containsObject:wid]) [iterIDs addObject:wid];
    NSInteger seqOrder = ApolloSBOrderContent;
    for (NSString *wid in iterIDs) {
        NSDictionary *w = [items[wid] isKindOfClass:[NSDictionary class]] ? items[wid] : nil;
        NSString *kind = ApolloSBString(w[@"kind"]);
        if ([kind isEqualToString:@"button"]) {
            NSArray *links = ApolloSBLinksFromButtonWidget(w);
            NSString *shortName = ApolloSBString(w[@"shortName"]);
            ASDisplayNode *section = ApolloSBBuildLinkGroupSection(shortName, links, vc, tapTargets);
            ApolloSBAddSection(vc, scrollNode, section, seqOrder++, shortName ?: @"Links", UIEdgeInsetsMake(20, 16, 0, 16));
        } else if ([kind isEqualToString:@"community-list"]) {
            NSArray *data = [w[@"data"] isKindOfClass:[NSArray class]] ? w[@"data"] : nil;
            if (data.count == 0) continue;
            NSString *shortName = ApolloSBString(w[@"shortName"]);
            ASDisplayNode *section = ApolloSBBuildCommunityListSection(shortName, data, vc, tapTargets);
            ApolloSBAddSection(vc, scrollNode, section, seqOrder++, shortName ?: @"Communities", UIEdgeInsetsMake(20, 16, 0, 16));
        }
    }

    // ---- Table of contents (built last, from all registered sections). ----
    NSArray *allSections = objc_getAssociatedObject(scrollNode, &kApolloSBSectionsKey);
    ASDisplayNode *toc = ApolloSBBuildTOC(allSections, scrollNode, tapTargets);
    ApolloSBAddSection(vc, scrollNode, toc, ApolloSBOrderTOC, nil, UIEdgeInsetsMake(18, 16, 0, 16));
    ApolloLog(@"[Sidebar] r/%@ built (idCard=%d menu=%d toc=%d)", subredditName, idCard != nil, menuWidget != nil, toc != nil);
}

// On a warm widget cache the fetch completion fires synchronously + early — before
// Apollo has created the scroll/header/markdown nodes. Retry on the main queue
// until they exist, then build once. (Plain recursion — no self-freeing block.)
static void ApolloSBTryBuild(UIViewController *vc, NSDictionary *root, NSString *subredditName, NSMutableArray *tapTargets, NSInteger attempt) {
    if (!vc) return;
    ASDisplayNode *scrollNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "scrollNode");
    id hn = ApolloSBReadObjectIvar(vc, "headerNode");
    id md = ApolloSBReadObjectIvar(vc, "markdownNode");
    if ((!scrollNode || !scrollNode.layoutSpecBlock || !hn || !md) && attempt < 15) {
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloSBTryBuild(weakVC, root, subredditName, tapTargets, attempt + 1);
        });
        return;
    }
    ApolloSBBuildSidebarSections(vc, root, subredditName, tapTargets);
}

%hook _TtC6Apollo30SubredditSidebarViewController

- (void)viewDidLoad {
    %orig;
    if ([objc_getAssociatedObject(self, &kApolloSBInstalledKey) boolValue]) return;
    objc_setAssociatedObject(self, &kApolloSBInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *subredditName = ApolloSBReadSwiftStringIvar(self, "subredditName");
    if (subredditName.length == 0) return;

    // Collapse Apollo's native 2-stat header — we render our own custom-labeled
    // stats as the first section instead. Flag the header node now (before it
    // lays out) so it returns a zero-size spec.
    id headerNode = ApolloSBReadObjectIvar(self, "headerNode");
    if (headerNode) {
        objc_setAssociatedObject(headerNode, &kApolloSBCollapseHeaderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(ASDisplayNode *)headerNode setNeedsLayout];
    }

    NSMutableArray *tapTargets = [NSMutableArray array];
    objc_setAssociatedObject(self, &kApolloSBTapTargetsKey, tapTargets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakSelf = (UIViewController *)self;
    ApolloSBFetchWidgets(subredditName, ^(NSDictionary *root) {
        ApolloSBTryBuild(weakSelf, root, subredditName, tapTargets, 0);
    });
}

%end

#pragma mark - Collapse native stats header

%hook _TtC6Apollo26SubredditSidebarHeaderNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if ([objc_getAssociatedObject(self, &kApolloSBCollapseHeaderKey) boolValue]) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:0.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:@[]];
    }
    return %orig;
}

%end

//
//  ApolloAISummary.xm
//  Apollo-Reborn
//
//  On-device AI summaries (Apple FoundationModels): a post summary at the
//  bottom of the post and a comment summary at the top of the comment list,
//  generated automatically when a post's comments open. Gated by the
//  `sEnableAISummaries` settings toggle (off by default) and only active when
//  the on-device model reports available.
//
//  The Swift-only FoundationModels API is reached through the
//  `ApolloFoundationModels` @objc bridge (ApolloFoundationModels.swift). We
//  resolve it via NSClassFromString so there is no link-time dependency on the
//  Swift-generated interop header.
//
//  The summaries are inserted into CommentsHeaderCellNode's layout. The post
//  summary follows Apollo's original post header content; the discussion
//  summary follows it, immediately before the first comment row.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

#pragma mark - Texture declarations

typedef NS_ENUM(unsigned char, ApolloAIStackDirection) {
    ApolloAIStackDirectionHorizontal = 0,
    ApolloAIStackDirectionVertical = 1,
};

typedef NS_ENUM(unsigned char, ApolloAIStackJustifyContent) {
    ApolloAIStackJustifyContentStart = 0,
};

typedef NS_ENUM(unsigned char, ApolloAIStackAlignItems) {
    ApolloAIStackAlignItemsStart = 0,
    ApolloAIStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASInsetLayoutSpec;
@class ASBackgroundLayoutSpec;
@class ASDisplayNode;
@class ASTextNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
- (UIView *)view;
- (void)onDidLoad:(void (^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat borderWidth;
@property (nullable, nonatomic) CGColorRef borderColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloAIStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloAIStackJustifyContent justifyContent;
@property (nonatomic) ApolloAIStackAlignItems alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
@property (nullable, nonatomic) NSArray *children;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloAIStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloAIStackJustifyContent)justifyContent
                                  alignItems:(ApolloAIStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
@property (nonatomic) UIEdgeInsets insets;
@property (nullable, nonatomic) id child;
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(id)background;
@end

// ASSizeRange as emitted by Apollo's class-dumped headers.
struct ApolloAISizeRange { CGSize min; CGSize max; };

#pragma mark - FoundationModels bridge (declared, resolved at runtime)

// Mirrors the @objc surface of ApolloFoundationModels.swift. We never reference
// the class symbol directly (only via NSClassFromString), so this is a pure
// type declaration for clean message sends.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
- (BOOL)isModelAvailable;
- (void)prepareSession:(NSString *)identifier instructions:(NSString *)instructions;
- (void)discardPreparedSession:(NSString *)identifier;
- (void)cancelRequest:(NSString *)identifier;
- (void)summarize:(NSString *)text
       identifier:(NSString *)identifier
     instructions:(NSString *)instructions
maximumResponseTokens:(NSInteger)maximumResponseTokens
        onPartial:(void (^)(NSString *partial))onPartial
       onComplete:(void (^)(NSString *final, NSError *error))onComplete;
@end

static ApolloFoundationModels *ApolloAIBridge(void) {
    Class cls = NSClassFromString(@"ApolloFoundationModels");
    if (!cls) return nil;
    return [cls shared];
}

#pragma mark - Tuning

// Keep prompts well within the on-device model's context window.
static const NSUInteger kApolloAIMaxPostChars = 1400;
static const NSUInteger kApolloAIMinComments = 5;
static const NSUInteger kApolloAIMinCommentChars = 500;
static const NSUInteger kApolloAIMaxCommentChars = 1200;
static const NSUInteger kApolloAIMaxComments = 8;
static const NSUInteger kApolloAIMaxSingleCommentChars = 280;
static const NSInteger kApolloAIPostResponseTokens = 80;
static const NSInteger kApolloAICommentResponseTokens = 80;
static const NSTimeInterval kApolloAIGenerationTimeout = 20.0;
static NSString *const kApolloAICacheVersion = @"2";

static NSString *const kApolloAIPostInstructions =
    @"Summarize this Reddit post in 2 short plain sentences. State the main point "
    @"and what the poster asks, claims, or shares. No heading, Markdown, or added facts.";

static NSString *const kApolloAICommentInstructions =
    @"Summarize these Reddit comments in 2-3 short plain sentences. Cover the "
    @"consensus, useful details, and one notable disagreement if present. "
    @"Summarize commenters, not the post. No heading, Markdown, or added facts.";

#pragma mark - Per-session caches / in-flight guard

// fullName -> generated summary text. Survives re-opening the same thread.
static NSMutableDictionary<NSString *, NSString *> *sPostSummaryCache;
static NSMutableDictionary<NSString *, NSString *> *sCommentSummaryCache;
static NSMutableDictionary<NSString *, NSNumber *> *sCommentSummarySourceCounts;
static NSMutableDictionary<NSString *, NSString *> *sCommentSummarySignatures;
// fullNames whose post / comment generation is currently running, so we don't
// kick off duplicate concurrent requests for the same thread.
static NSMutableSet<NSString *> *sPostInFlight;
static NSMutableSet<NSString *> *sCommentInFlight;
static NSMutableDictionary<NSString *, NSString *> *sPostRequestIDs;
static NSMutableDictionary<NSString *, NSString *> *sCommentRequestIDs;
// Header nodes are weak: they are only retained by Apollo/Texture while their
// rows exist. Generated text is applied to every live header for the same post.
static NSHashTable *sHeaderNodes;
static NSMapTable<NSString *, UIViewController *> *sControllerByFullName;
// Comments captured from CommentCellNode lifecycle hooks, keyed by post. This
// includes rows Texture creates below the fold and is more reliable than
// asking ASTableNode for nodes that have not yet entered its visible cache.
static NSMutableDictionary<NSString *, NSMutableArray *> *sCapturedComments;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *sCapturedCommentKeys;
static __weak UIViewController *sVisibleCommentsController;
static NSMutableDictionary<NSString *, NSNumber *> *sLastPartialUIUpdate;
static NSMutableSet<NSString *> *sCommentGenerationScheduled;
// fullNames whose post / comment generation hit a hard error this session. We
// stop retrying them (the box shows the error) so the layout doesn't flicker
// loading<->error as the retry schedule and comment captures re-fire.
static NSMutableSet<NSString *> *sPostFailed;
static NSMutableSet<NSString *> *sCommentFailed;
static NSMutableSet<NSString *> *sTimedOutRequests;

#pragma mark - Disk persistence (summaries survive app relaunches)

// Completed summaries are tiny strings keyed by Reddit fullName, so we persist
// them to a single plist and reload on launch — reopening a thread you have
// already summarized is then instant and costs no model time. The file lives in
// Caches (regenerable; the OS may purge it under storage pressure, which simply
// means those threads re-summarize once).
static const NSUInteger kApolloAIPersistMaxEntries = 600;

static NSString *ApolloAISummariesCachePath(void) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (caches.length == 0) caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return [caches stringByAppendingPathComponent:@"ApolloAISummaries.plist"];
}

static dispatch_queue_t ApolloAIPersistQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apollo-reborn.aisummary.persist", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Reads the persisted summaries into the in-memory caches. Caller must hold the
// once-guard (we only ever populate these dictionaries on the main thread).
static void ApolloAILoadPersistedSummaries(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:ApolloAISummariesCachePath()];
    if (![root isKindOfClass:[NSDictionary class]]) return;
    if (![root[@"version"] isEqualToString:kApolloAICacheVersion]) {
        ApolloLog(@"[AISummary] ignoring stale summary cache version %@", root[@"version"] ?: @"(none)");
        return;
    }
    NSDictionary *post = root[@"post"];
    NSDictionary *comment = root[@"comment"];
    NSDictionary *sourceCounts = root[@"commentSourceCounts"];
    NSDictionary *signatures = root[@"commentSignatures"];
    if ([post isKindOfClass:[NSDictionary class]]) [sPostSummaryCache addEntriesFromDictionary:post];
    if ([comment isKindOfClass:[NSDictionary class]]) [sCommentSummaryCache addEntriesFromDictionary:comment];
    if ([sourceCounts isKindOfClass:[NSDictionary class]]) [sCommentSummarySourceCounts addEntriesFromDictionary:sourceCounts];
    if ([signatures isKindOfClass:[NSDictionary class]]) [sCommentSummarySignatures addEntriesFromDictionary:signatures];
    ApolloLog(@"[AISummary] loaded %lu post / %lu comment summaries from disk",
              (unsigned long)sPostSummaryCache.count, (unsigned long)sCommentSummaryCache.count);
}

// Snapshots the caches on the main thread and writes them off-thread. Cheap to
// call after each completed summary (a thread completes at most twice).
static void ApolloAIPersistSummaries(void) {
    NSDictionary *postSnapshot = [sPostSummaryCache copy];
    NSDictionary *commentSnapshot = [sCommentSummaryCache copy];
    NSDictionary *sourceCountSnapshot = [sCommentSummarySourceCounts copy];
    NSDictionary *signatureSnapshot = [sCommentSummarySignatures copy];
    dispatch_async(ApolloAIPersistQueue(), ^{
        NSMutableDictionary *post = [postSnapshot mutableCopy];
        NSMutableDictionary *comment = [commentSnapshot mutableCopy];
        // Bound pathological growth; summaries are ~a few hundred bytes each.
        while (post.count > kApolloAIPersistMaxEntries) [post removeObjectForKey:post.allKeys.firstObject];
        while (comment.count > kApolloAIPersistMaxEntries) [comment removeObjectForKey:comment.allKeys.firstObject];
        NSDictionary *root = @{
            @"version": kApolloAICacheVersion,
            @"post": post,
            @"comment": comment,
            @"commentSourceCounts": sourceCountSnapshot,
            @"commentSignatures": signatureSnapshot,
        };
        [root writeToFile:ApolloAISummariesCachePath() atomically:YES];
    });
}

static void ApolloAIEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPostSummaryCache = [NSMutableDictionary dictionary];
        sCommentSummaryCache = [NSMutableDictionary dictionary];
        sCommentSummarySourceCounts = [NSMutableDictionary dictionary];
        sCommentSummarySignatures = [NSMutableDictionary dictionary];
        sPostInFlight = [NSMutableSet set];
        sCommentInFlight = [NSMutableSet set];
        sPostRequestIDs = [NSMutableDictionary dictionary];
        sCommentRequestIDs = [NSMutableDictionary dictionary];
        sHeaderNodes = [NSHashTable weakObjectsHashTable];
        sControllerByFullName = [NSMapTable strongToWeakObjectsMapTable];
        sCapturedComments = [NSMutableDictionary dictionary];
        sCapturedCommentKeys = [NSMutableDictionary dictionary];
        sLastPartialUIUpdate = [NSMutableDictionary dictionary];
        sCommentGenerationScheduled = [NSMutableSet set];
        sPostFailed = [NSMutableSet set];
        sCommentFailed = [NSMutableSet set];
        sTimedOutRequests = [NSMutableSet set];
        ApolloAILoadPersistedSummaries();
    });
}

#pragma mark - Runtime helpers (self-contained; mirror ApolloTranslation patterns)

static UITableView *ApolloAICommentsTableView(UIViewController *vc);
static id ApolloAICommentFromCellNode(id cellNode);
static void ApolloAIGenerateForController(UIViewController *vc);
static void ApolloAIPrepareForController(UIViewController *vc);
static void ApolloAIShowLoadingIfIdle(NSString *fullName, BOOL isPost);

static id ApolloAIGetIvarObject(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

// Swift Optional<ObjCClass> ivars do not consistently report an '@' runtime
// encoding. For known object ivars, object_getIvar is still the correct access
// path and avoids rejecting CommentsViewController.link before reading it.
static id ApolloAIKnownObjectIvar(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) return nil;
    @try {
        return object_getIvar(obj, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Reddit fullName ("t3_xxxx") for the post; falls back to a stable key.
static NSString *ApolloAILinkFullName(id link) {
    if (!link) return nil;
    SEL sels[] = { @selector(fullName), NSSelectorFromString(@"name"), NSSelectorFromString(@"identifier") };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        if ([link respondsToSelector:sels[i]]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(link, sels[i]);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

// Scan every `@`-typed ivar in an object's class hierarchy and return the first
// RDKLink found. Catches Swift-mangled / optional-wrapped ivar names that a
// fixed name list misses.
static id ApolloAIScanForLink(id obj) {
    if (!obj) return nil;
    Class rdkLink = NSClassFromString(@"RDKLink");
    if (!rdkLink) return nil;

    static const char *knownNames[] = {
        "link", "_link", "post", "_post", "currentLink", "currentPost", NULL
    };
    for (size_t i = 0; knownNames[i]; i++) {
        id value = ApolloAIKnownObjectIvar(obj, knownNames[i]);
        if ([value isKindOfClass:rdkLink]) return value;
    }

    for (Class cls = [obj class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(obj, ivars[i]); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) { free(ivars); return v; }
        }
        free(ivars);
    }
    return nil;
}

static NSArray *ApolloAIAvailableNodes(UIViewController *vc) {
    id tableNode = ApolloAIGetIvarObject(vc, "tableNode");
    UITableView *tableView = ApolloAICommentsTableView(vc);
    NSMutableArray *nodes = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    // AsyncDisplayKit retains a node for every row it has already loaded,
    // including preloaded rows below the fold; ask for those by index path.
    // We deliberately do NOT execute Texture's node block for rows it hasn't
    // built yet — that forces synchronous offscreen cell construction on the
    // main thread (the old code's biggest stall) and defeats lazy loading.
    // Comment bodies are captured from the cell lifecycle hooks instead, so the
    // already-loaded nodes here are only a supplementary source.
    SEL nodeForRowSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (tableNode && tableView && [tableNode respondsToSelector:nodeForRowSelector]) {
        NSInteger sectionCount = [tableView numberOfSections];
        for (NSInteger section = 0; section < sectionCount; section++) {
            NSInteger rowCount = [tableView numberOfRowsInSection:section];
            for (NSInteger row = 0; row < rowCount; row++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeForRowSelector, indexPath);
                if (!node) continue;
                NSValue *identity = [NSValue valueWithNonretainedObject:node];
                if ([seen containsObject:identity]) continue;
                [seen addObject:identity];
                [nodes addObject:node];
            }
        }
    }

    SEL visibleNodesSelector = NSSelectorFromString(@"visibleNodes");
    if (tableNode && [tableNode respondsToSelector:visibleNodesSelector]) {
        id visibleNodes = ((id (*)(id, SEL))objc_msgSend)(tableNode, visibleNodesSelector);
        if ([visibleNodes isKindOfClass:[NSArray class]]) {
            for (id node in visibleNodes) {
                NSValue *identity = [NSValue valueWithNonretainedObject:node];
                if ([seen containsObject:identity]) continue;
                [seen addObject:identity];
                [nodes addObject:node];
            }
        }
    }

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (![cell respondsToSelector:@selector(node)]) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
        if (!node) continue;
        NSValue *identity = [NSValue valueWithNonretainedObject:node];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [nodes addObject:node];
    }
    return nodes;
}

// Per-controller memoization of the resolved link and its fullName. Both are
// stable for the lifetime of a comments controller, but the resolvers below are
// on the hot path (called from every comment cell's lifecycle hooks), so we
// cache the result on the controller the first time it resolves instead of
// re-scanning ivars / the loaded node set on every call.
static char kApolloAICachedLinkKey;
static char kApolloAICachedFullNameKey;
static char kApolloAIProvisionalPostRequestKey;
static char kApolloAIProvisionalCommentRequestKey;

// The RDKLink backing a comments view controller: first from the controller's
// own ivars, then (the reliable path) from the post header cell node, which
// always holds the link. Memoized on the controller once found.
static id ApolloAILinkFromController(UIViewController *vc) {
    if (!vc) return nil;
    id cached = objc_getAssociatedObject(vc, &kApolloAICachedLinkKey);
    if (cached) return cached;

    id link = ApolloAIScanForLink(vc);
    if (!link) {
        for (id cellNode in ApolloAIAvailableNodes(vc)) {
            // Skip comment cells; the header (post) cell node carries the link.
            if (ApolloAICommentFromCellNode(cellNode)) continue;
            link = ApolloAIScanForLink(cellNode);
            if (link) break;
        }
    }
    if (link) objc_setAssociatedObject(vc, &kApolloAICachedLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return link;
}

static UITableView *ApolloAIFindTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *t = ApolloAIFindTableViewInView(sub);
        if (t) return t;
    }
    return nil;
}

static UITableView *ApolloAICommentsTableView(UIViewController *vc) {
    id tableNode = ApolloAIGetIvarObject(vc, "tableNode");
    if (tableNode && [tableNode respondsToSelector:@selector(view)]) {
        UIView *v = ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    }
    return ApolloAIFindTableViewInView(vc.view);
}

// The RDKComment on a CommentCellNode (its `comment` ivar), or nil.
static id ApolloAICommentFromCellNode(id cellNode) {
    if (!cellNode) return nil;
    id comment = ApolloAIKnownObjectIvar(cellNode, "comment");
    Class rdkComment = NSClassFromString(@"RDKComment");
    if (!rdkComment || ![comment isKindOfClass:rdkComment]) return nil;
    return comment;
}

static NSString *ApolloAIStringSel(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *ApolloAINormalizeGeneratedSummary(NSString *summary) {
    if (![summary isKindOfClass:[NSString class]]) return nil;
    NSString *plain = [summary stringByReplacingOccurrencesOfString:@"**" withString:@""];
    plain = [plain stringByReplacingOccurrencesOfString:@"__" withString:@""];
    return [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Remove input that costs context without helping a short summary. Keep this
// deterministic and conservative: ordinary prose and punctuation are preserved.
static NSString *ApolloAICleanInputText(NSString *text, NSUInteger maxLength) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;

    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    BOOL inCodeBlock = NO;
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"```"]) {
            inCodeBlock = !inCodeBlock;
            continue;
        }
        if (inCodeBlock || [line hasPrefix:@">"] || line.length == 0) continue;
        [keptLines addObject:line];
    }

    NSString *clean = [keptLines componentsJoinedByString:@" "];
    NSError *regexError = nil;
    NSRegularExpression *urlRegex =
        [NSRegularExpression regularExpressionWithPattern:@"https?://\\S+"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&regexError];
    if (!regexError) {
        clean = [urlRegex stringByReplacingMatchesInString:clean
                                                   options:0
                                                     range:NSMakeRange(0, clean.length)
                                              withTemplate:@"[link]"];
    }
    clean = [clean stringByReplacingOccurrencesOfString:@"**" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"__" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"~~" withString:@""];
    while ([clean containsString:@"  "]) {
        clean = [clean stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (maxLength > 0 && clean.length > maxLength) {
        clean = [[clean substringToIndex:maxLength]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return clean.length > 0 ? clean : nil;
}

static NSInteger ApolloAIIntegerSel(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSString *ApolloAICommentDedupKey(id comment) {
    NSString *fullName = ApolloAIStringSel(comment, @selector(fullName));
    if (fullName.length > 0) return fullName;
    NSString *body = ApolloAIStringSel(comment, @selector(body));
    NSString *author = ApolloAIStringSel(comment, @selector(author)) ?: @"user";
    if (body.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%lu", author, (unsigned long)body.hash];
}

// A comment must be useful before it can be captured, counted, ranked, or make
// the discussion card appear. Filtering here prevents AutoModerator-only and
// deleted/removed threads from getting stuck in a permanent loading state.
static BOOL ApolloAICommentIsEligible(id comment) {
    if (!comment) return NO;
    NSString *author = [ApolloAIStringSel(comment, @selector(author))
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (author.length == 0 ||
        [author caseInsensitiveCompare:@"AutoModerator"] == NSOrderedSame ||
        [author caseInsensitiveCompare:@"[deleted]"] == NSOrderedSame) {
        return NO;
    }

    NSString *rawBody = ApolloAIStringSel(comment, @selector(body));
    if ([rawBody isEqualToString:@"[deleted]"] || [rawBody isEqualToString:@"[removed]"]) return NO;
    NSString *body = ApolloAICleanInputText(rawBody, kApolloAIMaxSingleCommentChars);
    return body.length >= 30;
}

static NSString *ApolloAIFullNameForController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *cached = objc_getAssociatedObject(vc, &kApolloAICachedFullNameKey);
    if (cached.length > 0) return cached;
    NSString *fullName = ApolloAILinkFullName(ApolloAILinkFromController(vc));
    if (fullName.length > 0) {
        objc_setAssociatedObject(vc, &kApolloAICachedFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return fullName;
}

static void ApolloAICaptureCommentForController(id comment, UIViewController *vc) {
    if (!ApolloAICommentIsEligible(comment) || !vc) return;
    NSString *fullName = ApolloAIFullNameForController(vc);
    NSString *key = ApolloAICommentDedupKey(comment);
    if (fullName.length == 0 || key.length == 0) return;

    NSMutableArray *comments = sCapturedComments[fullName];
    if (!comments) {
        comments = [NSMutableArray array];
        sCapturedComments[fullName] = comments;
    }
    NSMutableSet *keys = sCapturedCommentKeys[fullName];
    if (!keys) {
        keys = [NSMutableSet set];
        sCapturedCommentKeys[fullName] = keys;
    }
    if ([keys containsObject:key]) return;
    [keys addObject:key];
    [comments addObject:comment];
    // Do not show a discussion card until there is enough material to synthesize.
    // Below this threshold, reading the comments directly is faster and clearer.
    if (comments.count >= kApolloAIMinComments &&
        sCommentSummaryCache[fullName].length == 0 &&
        ![sCommentFailed containsObject:fullName]) {
        ApolloAIShowLoadingIfIdle(fullName, NO);
    }
    ApolloLog(@"[AISummary] captured comment %lu for %@", (unsigned long)comments.count, fullName);
}

static void ApolloAIAppendCommentText(id comment,
                                      NSMutableSet<NSString *> *seen,
                                      NSMutableString *joined,
                                      NSUInteger *count) {
    if (!ApolloAICommentIsEligible(comment) || !seen || !joined || !count) return;
    NSString *body = ApolloAICleanInputText(ApolloAIStringSel(comment, @selector(body)),
                                            kApolloAIMaxSingleCommentChars);
    if (body.length < 30) return;
    NSString *author = ApolloAIStringSel(comment, @selector(author)) ?: @"user";
    NSString *key = ApolloAICommentDedupKey(comment);
    if (key.length == 0 || [seen containsObject:key]) return;
    [seen addObject:key];

    NSInteger score = ApolloAIIntegerSel(comment, @selector(score));
    NSUInteger controversiality = (NSUInteger)MAX(0, ApolloAIIntegerSel(comment, @selector(controversiality)));
    NSString *linkAuthor = ApolloAIStringSel(comment, @selector(linkAuthor));
    BOOL isOP = linkAuthor.length > 0 && [author caseInsensitiveCompare:linkAuthor] == NSOrderedSame;
    NSString *kind = isOP ? @"OP" : (controversiality > 0 ? @"controversial" : @"comment");
    [joined appendFormat:@"[%@, score %ld] %@\n", kind, (long)score, body];
    (*count)++;
}

// Pull the RDKComment out of a comment row/model object — directly if it is
// one, otherwise via a `comment` accessor (cell models wrap it).
static id ApolloAIRDKCommentFromObject(id obj, Class rdkComment) {
    if (!obj || !rdkComment) return nil;
    if ([obj isKindOfClass:rdkComment]) return obj;
    if ([obj respondsToSelector:@selector(comment)]) {
        id c = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(comment));
        if ([c isKindOfClass:rdkComment]) return c;
    }
    return nil;
}

// Walk the comments controller's own ivars for the in-memory comment list
// Apollo already holds (the full fetched set), so we can summarize the instant
// the thread's data arrives instead of waiting for table cells to render — the
// main reason on-device felt slow next to a server that has the data in hand.
// Picks the array ivar with the most comment-bearing elements (best-effort).
static void ApolloAICollectCommentsFromDataModel(UIViewController *vc,
                                                 NSMutableArray *comments,
                                                 NSMutableSet<NSString *> *candidateKeys) {
    Class rdkComment = NSClassFromString(@"RDKComment");
    if (!rdkComment || !vc || !comments || !candidateKeys) return;

    NSArray *bestArray = nil;
    NSUInteger bestScore = 0;
    for (Class cls = [vc class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        if (!ivars) continue;
        for (unsigned int i = 0; i < n; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(vc, ivars[i]); } @catch (__unused NSException *e) { continue; }
            NSArray *arr = nil;
            if ([value isKindOfClass:[NSArray class]]) arr = value;
            else if ([value isKindOfClass:[NSOrderedSet class]]) arr = [(NSOrderedSet *)value array];
            if (arr.count == 0) continue;
            NSUInteger score = 0, probe = MIN(arr.count, (NSUInteger)8);
            for (NSUInteger j = 0; j < probe; j++) {
                if (ApolloAIRDKCommentFromObject(arr[j], rdkComment)) score++;
            }
            if (score > bestScore) { bestScore = score; bestArray = arr; }
        }
        free(ivars);
    }
    if (bestScore == 0) return;

    for (id obj in bestArray) {
        id comment = ApolloAIRDKCommentFromObject(obj, rdkComment);
        NSString *key = ApolloAICommentDedupKey(comment);
        if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
        [candidateKeys addObject:key];
        [comments addObject:comment];
    }
}

static NSInteger ApolloAICommentRank(id comment, NSUInteger originalIndex) {
    NSInteger score = ApolloAIIntegerSel(comment, @selector(score));
    NSUInteger controversiality = (NSUInteger)MAX(0, ApolloAIIntegerSel(comment, @selector(controversiality)));
    NSString *author = ApolloAIStringSel(comment, @selector(author));
    NSString *linkAuthor = ApolloAIStringSel(comment, @selector(linkAuthor));
    BOOL isOP = author.length > 0 && linkAuthor.length > 0 &&
        [author caseInsensitiveCompare:linkAuthor] == NSOrderedSame;
    NSInteger depth = MAX(0, ApolloAIIntegerSel(comment, @selector(depth)));

    // High-score comments carry consensus. OP and controversial comments add
    // useful diversity. Preserve a modest top-to-bottom bias and favor roots.
    NSInteger rank = MIN(MAX(score, -50), 5000);
    if (isOP) rank += 1400;
    if (controversiality > 0) rank += 700;
    rank -= MIN(depth, 8) * 70;
    rank -= MIN(originalIndex, (NSUInteger)100) * 3;
    return rank;
}

// Gather a compact representative set rather than the first N rendered rows.
// The model sees consensus (score), OP context, disagreement (controversiality),
// and some thread-order signal without paying for the full comment section.
static NSString *ApolloAIGatherCommentText(UIViewController *vc,
                                           NSUInteger *outCount,
                                           NSString **outSignature) {
    if (outCount) *outCount = 0;
    if (outSignature) *outSignature = nil;

    NSMutableSet<NSString *> *candidateKeys = [NSMutableSet set];
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableString *joined = [NSMutableString string];
    NSUInteger count = 0;

    NSString *fullName = ApolloAIFullNameForController(vc);

    ApolloAICollectCommentsFromDataModel(vc, candidates, candidateKeys);

    for (id comment in sCapturedComments[fullName] ?: @[]) {
        NSString *key = ApolloAICommentDedupKey(comment);
        if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
        [candidateKeys addObject:key];
        [candidates addObject:comment];
    }

    if (candidates.count < 3) {
        for (id cellNode in ApolloAIAvailableNodes(vc)) {
            id comment = ApolloAICommentFromCellNode(cellNode);
            NSString *key = ApolloAICommentDedupKey(comment);
            if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
            [candidateKeys addObject:key];
            [candidates addObject:comment];
        }
    }

    NSMapTable *originalIndexes = [NSMapTable weakToStrongObjectsMapTable];
    [candidates enumerateObjectsUsingBlock:^(id comment, NSUInteger idx, __unused BOOL *stop) {
        [originalIndexes setObject:@(idx) forKey:comment];
    }];
    [candidates sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger rankA = ApolloAICommentRank(a, [[originalIndexes objectForKey:a] unsignedIntegerValue]);
        NSInteger rankB = ApolloAICommentRank(b, [[originalIndexes objectForKey:b] unsignedIntegerValue]);
        if (rankA > rankB) return NSOrderedAscending;
        if (rankA < rankB) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *selectedKeys = [NSMutableArray array];
    for (id comment in candidates) {
        if (count >= kApolloAIMaxComments || joined.length >= kApolloAIMaxCommentChars) break;
        NSUInteger previousCount = count;
        ApolloAIAppendCommentText(comment, seen, joined, &count);
        if (count > previousCount) {
            NSString *key = ApolloAICommentDedupKey(comment);
            NSString *body = ApolloAIStringSel(comment, @selector(body)) ?: @"";
            [selectedKeys addObject:[NSString stringWithFormat:@"%@:%lu",
                                     key ?: @"unknown", (unsigned long)body.hash]];
        }
    }

    if (outCount) *outCount = count;
    if (outSignature && selectedKeys.count > 0) {
        *outSignature = [selectedKeys componentsJoinedByString:@"|"];
    }
    if (joined.length == 0) return nil;
    if (joined.length > kApolloAIMaxCommentChars) {
        return [joined substringToIndex:kApolloAIMaxCommentChars];
    }
    return joined;
}

// Title + selftext for the post, or nil for non-self (link/image) posts.
static NSString *ApolloAIPostText(id link) {
    if (!link) return nil;
    BOOL isSelf = [link respondsToSelector:@selector(isSelfPostWithSelfText)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSelfPostWithSelfText));

    NSString *title = ApolloAIStringSel(link, @selector(title)) ?: @"";
    NSString *selfText = isSelf ? (ApolloAIStringSel(link, @selector(selfText)) ?: @"") : @"";

    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    selfText = ApolloAICleanInputText(selfText, kApolloAIMaxPostChars) ?: @"";

    if (selfText.length == 0) return nil;  // nothing meaningful to summarize

    if (title.length > 0) return [NSString stringWithFormat:@"Title: %@\nBody: %@", title, selfText];
    return selfText;
}

// A short, capped context block (post title + a snippet of the body, if any) so
// the comment summary knows the topic the discussion is responding to. Keeps
// the comment prompt grounded without spending much of the token budget on it.
static NSString *ApolloAIPostContextForComments(id link) {
    if (!link) return nil;
    NSString *title = [(ApolloAIStringSel(link, @selector(title)) ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) return nil;

    BOOL isSelf = [link respondsToSelector:@selector(isSelfPostWithSelfText)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSelfPostWithSelfText));
    NSString *selfText = isSelf ? [(ApolloAIStringSel(link, @selector(selfText)) ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";

    NSMutableString *context = [NSMutableString stringWithFormat:@"Post title: %@\n", title];
    if (selfText.length > 0) {
        NSUInteger snippetMax = 160;
        NSString *snippet = selfText.length > snippetMax ? [selfText substringToIndex:snippetMax] : selfText;
        [context appendFormat:@"Post body: %@\n", snippet];
    }
    return context;
}

#pragma mark - Summary UI

// Per-box lifecycle state. The summary cards are always visible (in their
// loading state) the moment we know a box applies, rather than popping in when
// the text is ready; failures show an error inside the box instead of hiding it.
typedef NS_ENUM(NSInteger, ApolloAIBoxState) {
    ApolloAIBoxStateNone = 0,   // no box for this type (e.g. link post / no comments)
    ApolloAIBoxStateLoading,    // box visible, generating (shows streamed text or "Summarizing…")
    ApolloAIBoxStateReady,      // box visible, final summary shown
    ApolloAIBoxStateError,      // box visible, error message shown
};

static char kApolloAIPostSummaryKey;        // ready/streamed summary text (post)
static char kApolloAICommentSummaryKey;     // ready/streamed summary text (comment)
static char kApolloAIPostStateKey;          // ApolloAIBoxState (post)
static char kApolloAICommentStateKey;       // ApolloAIBoxState (comment)
static char kApolloAIPostErrorKey;          // error message (post)
static char kApolloAICommentErrorKey;       // error message (comment)
static char kApolloAIPostSummaryNodeKey;
static char kApolloAICommentSummaryNodeKey;
static char kApolloAIHeaderFullNameKey;
static char kApolloAIPostSummaryBackgroundNodeKey;
static char kApolloAICommentSummaryBackgroundNodeKey;
static char kApolloAIPostExpandedKey;
static char kApolloAICommentExpandedKey;
static char kApolloAISummaryOwnerKey;
static char kApolloAISummaryIsPostKey;

static void ApolloAIForceHeaderRemeasure(NSString *fullName);

static UIColor *ApolloAISummaryThemeAccent(id headerNode) {
    NSString *fullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
    UIViewController *vc = [sControllerByFullName objectForKey:fullName];
    NSArray<UIColor *> *candidates = @[
        vc.navigationController.navigationBar.tintColor ?: UIColor.clearColor,
        vc.tabBarController.tabBar.tintColor ?: UIColor.clearColor,
        vc.view.tintColor ?: UIColor.clearColor,
        vc.view.window.tintColor ?: UIColor.clearColor,
    ];
    for (UIColor *candidate in candidates) {
        if (candidate && candidate != UIColor.clearColor) return candidate;
    }
    return UIColor.systemBlueColor;
}

// A baseline-aligned SF Symbol as an attributed string, sized to `font` and
// tinted `tint`. Returns nil if the symbol is unavailable so callers can fall
// back to a plain glyph.
static NSAttributedString *ApolloAISymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:font];
        UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
        if (image) {
            image = [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = image;
            // Center the glyph on the font's cap height so it sits on the text
            // baseline rather than floating above it.
            CGFloat y = (font.capHeight - image.size.height) / 2.0;
            attachment.bounds = CGRectMake(0, y, image.size.width, image.size.height);
            return [NSAttributedString attributedStringWithAttachment:attachment];
        }
    }
    return nil;
}

static NSAttributedString *ApolloAISummaryAttributedText(NSString *title,
                                                         ApolloAIBoxState state,
                                                         NSString *bodyText,
                                                         BOOL expanded,
                                                         BOOL isPost,
                                                         NSUInteger sourceCount,
                                                         UIColor *accent) {
    if (state == ApolloAIBoxStateNone) return nil;

    UIColor *secondary = nil;
    UIColor *tertiary = nil;
    if (@available(iOS 13.0, *)) {
        secondary = UIColor.secondaryLabelColor;
        tertiary = UIColor.tertiaryLabelColor;
    } else {
        secondary = UIColor.darkGrayColor;
        tertiary = UIColor.grayColor;
    }
    UIColor *errorColor = UIColor.systemOrangeColor;

    accent = accent ?: UIColor.systemBlueColor;
    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    UIFont *chevronFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIFont *captionFont = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: titleFont,
        NSForegroundColorAttributeName: accent,
    };
    NSDictionary *chevronAttributes = @{
        NSFontAttributeName: chevronFont,
        NSForegroundColorAttributeName: secondary,
    };
    NSDictionary *bodyAttributes = @{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
        NSForegroundColorAttributeName: state == ApolloAIBoxStateError ? errorColor : secondary,
    };
    NSDictionary *captionAttributes = @{
        NSFontAttributeName: captionFont,
        NSForegroundColorAttributeName: tertiary,
    };

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];

    // Leading icon — native SF Symbol, glyph fallback for < iOS 13. The error
    // state swaps in a warning glyph tinted to match the body.
    NSString *symbolName = isPost ? @"sparkles" : @"text.bubble.fill";
    UIColor *iconTint = accent;
    if (state == ApolloAIBoxStateError) { symbolName = @"exclamationmark.triangle.fill"; iconTint = errorColor; }
    NSAttributedString *iconAttachment = ApolloAISymbolAttachment(symbolName, titleFont, iconTint);
    if (iconAttachment) {
        [result appendAttributedString:iconAttachment];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:titleAttributes]];
    } else {
        NSString *glyph = isPost ? @"✦  " : @"◉  ";
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:glyph attributes:titleAttributes]];
    }
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:titleAttributes]];
    if (!expanded && state == ApolloAIBoxStateLoading) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ·  Summarizing…"
                                                                       attributes:chevronAttributes]];
    }

    // Trailing disclosure chevron.
    NSAttributedString *chevronAttachment =
        ApolloAISymbolAttachment(expanded ? @"chevron.down" : @"chevron.right", chevronFont, secondary);
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:chevronAttributes]];
    if (chevronAttachment) {
        [result appendAttributedString:chevronAttachment];
    } else {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:expanded ? @"▾" : @"▸"
                                                                       attributes:chevronAttributes]];
    }

    if (!expanded) return result;

    // Body (expanded). Loading shows streamed text if we have any, else a
    // placeholder; ready shows the summary + a trust caption; error shows the
    // message in the warning color.
    NSString *body = bodyText;
    if (state == ApolloAIBoxStateLoading && body.length == 0) {
        body = isPost ? @"Summarizing…" : @"Summarizing discussion…";
    } else if (state == ApolloAIBoxStateError && body.length == 0) {
        body = @"Couldn't generate this summary.";
    }
    if (body.length > 0) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:bodyAttributes]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:body attributes:bodyAttributes]];
    }
    if (state == ApolloAIBoxStateReady) {
        // Quiet trust/expectation footer so the summary isn't mistaken for the
        // author's own words.
        NSString *caption = (!isPost && sourceCount > 0)
            ? [NSString stringWithFormat:@"\n\nAI-generated · Based on %lu representative comments · may be inaccurate",
                                         (unsigned long)sourceCount]
            : @"\n\nAI-generated · may be inaccurate";
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:caption
                                                                       attributes:captionAttributes]];
    }
    return result;
}

static void ApolloAIRenderSummaryNode(id headerNode, BOOL isPost);

static ASTextNode *ApolloAIEnsureSummaryNode(id headerNode, BOOL isPost) {
    const void *key = isPost ? &kApolloAIPostSummaryNodeKey : &kApolloAICommentSummaryNodeKey;
    ASTextNode *textNode = objc_getAssociatedObject(headerNode, key);
    if (textNode) return textNode;

    Class textNodeClass = NSClassFromString(@"ASTextNode");
    if (!textNodeClass) return nil;
    textNode = [[textNodeClass alloc] init];
    textNode.maximumNumberOfLines = 0;
    textNode.userInteractionEnabled = YES;
    objc_setAssociatedObject(textNode, &kApolloAISummaryOwnerKey, headerNode, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(textNode, &kApolloAISummaryIsPostKey, @(isPost), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ASTextNode *weakTextNode = textNode;
    [textNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASTextNode *strongTextNode = weakTextNode;
        id owner = objc_getAssociatedObject(strongTextNode, &kApolloAISummaryOwnerKey);
        if (!owner || !strongTextNode.view) return;
        SEL action = isPost ? NSSelectorFromString(@"apollo_togglePostSummary")
                            : NSSelectorFromString(@"apollo_toggleDiscussionSummary");
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:owner action:action];
        [strongTextNode.view addGestureRecognizer:tap];
        strongTextNode.view.accessibilityTraits |= UIAccessibilityTraitButton;
        strongTextNode.view.accessibilityLabel = isPost ? @"Post summary" : @"Discussion so far";
    }];
    [headerNode addSubnode:textNode];
    objc_setAssociatedObject(headerNode, key, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return textNode;
}

static ASDisplayNode *ApolloAIEnsureBackgroundNode(id headerNode, BOOL isPost) {
    const void *key = isPost ? &kApolloAIPostSummaryBackgroundNodeKey
                             : &kApolloAICommentSummaryBackgroundNodeKey;
    ASDisplayNode *background = objc_getAssociatedObject(headerNode, key);
    if (background) return background;

    background = [[NSClassFromString(@"ASDisplayNode") alloc] init];
    UIColor *accent = ApolloAISummaryThemeAccent(headerNode);
    background.backgroundColor = [accent colorWithAlphaComponent:0.10];
    background.cornerRadius = 12.0;
    background.clipsToBounds = YES;
    background.borderWidth = 0.5;
    background.borderColor = [accent colorWithAlphaComponent:0.24].CGColor;
    [headerNode addSubnode:background];
    objc_setAssociatedObject(headerNode, key, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return background;
}

static ApolloAIBoxState ApolloAIGetBoxState(id headerNode, BOOL isPost) {
    const void *stateKey = isPost ? &kApolloAIPostStateKey : &kApolloAICommentStateKey;
    return (ApolloAIBoxState)[objc_getAssociatedObject(headerNode, stateKey) integerValue];
}

static void ApolloAIRenderSummaryNode(id headerNode, BOOL isPost) {
    if (!headerNode) return;
    const void *summaryKey = isPost ? &kApolloAIPostSummaryKey : &kApolloAICommentSummaryKey;
    const void *errorKey = isPost ? &kApolloAIPostErrorKey : &kApolloAICommentErrorKey;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;
    ApolloAIBoxState state = ApolloAIGetBoxState(headerNode, isPost);
    if (state == ApolloAIBoxStateNone) return;
    BOOL expanded = [objc_getAssociatedObject(headerNode, expandedKey) boolValue];
    NSString *body = state == ApolloAIBoxStateError
        ? objc_getAssociatedObject(headerNode, errorKey)
        : objc_getAssociatedObject(headerNode, summaryKey);
    NSString *fullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
    NSUInteger sourceCount = isPost ? 0 : [sCommentSummarySourceCounts[fullName] unsignedIntegerValue];
    ASTextNode *textNode = ApolloAIEnsureSummaryNode(headerNode, isPost);
    NSString *title = isPost ? @"Post summary" : @"Discussion so far";
    textNode.attributedText = ApolloAISummaryAttributedText(
        title, state, body, expanded, isPost, sourceCount, ApolloAISummaryThemeAccent(headerNode));

    // VoiceOver: read the title + current body (summary / status / error) and
    // announce the collapsed/expanded state. Setting the label on the view
    // overrides the text node default, which would read only the title glyphs.
    UIView *nodeView = textNode.view;
    if (nodeView) {
        nodeView.accessibilityTraits |= UIAccessibilityTraitButton;
        NSString *spoken = body.length ? body : (state == ApolloAIBoxStateLoading ? @"Summarizing" : @"");
        nodeView.accessibilityLabel = expanded
            ? [NSString stringWithFormat:@"%@. %@", title, spoken]
            : [NSString stringWithFormat:@"%@, collapsed", title];
        nodeView.accessibilityHint = @"Double tap to expand or collapse";
    }
}

// Single source of truth for a box: set its state (+ ready/streamed text or
// error message) and re-render. No-ops if nothing changed so we don't trigger
// redundant relayouts.
static void ApolloAISetBoxState(id headerNode, BOOL isPost, ApolloAIBoxState state, NSString *text) {
    if (!headerNode) return;
    const void *stateKey = isPost ? &kApolloAIPostStateKey : &kApolloAICommentStateKey;
    const void *summaryKey = isPost ? &kApolloAIPostSummaryKey : &kApolloAICommentSummaryKey;
    const void *errorKey = isPost ? &kApolloAIPostErrorKey : &kApolloAICommentErrorKey;
    const void *textKey = (state == ApolloAIBoxStateError) ? errorKey : summaryKey;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;

    ApolloAIBoxState oldState = ApolloAIGetBoxState(headerNode, isPost);
    NSString *oldText = objc_getAssociatedObject(headerNode, textKey);
    if (oldState == state && (text == oldText || [text isEqualToString:oldText])) return;

    // Collapsed by default so opening a comments view remains visually stable.
    // Generation and streaming still begin immediately in the background; the
    // compact title shows "Summarizing…" until the result is ready. Once the
    // user toggles it, that explicit choice is preserved on this header.
    if (!objc_getAssociatedObject(headerNode, expandedKey)) {
        objc_setAssociatedObject(headerNode, expandedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(headerNode, stateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(headerNode, textKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloAIEnsureSummaryNode(headerNode, isPost);
    ApolloAIEnsureBackgroundNode(headerNode, isPost);
    ApolloAIRenderSummaryNode(headerNode, isPost);
    [headerNode invalidateCalculatedLayout];
    [headerNode setNeedsLayout];
}

static void ApolloAISetBoxStateOnMatchingHeaders(NSString *fullName, BOOL isPost, ApolloAIBoxState state, NSString *text) {
    if (fullName.length == 0) return;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (headerFullName.length == 0) {
            headerFullName = ApolloAILinkFullName(ApolloAIScanForLink(headerNode));
        }
        if ([headerFullName isEqualToString:fullName]) {
            ApolloAISetBoxState(headerNode, isPost, state, text);
        }
    }
}

// Promote idle (none) boxes for this post to the loading state, without
// disturbing a box that is already loading/ready/errored (so we never wipe
// streamed text or downgrade a finished summary).
static void ApolloAIShowLoadingIfIdle(NSString *fullName, BOOL isPost) {
    if (fullName.length == 0) return;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (![headerFullName isEqualToString:fullName]) continue;
        if (ApolloAIGetBoxState(headerNode, isPost) == ApolloAIBoxStateNone) {
            ApolloAISetBoxState(headerNode, isPost, ApolloAIBoxStateLoading, nil);
        }
    }
}

// Apply the current known state of a post to a (re)appearing header — used when
// a header cell loads mid-generation or is recycled, so it doesn't show a blank
// box. Mirrors the caches / in-flight / failed bookkeeping.
static void ApolloAIRestoreStateForHeader(id headerNode, NSString *fullName) {
    if (!headerNode || fullName.length == 0) return;
    if (sPostSummaryCache[fullName].length > 0) {
        ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateReady, sPostSummaryCache[fullName]);
    } else if ([sPostFailed containsObject:fullName]) {
        ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateError, nil);
    } else if ([sPostInFlight containsObject:fullName]) {
        ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateLoading, nil);
    }
    if (sCommentSummaryCache[fullName].length > 0) {
        ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateReady, sCommentSummaryCache[fullName]);
    } else if ([sCommentFailed containsObject:fullName]) {
        ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateError, nil);
    } else if ([sCommentInFlight containsObject:fullName] ||
               [sCapturedComments[fullName] count] >= kApolloAIMinComments) {
        ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateLoading, nil);
    }
}

// Short, user-facing message for a generation error shown inside the box. The
// bridge classifies thrown FoundationModels errors into stable codes (see
// ApolloFoundationModels.classify); we branch on those rather than on the
// localized text, which differs per language.
static NSString *ApolloAIFriendlyError(NSError *error) {
    switch (error.code) {
        case 1:
            return @"Apple Intelligence isn't enabled. Turn it on in Settings, and make sure your device and Siri language match a supported language.";
        case 2:
            return @"The on-device model is still downloading. Try again shortly.";
        case 7:
            return @"The model declined to summarize this content.";
        case 8:
            return @"This thread is too long to summarize on-device.";
        case 10:
            return @"Summaries aren't available for this language yet.";
        default:
            break;
    }
    // Last-resort fallback for an uncategorized error (e.g. a non-bridge NSError).
    NSString *d = error.localizedDescription ?: @"";
    if ([d localizedCaseInsensitiveContainsString:@"not enabled"])
        return @"Apple Intelligence isn't enabled. Turn it on in Settings, and make sure your device and Siri language match a supported language.";
    if ([d localizedCaseInsensitiveContainsString:@"download"])
        return @"The on-device model is still downloading. Try again shortly.";
    return @"Couldn't generate this summary.";
}

// Code 9 = rate-limited / concurrent-request throttling: the model is busy, not
// a hard failure, so the caller retries shortly instead of showing an error.
static BOOL ApolloAIErrorIsTransientConcurrency(NSError *error) {
    return error.code == 9;
}

static void ApolloAIForceHeaderRemeasure(NSString *fullName) {
    UIViewController *vc = [sControllerByFullName objectForKey:fullName];
    UITableView *tableView = ApolloAICommentsTableView(vc);
    if (!tableView) return;

    // Texture has already cached the row's old height. begin/end updates asks
    // the backing UITableView to query the node's newly invalidated layout.
    [tableView beginUpdates];
    [tableView endUpdates];
    ApolloLog(@"[AISummary][UI] requested header remeasure for %@", fullName);
}

// Is any live header for this post currently showing the expanded body of the
// given summary type? If not, streaming text into it changes nothing visible
// (the collapsed card shows only its title), so we can skip the expensive
// full-table remeasure entirely while still keeping the cached text current.
static BOOL ApolloAIAnyHeaderExpanded(NSString *fullName, BOOL isPost) {
    if (fullName.length == 0) return NO;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (![headerFullName isEqualToString:fullName]) continue;
        if ([objc_getAssociatedObject(headerNode, expandedKey) boolValue]) return YES;
    }
    return NO;
}

// Grow the box token-by-token as the model streams, so it feels responsive
// rather than sitting on a placeholder until done. Throttled, and the table
// remeasure only fires when the box is expanded (its height actually tracks the
// growing text), keeping the relayout churn in check.
static const BOOL kApolloAIStreamPartialsToUI = YES;

static void ApolloAIApplyStreamingPartial(NSString *fullName, BOOL isPost, NSString *partial) {
    if (!kApolloAIStreamPartialsToUI) return;
    if (fullName.length == 0 || partial.length < 40) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", isPost ? @"post" : @"comment", fullName];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval last = sLastPartialUIUpdate[key].doubleValue;
    if (last > 0 && now - last < 0.25) return;
    sLastPartialUIUpdate[key] = @(now);

    NSString *normalized = ApolloAINormalizeGeneratedSummary(partial);
    // Stream into the (already-visible) loading box. Only pay for a remeasure
    // when expanded, since the collapsed box height doesn't track the text.
    ApolloAISetBoxStateOnMatchingHeaders(fullName, isPost, ApolloAIBoxStateLoading, normalized);
    if (ApolloAIAnyHeaderExpanded(fullName, isPost)) {
        ApolloAIForceHeaderRemeasure(fullName);
    }
}

static void ApolloAIScheduleCommentGeneration(UIViewController *vc) {
    if (!vc || !sEnableAISummaries) return;
    NSString *fullName = ApolloAIFullNameForController(vc);
    if (fullName.length == 0 || [sCommentGenerationScheduled containsObject:fullName]) return;
    [sCommentGenerationScheduled addObject:fullName];

    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sCommentGenerationScheduled removeObject:fullName];
        UIViewController *strongVC = weakVC;
        if (!strongVC || !strongVC.view.window) return;
        ApolloAIGenerateForController(strongVC);
    });
}

static void ApolloAIScheduleGenerationTimeout(NSString *fullName, BOOL isPost, NSString *requestID) {
    if (fullName.length == 0 || requestID.length == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloAIGenerationTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSMutableSet *inFlight = isPost ? sPostInFlight : sCommentInFlight;
        NSMutableDictionary *requestIDs = isPost ? sPostRequestIDs : sCommentRequestIDs;
        if (![inFlight containsObject:fullName] ||
            ![requestIDs[fullName] isEqualToString:requestID]) return;
        [sTimedOutRequests addObject:requestID];
        [inFlight removeObject:fullName];
        [requestIDs removeObjectForKey:fullName];
        [(ApolloFoundationModels *)ApolloAIBridge() cancelRequest:requestID];
        NSMutableSet *failed = isPost ? sPostFailed : sCommentFailed;
        [failed addObject:fullName];
        ApolloAISetBoxStateOnMatchingHeaders(
            fullName, isPost, ApolloAIBoxStateError,
            @"This summary took too long. Reopen the post to try again.");
        if (ApolloAIAnyHeaderExpanded(fullName, isPost)) {
            ApolloAIForceHeaderRemeasure(fullName);
        }
        ApolloLog(@"[AISummary] %@ summary timed out for %@",
                  isPost ? @"post" : @"comment", fullName);
    });
}

static void ApolloAIRegisterHeaderNodeForFullName(id headerNode, NSString *knownFullName) {
    if (!headerNode) return;
    ApolloAIEnsureState();
    [sHeaderNodes addObject:headerNode];

    NSString *fullName = knownFullName;
    if (fullName.length == 0) {
        fullName = ApolloAILinkFullName(ApolloAIScanForLink(headerNode));
    }
    if (fullName.length == 0) return;
    objc_setAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloAIRestoreStateForHeader(headerNode, fullName);
    ApolloLog(@"[AISummary][UI] registered header=%p fullName=%@ post=%lu comment=%lu",
              headerNode, fullName,
              (unsigned long)sPostSummaryCache[fullName].length,
              (unsigned long)sCommentSummaryCache[fullName].length);
}

static void ApolloAIRegisterHeaderNode(id headerNode) {
    ApolloAIRegisterHeaderNodeForFullName(headerNode, nil);
}

static id ApolloAISummaryLayoutSpec(id textNode, id backgroundNode) {
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    Class backgroundClass = NSClassFromString(@"ASBackgroundLayoutSpec");
    if (!insetClass || !backgroundClass || !textNode || !backgroundNode) return nil;
    id inner = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(12.0, 14.0, 12.0, 14.0)
                                               child:textNode];
    id card = [backgroundClass backgroundLayoutSpecWithChild:inner background:backgroundNode];
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(8.0, 12.0, 8.0, 12.0)
                                           child:card];
}

static ASStackLayoutSpec *ApolloAICloneStackWithSummaries(ASStackLayoutSpec *originalStack,
                                                          id postSummarySpec,
                                                          id discussionSummarySpec) {
    if (!originalStack || (!postSummarySpec && !discussionSummarySpec)) return nil;
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    NSMutableArray *children = [NSMutableArray arrayWithArray:originalStack.children ?: @[]];

    if (postSummarySpec) {
        // Apollo's self-post header is:
        // PostTitleNode -> MarkdownNode -> PostInfoNode -> actions/separators.
        // Insert directly before MarkdownNode so the summary sits between the
        // title/flair and the original post body.
        NSUInteger bodyIndex = NSNotFound;
        Class markdownClass = NSClassFromString(@"_TtC6Apollo12MarkdownNode");
        for (NSUInteger i = 0; i < children.count; i++) {
            id child = children[i];
            if ((markdownClass && [child isKindOfClass:markdownClass]) ||
                [NSStringFromClass([child class]) isEqualToString:@"Apollo.MarkdownNode"]) {
                bodyIndex = i;
                break;
            }
        }
        if (bodyIndex == NSNotFound) bodyIndex = MIN((NSUInteger)1, children.count);
        [children insertObject:postSummarySpec atIndex:bodyIndex];
    }

    // Keep the discussion summary in the established bottom-of-post position,
    // after Apollo's original content/actions and immediately before comments.
    if (discussionSummarySpec) [children addObject:discussionSummarySpec];

    ASStackLayoutSpec *newStack =
        [stackClass stackLayoutSpecWithDirection:originalStack.direction
                                        spacing:originalStack.spacing
                                 justifyContent:originalStack.justifyContent
                                     alignItems:originalStack.alignItems
                                       children:children];
    newStack.flexWrap = originalStack.flexWrap;
    newStack.alignContent = originalStack.alignContent;
    newStack.lineSpacing = originalStack.lineSpacing;
    return newStack;
}

// Preserve Apollo's root width/inset semantics. The comments header currently
// returns ASInsetLayoutSpec -> ASStackLayoutSpec; recurse through inset wrappers
// and only replace the existing stack with a property-for-property clone.
static id ApolloAIPlaceSummariesPreservingRoot(id rootSpec,
                                               id postSummarySpec,
                                               id discussionSummarySpec) {
    if (!rootSpec || (!postSummarySpec && !discussionSummarySpec)) return nil;

    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (stackClass && [rootSpec isKindOfClass:stackClass]) {
        return ApolloAICloneStackWithSummaries((ASStackLayoutSpec *)rootSpec,
                                               postSummarySpec,
                                               discussionSummarySpec);
    }

    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    if (insetClass && [rootSpec isKindOfClass:insetClass]) {
        ASInsetLayoutSpec *originalInset = (ASInsetLayoutSpec *)rootSpec;
        id newChild = ApolloAIPlaceSummariesPreservingRoot(originalInset.child,
                                                           postSummarySpec,
                                                           discussionSummarySpec);
        if (!newChild) return nil;
        return [insetClass insetLayoutSpecWithInsets:originalInset.insets child:newChild];
    }

    return nil;
}

static void ApolloAILogLayoutChildrenOnce(id headerNode, id rootSpec) {
    static NSHashTable *loggedHeaders;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loggedHeaders = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (loggedHeaders) {
        if ([loggedHeaders containsObject:headerNode]) return;
        [loggedHeaders addObject:headerNode];
    }

    id current = rootSpec;
    NSUInteger depth = 0;
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    while (insetClass && [current isKindOfClass:insetClass] && depth < 8) {
        current = ((ASInsetLayoutSpec *)current).child;
        depth++;
    }
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (![current isKindOfClass:stackClass]) {
        ApolloLog(@"[AISummary][layout] root=%@ unwrapped=%@",
                  NSStringFromClass([rootSpec class]), NSStringFromClass([current class]));
        return;
    }

    NSArray *children = ((ASStackLayoutSpec *)current).children ?: @[];
    NSMutableArray *classes = [NSMutableArray arrayWithCapacity:children.count];
    for (id child in children) {
        [classes addObject:NSStringFromClass([child class]) ?: @"nil"];
    }
    ApolloLog(@"[AISummary][layout] root=%@ insetDepth=%lu children=%@",
              NSStringFromClass([rootSpec class]), (unsigned long)depth, classes);
}

#pragma mark - Generation

static NSString *ApolloAIRequestIdentifier(NSString *fullName, BOOL isPost) {
    return [NSString stringWithFormat:@"%@|%@", isPost ? @"post" : @"comment", fullName ?: @"unknown"];
}

static NSString *ApolloAIProvisionalPostRequestIdentifier(UIViewController *vc) {
    NSString *existing = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
    if (existing.length > 0) return existing;
    NSString *identifier = [NSString stringWithFormat:@"post|controller-%p", vc];
    objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey,
                             identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
}

static NSString *ApolloAIProvisionalCommentRequestIdentifier(UIViewController *vc) {
    NSString *existing = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
    if (existing.length > 0) return existing;
    NSString *identifier = [NSString stringWithFormat:@"comment|controller-%p", vc];
    objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey,
                             identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
}

// Called in viewWillAppear, before the header is on screen and before comments
// finish loading. This gives the actual instructed post session useful time to
// load model/guardrail assets. If there is no self-text, prepare the comments
// session instead.
static void ApolloAIPrepareForController(UIViewController *vc) {
    if (!vc || !sEnableAISummaries) return;
    ApolloFoundationModels *bridge = ApolloAIBridge();
    id link = ApolloAILinkFromController(vc);
    NSString *fullName = ApolloAILinkFullName(link);
    if (!bridge) return;

    // Apollo often has not attached the RDKLink yet at viewWillAppear. Prepare
    // a controller-scoped post session anyway; generation will either consume
    // it once the link resolves or discard it for a link/image post.
    if (!link || fullName.length == 0) {
        NSString *postID = ApolloAIProvisionalPostRequestIdentifier(vc);
        NSString *commentID = ApolloAIProvisionalCommentRequestIdentifier(vc);
        [bridge prepareSession:postID instructions:kApolloAIPostInstructions];
        [bridge prepareSession:commentID instructions:kApolloAICommentInstructions];
        ApolloLog(@"[AISummary] prepared provisional sessions post=%@ comment=%@", postID, commentID);
        return;
    }

    BOOL needsPost = ApolloAIPostText(link).length > 0 &&
        sPostSummaryCache[fullName].length == 0 &&
        ![sPostFailed containsObject:fullName];
    BOOL needsComments = sCommentSummaryCache[fullName].length == 0 &&
        ![sCommentFailed containsObject:fullName];
    if (needsPost) {
        [bridge prepareSession:ApolloAIRequestIdentifier(fullName, YES)
                  instructions:kApolloAIPostInstructions];
        ApolloLog(@"[AISummary] prepared POST session for %@", fullName);
    }
    if (needsComments) {
        [bridge prepareSession:ApolloAIRequestIdentifier(fullName, NO)
                  instructions:kApolloAICommentInstructions];
        ApolloLog(@"[AISummary] prepared COMMENT session for %@", fullName);
    }
}

static void ApolloAIGenerateForController(UIViewController *vc) {
    ApolloAIEnsureState();
    if (!sEnableAISummaries) return;

    ApolloFoundationModels *bridge = ApolloAIBridge();
    if (!bridge) { ApolloLog(@"[AISummary] bridge unavailable"); return; }
    // status 4 = FoundationModels framework absent (pre-iOS 26): genuinely
    // cannot run, so bail. For every other "unavailable" reason we DO NOT bail:
    // on iOS 27, `availabilityStatus` returns 1 (appleIntelligenceNotEnabled)
    // even when generation works fine (other clients summarize on the same
    // device), so we attempt anyway and let a real generation error be the gate.
    NSInteger status = [bridge availabilityStatus];
    if (status == 4) {
        ApolloLog(@"[AISummary] FoundationModels unavailable (status=4), skipping");
        return;
    }
    if (status != 0) {
        ApolloLog(@"[AISummary] availability reports status=%ld; attempting anyway (iOS 27 under-reports)", (long)status);
    }

    id link = ApolloAILinkFromController(vc);
    if (!link) { ApolloLog(@"[AISummary] no RDKLink on controller %@", [vc class]); return; }
    NSString *fullName = ApolloAILinkFullName(link);
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"_anon|%lu", (unsigned long)(uintptr_t)link];
    [sControllerByFullName setObject:vc forKey:fullName];

    // Bind the controller's authoritative link identity to the actual Texture
    // header node. Swift Optional ivar encodings can make a later header-only
    // link lookup fail even though this controller lookup succeeded.
    Class headerClass = NSClassFromString(@"_TtC6Apollo22CommentsHeaderCellNode");
    for (id node in ApolloAIAvailableNodes(vc)) {
        if (headerClass && [node isKindOfClass:headerClass]) {
            ApolloAIRegisterHeaderNodeForFullName(node, fullName);
        }
    }

    NSString *provisionalPostID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
    BOOL hasPostInput = ApolloAIPostText(link).length > 0;
    if (provisionalPostID.length > 0 &&
        (!hasPostInput || sPostSummaryCache[fullName].length > 0 || [sPostFailed containsObject:fullName])) {
        [bridge discardPreparedSession:provisionalPostID];
        objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSString *provisionalCommentID = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
    if (provisionalCommentID.length > 0 &&
        (sCommentSummaryCache[fullName].length > 0 || [sCommentFailed containsObject:fullName])) {
        [bridge discardPreparedSession:provisionalCommentID];
        objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    // ----- Post summary -----
    if (sPostSummaryCache[fullName].length > 0) {
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateReady, sPostSummaryCache[fullName]);
    } else if (![sPostInFlight containsObject:fullName] && ![sPostFailed containsObject:fullName]) {
        NSString *postText = ApolloAIPostText(link);
        if (postText.length > 0) {
            [sPostInFlight addObject:fullName];
            ApolloAIShowLoadingIfIdle(fullName, YES);   // box visible immediately
            ApolloAIForceHeaderRemeasure(fullName);
            ApolloLog(@"[AISummary] generating POST summary for %@ (%lu chars)…", fullName, (unsigned long)postText.length);
            NSString *requestID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
            if (requestID.length == 0) requestID = ApolloAIRequestIdentifier(fullName, YES);
            objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [bridge prepareSession:requestID instructions:kApolloAIPostInstructions];
            sPostRequestIDs[fullName] = requestID;
            ApolloAIScheduleGenerationTimeout(fullName, YES, requestID);
            [bridge summarize:postText
                   identifier:requestID
                 instructions:kApolloAIPostInstructions
       maximumResponseTokens:kApolloAIPostResponseTokens
                    onPartial:^(NSString *partial) {
                        ApolloAIApplyStreamingPartial(fullName, YES, partial);
                    }
                   onComplete:^(NSString *final, NSError *error) {
                        [sPostInFlight removeObject:fullName];
                        if ([sPostRequestIDs[fullName] isEqualToString:requestID]) {
                            [sPostRequestIDs removeObjectForKey:fullName];
                        }
                        if ([sTimedOutRequests containsObject:requestID]) {
                            [sTimedOutRequests removeObject:requestID];
                            return;
                        }
                        if (error.code == 6) return; // navigation cancellation
                        final = ApolloAINormalizeGeneratedSummary(final);
                        if (error || final.length == 0) {
                            if (ApolloAIErrorIsTransientConcurrency(error)) {
                                ApolloLog(@"[AISummary] post request deferred by model concurrency for %@", fullName);
                                UIViewController *controller = [sControllerByFullName objectForKey:fullName];
                                if (controller) {
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        ApolloAIGenerateForController(controller);
                                    });
                                }
                                return;
                            }
                            [sPostFailed addObject:fullName];
                            NSString *msg = error ? ApolloAIFriendlyError(error) : @"The model returned an empty summary.";
                            ApolloLog(@"[AISummary] post summary error: %@", error ? error.localizedDescription : @"(empty)");
                            ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateError, msg);
                            if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                                ApolloAIForceHeaderRemeasure(fullName);
                            }
                            return;
                        }
                        sPostSummaryCache[fullName] = final;
                        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateReady, final);
                        if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                            ApolloAIForceHeaderRemeasure(fullName);
                        }
                        ApolloAIPersistSummaries();
                        ApolloLog(@"[AISummary] POST summary DONE for %@:\n%@", fullName, final);
                    }];
        } else {
            NSString *provisionalID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
            if (provisionalID.length > 0) {
                [bridge discardPreparedSession:provisionalID];
                objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
            ApolloLog(@"[AISummary] no self-text to summarize for %@", fullName);
        }
    }

    // ----- Comment summary -----
    NSUInteger commentCount = 0;
    NSString *commentSignature = nil;
    NSString *commentText = ApolloAIGatherCommentText(vc, &commentCount, &commentSignature);
    NSString *cachedCommentSummary = sCommentSummaryCache[fullName];
    NSString *cachedCommentSignature = sCommentSummarySignatures[fullName];
    BOOL cacheMatches = cachedCommentSummary.length > 0 &&
        (commentSignature.length == 0 || [cachedCommentSignature isEqualToString:commentSignature]);
    if (cacheMatches) {
        ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateReady, cachedCommentSummary);
    } else if (![sCommentInFlight containsObject:fullName] &&
               ![sCommentFailed containsObject:fullName]) {
        if (cachedCommentSummary.length > 0 && commentSignature.length > 0) {
            [sCommentSummaryCache removeObjectForKey:fullName];
            [sCommentSummarySourceCounts removeObjectForKey:fullName];
            [sCommentSummarySignatures removeObjectForKey:fullName];
            ApolloLog(@"[AISummary] representative comments changed; regenerating %@", fullName);
        }
        ApolloLog(@"[AISummary] gathered %lu comments (%lu chars) for %@", (unsigned long)commentCount,
                  (unsigned long)commentText.length, fullName);
        BOOL hasEnoughDiscussion = commentCount >= kApolloAIMinComments &&
            commentText.length >= kApolloAIMinCommentChars;
        if (hasEnoughDiscussion) {
            ApolloAIShowLoadingIfIdle(fullName, NO);
            ApolloAIForceHeaderRemeasure(fullName);
        } else {
            // Small or low-content threads are faster to read directly. Never
            // leave a misleading loading card behind for them.
            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateNone, nil);
        }
        if (hasEnoughDiscussion) {
            [sCommentInFlight addObject:fullName];
            // Ground the discussion summary in the post it is replying to.
            NSString *context = ApolloAIPostContextForComments(link);
            NSString *commentPrompt = context.length > 0
                ? [NSString stringWithFormat:@"%@\nComments:\n%@", context, commentText]
                : commentText;
            ApolloLog(@"[AISummary] generating COMMENT summary for %@…", fullName);
            NSString *requestID = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
            if (requestID.length == 0) requestID = ApolloAIRequestIdentifier(fullName, NO);
            objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [bridge prepareSession:requestID instructions:kApolloAICommentInstructions];
            sCommentRequestIDs[fullName] = requestID;
            ApolloAIScheduleGenerationTimeout(fullName, NO, requestID);
            [bridge summarize:commentPrompt
                   identifier:requestID
                 instructions:kApolloAICommentInstructions
       maximumResponseTokens:kApolloAICommentResponseTokens
                    onPartial:^(NSString *partial) {
                        ApolloAIApplyStreamingPartial(fullName, NO, partial);
                    }
                   onComplete:^(NSString *final, NSError *error) {
                        [sCommentInFlight removeObject:fullName];
                        if ([sCommentRequestIDs[fullName] isEqualToString:requestID]) {
                            [sCommentRequestIDs removeObjectForKey:fullName];
                        }
                        if ([sTimedOutRequests containsObject:requestID]) {
                            [sTimedOutRequests removeObject:requestID];
                            return;
                        }
                        if (error.code == 6) return; // navigation cancellation
                        final = ApolloAINormalizeGeneratedSummary(final);
                        if (error || final.length == 0) {
                            if (ApolloAIErrorIsTransientConcurrency(error)) {
                                ApolloLog(@"[AISummary] comment request deferred by model concurrency for %@", fullName);
                                UIViewController *controller = [sControllerByFullName objectForKey:fullName];
                                if (controller) {
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        ApolloAIGenerateForController(controller);
                                    });
                                }
                                return;
                            }
                            [sCommentFailed addObject:fullName];
                            NSString *msg = error ? ApolloAIFriendlyError(error) : @"The model returned an empty summary.";
                            ApolloLog(@"[AISummary] comment summary error: %@", error ? error.localizedDescription : @"(empty)");
                            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateError, msg);
                            if (ApolloAIAnyHeaderExpanded(fullName, NO)) {
                                ApolloAIForceHeaderRemeasure(fullName);
                            }
                            return;
                        }
                        sCommentSummaryCache[fullName] = final;
                        sCommentSummarySourceCounts[fullName] = @(commentCount);
                        if (commentSignature.length > 0) {
                            sCommentSummarySignatures[fullName] = commentSignature;
                        }
                        ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateReady, final);
                        if (ApolloAIAnyHeaderExpanded(fullName, NO)) {
                            ApolloAIForceHeaderRemeasure(fullName);
                        }
                        ApolloAIPersistSummaries();
                        // The summary is cached; we no longer need the raw comments.
                        [sCapturedComments removeObjectForKey:fullName];
                        [sCapturedCommentKeys removeObjectForKey:fullName];
                        ApolloLog(@"[AISummary] COMMENT summary DONE for %@:\n%@", fullName, final);
                    }];
        }
    }
}

#pragma mark - Diagnostics: comments table structure (informs UI placement)

static void ApolloAILogTableStructure(UIViewController *vc) {
    UITableView *tableView = ApolloAICommentsTableView(vc);
    NSArray *visibleNodes = ApolloAIAvailableNodes(vc);
    if (!tableView) {
        ApolloLog(@"[AISummary][struct] no UIKit table view; Texture visibleNodes=%lu firstNode=%@",
                  (unsigned long)visibleNodes.count,
                  visibleNodes.count ? NSStringFromClass([visibleNodes.firstObject class]) : @"(none)");
        return;
    }
    UIView *header = tableView.tableHeaderView;
    UIView *footer = tableView.tableFooterView;
    NSInteger sections = [tableView numberOfSections];
    NSInteger row0 = sections > 0 ? [tableView numberOfRowsInSection:0] : -1;

    NSString *row0NodeClass = @"(none)";
    NSArray<UITableViewCell *> *visible = [tableView visibleCells];
    if (visible.count > 0) {
        UITableViewCell *first = visible.firstObject;
        if ([first respondsToSelector:@selector(node)]) {
            id node = ((id (*)(id, SEL))objc_msgSend)(first, @selector(node));
            row0NodeClass = NSStringFromClass([node class]) ?: @"(nil node)";
        }
    }

    ApolloLog(@"[AISummary][struct] table=%@ headerView=%@ footerView=%@ sections=%ld rowsInSec0=%ld visibleCells=%lu firstNode=%@",
              NSStringFromClass([tableView class]),
              header ? NSStringFromClass([header class]) : @"nil",
              footer ? NSStringFromClass([footer class]) : @"nil",
              (long)sections, (long)row0, (unsigned long)visible.count, row0NodeClass);
}

#pragma mark - Hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloAIEnsureState();
    if (sEnableAISummaries) sVisibleCommentsController = (UIViewController *)self;
    ApolloAIPrepareForController((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!sEnableAISummaries) return;
    sVisibleCommentsController = (UIViewController *)self;

    ApolloAILogTableStructure((UIViewController *)self);
    ApolloAIGenerateForController((UIViewController *)self);

    // Comments/post often aren't loaded yet at viewDidAppear (network fetch in
    // flight, no cells rendered). Re-run on a staggered schedule so late-
    // arriving cells get summarized without forcing the user to scroll. The
    // in-flight/cache guards in ApolloAIGenerateForController keep this from
    // generating more than once per thread.
    NSArray<NSNumber *> *retryDelays = @[ @1.5, @4.0, @8.0 ];
    for (NSNumber *delay in retryDelays) {
        __weak UIViewController *weakSelf = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded || !strongSelf.view.window) return;
            if (!sEnableAISummaries) return;
            ApolloAIGenerateForController(strongSelf);
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    NSString *fullName = ApolloAIFullNameForController(vc);
    if (fullName.length > 0) {
        ApolloFoundationModels *bridge = ApolloAIBridge();
        NSString *activePostID = sPostRequestIDs[fullName] ?: ApolloAIRequestIdentifier(fullName, YES);
        NSString *activeCommentID = sCommentRequestIDs[fullName] ?: ApolloAIRequestIdentifier(fullName, NO);
        [bridge cancelRequest:activePostID];
        [bridge cancelRequest:activeCommentID];
        NSString *provisional = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
        if (provisional.length > 0) [bridge cancelRequest:provisional];
        NSString *provisionalComment = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
        if (provisionalComment.length > 0) [bridge cancelRequest:provisionalComment];
        [sPostInFlight removeObject:fullName];
        [sCommentInFlight removeObject:fullName];
        [sPostRequestIDs removeObjectForKey:fullName];
        [sCommentRequestIDs removeObjectForKey:fullName];
        [sPostFailed removeObject:fullName];
        [sCommentFailed removeObject:fullName];
        if (sPostSummaryCache[fullName].length == 0) {
            ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateNone, nil);
        }
        if (sCommentSummaryCache[fullName].length == 0) {
            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateNone, nil);
        }
    }
    if (sVisibleCommentsController == (UIViewController *)self) {
        sVisibleCommentsController = nil;
    }
}

%end

// Apollo creates comment section controllers from the loaded CommentTree before
// Texture necessarily creates their cells. Capturing here removes the multi-
// second dependency on scrolling/preloading and is the primary fast path.
%hook _TtC6Apollo24CommentSectionController

- (id)init {
    id result = %orig;
    if (sEnableAISummaries) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = sVisibleCommentsController;
            id comment = MSHookIvar<id>((id)result, "comment");
            if (!vc || !ApolloAICommentIsEligible(comment)) return;
            ApolloAICaptureCommentForController(comment, vc);
            ApolloAIScheduleCommentGeneration(vc);
        });
    }
    return result;
}

- (void)modelObjectUpdatedNotificationReceived:(id)notification {
    %orig;
    if (!sEnableAISummaries) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = sVisibleCommentsController;
        id comment = MSHookIvar<id>((id)self, "comment");
        if (!vc || !ApolloAICommentIsEligible(comment)) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    if (!sEnableAISummaries) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = sVisibleCommentsController;
        id comment = ApolloAICommentFromCellNode((id)self);
        if (!vc || !comment) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

- (void)didEnterPreloadState {
    %orig;
    if (!sEnableAISummaries) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = sVisibleCommentsController;
        id comment = ApolloAICommentFromCellNode((id)self);
        if (!vc || !comment) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    if (!sEnableAISummaries) return;
    ApolloAIRegisterHeaderNode((id)self);
}

- (void)didEnterDisplayState {
    %orig;
    if (!sEnableAISummaries) return;
    ApolloAIRegisterHeaderNode((id)self);
}

%new
- (void)apollo_togglePostSummary {
    BOOL expanded = [objc_getAssociatedObject((id)self, &kApolloAIPostExpandedKey) boolValue];
    objc_setAssociatedObject((id)self, &kApolloAIPostExpandedKey, @(!expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloAIRenderSummaryNode((id)self, YES);
    [(ASDisplayNode *)(id)self invalidateCalculatedLayout];
    [(ASDisplayNode *)(id)self setNeedsLayout];
    ApolloAIForceHeaderRemeasure(objc_getAssociatedObject((id)self, &kApolloAIHeaderFullNameKey));
}

%new
- (void)apollo_toggleDiscussionSummary {
    BOOL expanded = [objc_getAssociatedObject((id)self, &kApolloAICommentExpandedKey) boolValue];
    objc_setAssociatedObject((id)self, &kApolloAICommentExpandedKey, @(!expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloAIRenderSummaryNode((id)self, NO);
    [(ASDisplayNode *)(id)self invalidateCalculatedLayout];
    [(ASDisplayNode *)(id)self setNeedsLayout];
    ApolloAIForceHeaderRemeasure(objc_getAssociatedObject((id)self, &kApolloAIHeaderFullNameKey));
}

- (id)layoutSpecThatFits:(struct ApolloAISizeRange)constrainedSize {
    id originalSpec = %orig;
    if (!sEnableAISummaries) return originalSpec;
    ApolloAILogLayoutChildrenOnce((id)self, originalSpec);

    ApolloAIBoxState postState = ApolloAIGetBoxState((id)self, YES);
    ApolloAIBoxState commentState = ApolloAIGetBoxState((id)self, NO);
    if (postState == ApolloAIBoxStateNone && commentState == ApolloAIBoxStateNone) return originalSpec;
    ApolloLog(@"[AISummary][UI] composing header layout postState=%ld commentState=%ld",
              (long)postState, (long)commentState);

    id postSummarySpec = nil;
    id discussionSummarySpec = nil;
    if (postState != ApolloAIBoxStateNone) {
        ApolloAIEnsureSummaryNode((id)self, YES);
        ApolloAIEnsureBackgroundNode((id)self, YES);
        ApolloAIRenderSummaryNode((id)self, YES);
        postSummarySpec =
            ApolloAISummaryLayoutSpec(
                objc_getAssociatedObject((id)self, &kApolloAIPostSummaryNodeKey),
                objc_getAssociatedObject((id)self, &kApolloAIPostSummaryBackgroundNodeKey));
    }
    if (commentState != ApolloAIBoxStateNone) {
        ApolloAIEnsureSummaryNode((id)self, NO);
        ApolloAIEnsureBackgroundNode((id)self, NO);
        ApolloAIRenderSummaryNode((id)self, NO);
        discussionSummarySpec =
            ApolloAISummaryLayoutSpec(
                objc_getAssociatedObject((id)self, &kApolloAICommentSummaryNodeKey),
                objc_getAssociatedObject((id)self, &kApolloAICommentSummaryBackgroundNodeKey));
    }
    id newRoot = ApolloAIPlaceSummariesPreservingRoot(originalSpec,
                                                      postSummarySpec,
                                                      discussionSummarySpec);
    if (!newRoot) {
        ApolloLog(@"[AISummary][UI] incompatible header hierarchy rooted at %@; skipping summary injection",
                  NSStringFromClass([originalSpec class]));
        return originalSpec;
    }
    return newRoot;
}

%end

#if APOLLO_SIM_BUILD
// DEBUG ONLY — simulator builds only (gated by APOLLO_SIM_BUILD so it can never
// reach a device/release IPA): when the `AISummaryDebugURL` default is set to a
// reddit https URL, route Apollo to it shortly after launch using the app's own
// internal openURL path — no SpringBoard "Open in Apollo?" prompt. Lets the
// post/comment summary pipeline be exercised headlessly in the sim without UI
// tapping (idb HID is broken on Xcode 27 beta).
static void ApolloAIMaybeRouteDebugURL(void) {
    NSString *dbg = [[NSUserDefaults standardUserDefaults] stringForKey:@"AISummaryDebugURL"];
    if (dbg.length == 0) return;
    NSURL *url = [NSURL URLWithString:dbg];
    if (!url) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloLog(@"[AISummary][debug] routing to %@", dbg);
        ApolloRouteResolvedURLViaApolloScheme(url);
    });
}
#endif

%ctor {
    @autoreleasepool {
        ApolloAIEnsureState();
        ApolloFoundationModels *bridge = ApolloAIBridge();
        ApolloLog(@"[AISummary] loaded; bridge=%@ availabilityStatus=%ld",
                  bridge ? @"yes" : @"no", bridge ? (long)[bridge availabilityStatus] : -1);

#if APOLLO_SIM_BUILD
        ApolloAIMaybeRouteDebugURL();
#endif
    }
}

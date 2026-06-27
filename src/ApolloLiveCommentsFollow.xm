// ApolloLiveCommentsFollow.xm
//
// Makes Apollo's "Live Update" comment sort actually watchable on a busy thread
// (live sports, breaking news, etc).
//
// Native behavior: when Live Update sort is active, Apollo runs a 10s timer that
// fetches the 20 newest comments and INSERTS THEM AT THE TOP of the comment list,
// while preserving the user's reading position (content-offset compensation). The
// side effect is that new comments pile up OFF-SCREEN ABOVE the viewport — you never
// see them unless you keep manually scrolling up. (Confirmed via RE: the comments VC's
// `currentSort` ivar raw==8 == Live Update; the live tick calls
// commentsForLinkWithIdentifier:sort:3 limit:20 and merges newest-first.)
//
// This adds the standard live-stream UX on top of that, without fighting the native
// merge:
//   - FOLLOW mode (user at/near the "live edge" = top of the comment list): keep the
//     newest comment pinned to the top, so the latest are always visible and older ones
//     slide down. (This is the user's "push the older ones down" ask.)
//   - READ mode (user scrolled into older comments): the native position is left
//     untouched; a floating "N new comments" pill appears under the nav bar. Tapping it
//     jumps to the live edge and re-enters follow mode. Scrolling back to the top
//     yourself also re-arms follow mode.
//
// Two non-obvious facts drive the design (both found empirically in the sim):
//   1. The host VC's -viewDidLayoutSubviews does NOT fire when only the table NODE's
//      content changes (ASDK lays the node out itself). So new-comment arrival can't be
//      detected from layout — we drive everything from a lightweight poll loop instead
//      (the same generation-token poll pattern as ApolloInboxCommentScroll).
//   2. The "live edge" is NOT the absolute top: a match-thread post body can be ~1100pt
//      tall, so the newest COMMENT sits well below the absolute top. The live edge is the
//      first comment row, computed via rectForRowAtIndexPath, not -adjustedContentInset.top.
//
// Scope: only acts while Live Update sort is active (currentSort==8) and the
// sLiveCommentsFollow setting is on. The follow-mode contentOffset write is hard-gated on
// live mode, which is mutually exclusive with ApolloInboxCommentScroll's isolated-thread
// scope, so the two never fight over the same VC.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

// MARK: - tunables

static const NSTimeInterval kLCFPollInterval = 0.4;   // poll cadence while a live thread is on screen
static const CGFloat kLCFEdgeThreshold  = 24.0;       // within this of the live edge == "at the top"
static const CGFloat kLCFDriftThreshold = 4.0;        // only re-pin when offset drifts this far from edge
static const NSInteger kLCFCountCap     = 50;         // display "50+" past this
static const CGFloat kLCFPillTopMargin  = 8.0;        // gap below the nav bar / toolbar

// MARK: - per-VC state (associated objects) + generation token

static const void *kLCFGenKey       = &kLCFGenKey;       // NSNumber long: bumped each appear/disappear
static const void *kLCFFollowKey    = &kLCFFollowKey;    // NSNumber bool: follow mode (pin to edge)
static const void *kLCFEvalKey      = &kLCFEvalKey;      // NSNumber bool: did the first-live eval
static const void *kLCFAnchorKey    = &kLCFAnchorKey;    // NSString: fullName baseline (top comment when read began)
static const void *kLCFLastHKey     = &kLCFLastHKey;     // NSNumber double: contentSize.height last poll (stability)
static const void *kLCFCountKey     = &kLCFCountKey;     // NSNumber long: last displayed N (-2 == hidden)
static const void *kLCFWrapKey      = &kLCFWrapKey;      // UIView: pill shadow wrapper (reused)
static const void *kLCFButtonKey    = &kLCFButtonKey;    // UIButton: pill button (reused)

static long gLCFGen = 0;

static NSNumber *LCFNum(id vc, const void *key) { return objc_getAssociatedObject(vc, key); }
static void LCFSet(id vc, const void *key, id val) {
    objc_setAssociatedObject(vc, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL LCFBool(id vc, const void *key) { return [LCFNum(vc, key) boolValue]; }

// MARK: - runtime helpers

// Walk the superclass chain to read an object ivar (matches ApolloInboxCommentScroll).
static id LCFObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static ptrdiff_t LCFIvarOffset(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return ivar_getOffset(iv);
        cls = class_getSuperclass(cls);
    }
    return -1;
}

// Is the comments VC currently in Live Update sort?
//
// currentSort is an optional Swift enum (RDKCommentSortingMethod?). Layout read straight
// from Apollo's own code: a flag byte at offset+8 (bit0 set == .none), the raw Int at
// offset+0, raw==8 == Live Update. This is more robust than reading the `weak liveSortTimer`
// ivar (which would need swift_unknownObjectWeakLoadStrong, not object_getIvar).
static BOOL LCFIsLive(id vc) {
    ptrdiff_t off = LCFIvarOffset(vc, "currentSort");
    if (off < 0) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge const void *)vc;
    uint8_t nilFlag = *(base + off + 8);
    if (nilFlag & 0x1) return NO;            // .none
    int64_t raw = 0;
    memcpy(&raw, base + off, sizeof(raw));
    return raw == 8;                          // .liveUpdate
}

// Read a Swift.Bool / BOOL ivar (one inline byte) by walking the superclass chain.
static BOOL LCFReadBool(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return *(((uint8_t *)(__bridge void *)obj) + ivar_getOffset(iv)) != 0;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

// An isolated single-comment thread (Inbox permalink / continued thread). ApolloInboxCommentScroll
// owns the scroll position there, so this module stays dormant to avoid two contentOffset writers
// fighting on the same VC (matters if the user's default sort happens to be Live Update).
static BOOL LCFIsIsolatedThread(UIViewController *vc) {
    if (LCFObjectIvar(vc, "viewFullPostNode") != nil) return YES;
    if (LCFReadBool(vc, "continuingThread")) return YES;
    return NO;
}

static id LCFTableNode(id vc) { return LCFObjectIvar(vc, "tableNode"); }

static UITableView *LCFTableView(UIViewController *vc) {
    id tableNode = LCFTableNode(vc);
    if (tableNode) {
        SEL viewSel = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSel]) {
            UIView *v = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSel);
            if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        }
    }
    return nil;
}

static BOOL LCFScrollable(UITableView *tv) {
    CGFloat h = tv.contentSize.height;
    CGFloat insets = tv.adjustedContentInset.top + tv.adjustedContentInset.bottom;
    return (h + insets) > (tv.bounds.size.height + 1.0);
}

// fullName ("t1_xxx") of a comment cell node, or nil for header/footer/spinner/load-more rows.
static NSString *LCFNodeCommentFullName(id node) {
    id comment = LCFObjectIvar(node, "comment");   // RDKComment on _TtC6Apollo15CommentCellNode
    if (!comment) return nil;
    SEL fnSel = NSSelectorFromString(@"fullName");
    if (![comment respondsToSelector:fnSel]) return nil;
    NSString *fn = ((id (*)(id, SEL))objc_msgSend)(comment, fnSel);
    return [fn isKindOfClass:[NSString class]] ? fn : nil;
}

// Index path of the first (topmost) comment row, skipping the post header / summary / spinner.
// ASDK holds a node for every row eagerly, so this resolves even when below the fold.
static NSIndexPath *LCFFirstCommentIndexPath(id tableNode, UITableView *tv) {
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return nil;
    NSInteger sections = [tv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (LCFNodeCommentFullName(node)) return ip;
        }
    }
    return nil;
}

static NSString *LCFTopCommentFullName(UIViewController *vc) {
    id tableNode = LCFTableNode(vc);
    UITableView *tv = LCFTableView(vc);
    if (!tableNode || !tv) return nil;
    NSIndexPath *ip = LCFFirstCommentIndexPath(tableNode, tv);
    if (!ip) return nil;
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
    return LCFNodeCommentFullName(node);
}

// The "live edge" content offset: puts the FIRST comment row at the top of the viewport
// (just under the nav bar), so the newest comment is visible and the post header scrolls
// off above. Falls back to the absolute top when there are no comments yet. Clamped to
// the scrollable range.
static CGFloat LCFLiveEdgeOffset(UIViewController *vc, UITableView *tv) {
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    CGFloat maxOff = MAX(-insetTop, tv.contentSize.height - viewportH + insetBottom);

    id tableNode = LCFTableNode(vc);
    NSIndexPath *ip = LCFFirstCommentIndexPath(tableNode, tv);
    if (!ip) return -insetTop;   // no comments yet
    CGRect rr = [tv rectForRowAtIndexPath:ip];
    CGFloat desired = rr.origin.y - insetTop;
    return MIN(MAX(desired, -insetTop), maxOff);
}

static BOOL LCFAtEdge(UIViewController *vc, UITableView *tv) {
    return fabs(tv.contentOffset.y - LCFLiveEdgeOffset(vc, tv)) <= kLCFEdgeThreshold;
}

// Count comment rows currently ABOVE the anchored comment. Returns the count, or -1 if the
// anchor can't be found. Only rows with a `comment` ivar are counted, so the post header /
// footer / spinner / load-more are excluded, and collapse/expand below the anchor never
// changes the result.
static NSInteger LCFCountAboveAnchor(UIViewController *vc, NSString *anchor) {
    if (anchor.length == 0) return -1;
    id tableNode = LCFTableNode(vc);
    UITableView *tv = LCFTableView(vc);
    if (!tableNode || !tv) return -1;
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (![tableNode respondsToSelector:nodeSel]) return -1;
    NSInteger n = 0;
    NSInteger sections = [tv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, [NSIndexPath indexPathForRow:r inSection:s]);
            NSString *fn = LCFNodeCommentFullName(node);
            if (!fn) continue;                    // not a comment row
            if ([fn isEqualToString:anchor]) return n;
            n++;
        }
    }
    return -1;                                    // anchor gone
}

// MARK: - chrome geometry (ported from ApolloCommentsCollapse, same hooked VC)

static CGFloat LCFNavBarBottom(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return 0.0;
    CGFloat bottom = root.safeAreaInsets.top;
    UINavigationController *nav = vc.navigationController;
    if (nav && !nav.navigationBarHidden) {
        UINavigationBar *bar = nav.navigationBar;
        if (bar && !bar.hidden) {
            CGRect f = [root convertRect:bar.bounds fromView:bar];
            bottom = MAX(bottom, CGRectGetMaxY(f));
        }
    }
    return bottom;
}

// If Apollo's in-comments upper toolbar / search field is showing, sit below it.
static CGFloat LCFToolbarBottom(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return 0.0;
    UIView *host = LCFObjectIvar(vc, "upperToolbar");
    if (![host isKindOfClass:[UIView class]]) {
        UIView *search = LCFObjectIvar(vc, "searchTextField");
        if ([search isKindOfClass:[UIView class]] && search.superview && search.superview != root) {
            host = search.superview;
        } else {
            host = nil;
        }
    }
    if (host && !host.hidden && host.alpha > 0.01 && host.superview) {
        CGRect f = [root convertRect:host.frame fromView:host.superview];
        if (CGRectGetMinY(f) < CGRectGetHeight(root.bounds)) return CGRectGetMaxY(f);
    }
    return 0.0;
}

// MARK: - theming (ported from ApolloAISummary)

static UIColor *LCFThemeAccent(UIViewController *vc) {
    NSArray<UIColor *> *candidates = @[
        vc.navigationController.navigationBar.tintColor ?: UIColor.clearColor,
        vc.tabBarController.tabBar.tintColor ?: UIColor.clearColor,
        vc.view.tintColor ?: UIColor.clearColor,
        vc.view.window.tintColor ?: UIColor.clearColor,
    ];
    for (UIColor *c in candidates) {
        if (c && c != UIColor.clearColor) return c;
    }
    return UIColor.systemBlueColor;
}

static NSAttributedString *LCFSymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:font];
        UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
        if (image) {
            image = [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
            NSTextAttachment *att = [[NSTextAttachment alloc] init];
            att.image = image;
            CGFloat y = (font.capHeight - image.size.height) / 2.0;
            att.bounds = CGRectMake(0, y, image.size.width, image.size.height);
            return [NSAttributedString attributedStringWithAttachment:att];
        }
    }
    return nil;
}

// MARK: - pill view

static UIButton *LCFButton(UIViewController *vc) { return objc_getAssociatedObject(vc, kLCFButtonKey); }
static UIView *LCFWrap(UIViewController *vc) { return objc_getAssociatedObject(vc, kLCFWrapKey); }

// Create the pill (shadow wrapper + accent button) once and cache it on the VC.
static void LCFEnsurePill(UIViewController *vc) {
    if (LCFWrap(vc)) return;

    UIView *wrap = [[UIView alloc] initWithFrame:CGRectZero];
    wrap.userInteractionEnabled = YES;
    wrap.layer.masksToBounds = NO;                 // let the shadow show
    wrap.layer.shadowColor = UIColor.blackColor.CGColor;
    wrap.layer.shadowOpacity = 0.18;
    wrap.layer.shadowRadius = 6.0;
    wrap.layer.shadowOffset = CGSizeMake(0, 2);
    wrap.hidden = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    // contentEdgeInsets is deprecated on iOS 15+ in favor of UIButtonConfiguration, but the
    // device build floors at iOS 14 where UIButtonConfiguration doesn't exist.
    btn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
    btn.layer.masksToBounds = YES;                 // rounded fill
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [btn addTarget:vc action:@selector(apolloLCFPillTapped:) forControlEvents:UIControlEventTouchUpInside];

    [wrap addSubview:btn];
    [vc.view addSubview:wrap];

    objc_setAssociatedObject(vc, kLCFWrapKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kLCFButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Set the pill label (chevron-up + text) and re-apply the current theme accent.
static void LCFSetPillContent(UIViewController *vc, NSString *text) {
    UIButton *btn = LCFButton(vc);
    if (!btn) return;
    btn.backgroundColor = LCFThemeAccent(vc);

    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] init];
    NSAttributedString *chevron = LCFSymbolAttachment(@"chevron.up", btn.titleLabel.font, UIColor.whiteColor);
    if (chevron) {
        [title appendAttributedString:chevron];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
    }
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSFontAttributeName: btn.titleLabel.font,
    }]];
    [btn setAttributedTitle:title forState:UIControlStateNormal];
}

// Position the pill top-center, below the nav bar (and the in-comments toolbar if visible).
static void LCFLayoutPill(UIViewController *vc) {
    UIView *wrap = LCFWrap(vc);
    UIButton *btn = LCFButton(vc);
    if (!wrap || !btn || wrap.hidden) return;

    [btn sizeToFit];
    CGFloat h = btn.bounds.size.height;
    CGFloat w = btn.bounds.size.width;
    btn.layer.cornerRadius = h / 2.0;
    btn.frame = CGRectMake(0, 0, w, h);
    wrap.bounds = CGRectMake(0, 0, w, h);
    wrap.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:btn.bounds cornerRadius:h / 2.0].CGPath;

    CGFloat topY = MAX(LCFNavBarBottom(vc), LCFToolbarBottom(vc)) + kLCFPillTopMargin;
    wrap.center = CGPointMake(CGRectGetMidX(vc.view.bounds), topY + h / 2.0);
    [vc.view bringSubviewToFront:wrap];
}

static void LCFHidePill(UIViewController *vc) {
    UIView *wrap = LCFWrap(vc);
    LCFSet(vc, kLCFCountKey, @(-2));
    if (!wrap || wrap.hidden) return;
    [UIView animateWithDuration:0.2 animations:^{
        wrap.alpha = 0.0;
        wrap.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        // A show() may have run during this fade-out; only commit the hide if the pill is still
        // meant to be hidden (count sentinel still -2). Otherwise the stale completion would
        // wipe out the freshly re-shown pill.
        if ([LCFNum(vc, kLCFCountKey) longValue] == -2) {
            wrap.hidden = YES;
            wrap.transform = CGAffineTransformIdentity;
        }
    }];
}

static void LCFShowPill(UIViewController *vc, NSString *text, long countKey) {
    LCFEnsurePill(vc);
    UIView *wrap = LCFWrap(vc);
    if (!wrap) return;

    long prev = [LCFNum(vc, kLCFCountKey) longValue];
    if (prev == countKey && !wrap.hidden) return;   // unchanged — avoid relayout/re-anim churn

    BOOL wasHidden = wrap.hidden || prev == -2;
    LCFSetPillContent(vc, text);
    LCFSet(vc, kLCFCountKey, @(countKey));
    wrap.hidden = NO;                                // un-hide BEFORE layout so it gets sized/centered
    LCFLayoutPill(vc);

    if (wasHidden) {
        wrap.alpha = 0.0;
        wrap.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
            wrap.alpha = 1.0;
            wrap.transform = CGAffineTransformIdentity;
        } completion:nil];
        ApolloLog(@"[LiveFollow] pill shown: \"%@\"", text);
    } else {
        wrap.alpha = 1.0;                            // recover if a hide fade was mid-flight
        wrap.transform = CGAffineTransformIdentity;
    }
}

// Recount and show/hide the pill (READ mode). `hStable` == the comment list isn't mid-rebuild
// this poll (contentSize unchanged since last). Quiet unless the displayed value changes.
//
// The anchor baseline (the top comment when the user left the live edge) is the count origin.
// Selecting Live Update rebuilds the comment list, so a baseline captured during that churn is
// stale — we only (re)establish it when the list is stable, and re-establish if it falls out of
// the live window (n == -1).
static void LCFUpdatePill(UIViewController *vc, BOOL hStable) {
    UITableView *tv = LCFTableView(vc);
    if (!tv) return;

    NSString *anchor = objc_getAssociatedObject(vc, kLCFAnchorKey);
    NSInteger n = anchor.length ? LCFCountAboveAnchor(vc, anchor) : -1;

    if (n >= 1) {
        long shown = MIN(n, kLCFCountCap);
        NSString *text = (n > kLCFCountCap)
            ? [NSString stringWithFormat:@"%ld+ new comments", (long)kLCFCountCap]
            : [NSString stringWithFormat:@"%ld new comment%@", (long)n, (n == 1 ? @"" : @"s")];
        LCFShowPill(vc, text, shown);
        return;
    }

    if (n < 0 && hStable) {
        // Baseline missing or fell out of the live window — re-establish from the current
        // (stable) top comment so subsequent arrivals count from here.
        NSString *top = LCFTopCommentFullName(vc);
        if (top) {
            LCFSet(vc, kLCFAnchorKey, top);
            ApolloLog(@"[LiveFollow] baseline (re)established anchor=%@ h=%.0f", top, tv.contentSize.height);
        }
    }
    LCFHidePill(vc);   // n == 0 (caught up), or baseline just (re)set
}

// Pin the newest to the live edge (FOLLOW mode). Instant, drift-guarded.
static void LCFPinToEdge(UIViewController *vc) {
    UITableView *tv = LCFTableView(vc);
    if (!tv || !LCFScrollable(tv)) return;
    CGFloat edge = LCFLiveEdgeOffset(vc, tv);
    CGFloat cur = tv.contentOffset.y;
    if (fabs(cur - edge) > kLCFDriftThreshold) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, edge) animated:NO];
        ApolloLog(@"[LiveFollow] pinned to edge %.0f -> %.0f", cur, edge);
    }
}

// Snapshot the anchor (first comment fullName) at the follow->read transition.
static void LCFSnapshotAnchor(UIViewController *vc) {
    NSString *top = LCFTopCommentFullName(vc);
    LCFSet(vc, kLCFAnchorKey, top);
    ApolloLog(@"[LiveFollow] FOLLOW->READ, anchor=%@", top);
}

// Re-arm follow mode (user reached / jumped to the live edge).
static void LCFEnterFollow(UIViewController *vc) {
    BOOL was = LCFBool(vc, kLCFFollowKey);
    LCFSet(vc, kLCFFollowKey, @YES);
    LCFSet(vc, kLCFAnchorKey, nil);
    LCFHidePill(vc);
    if (!was) ApolloLog(@"[LiveFollow] entered FOLLOW (at live edge)");
}

// MARK: - poll loop (drives detection; the host VC's layout doesn't fire on node changes)

static void LCFScheduleTick(__weak UIViewController *weakVC, long gen);

static void LCFTick(__weak UIViewController *weakVC, long gen) {
    UIViewController *vc = weakVC;
    if (!vc) return;
    NSNumber *curGen = LCFNum(vc, kLCFGenKey);
    if (!curGen || curGen.longValue != gen) return;     // superseded by a newer appear/disappear
    if (!sLiveCommentsFollow) return;                   // toggled off — stop the loop

    // A compose/edit/share sheet (or any modal) is presented over the comments view — it stays
    // alive underneath, but we must not pin/scroll it or touch the pill while the user is typing.
    // Stand down and resume when the sheet dismisses (viewDidAppear restarts a fresh poll then).
    if (vc.presentedViewController) {
        LCFScheduleTick(weakVC, gen);
        return;
    }

    UITableView *tv = LCFTableView(vc);
    BOOL live = LCFIsLive(vc);

    if (!live || !tv || LCFIsIsolatedThread(vc)) {
        // Not live, no table, or an isolated thread (ApolloInboxCommentScroll's domain) — stay
        // dormant but keep polling cheaply so we notice when Live Update is turned on.
        if (!LCFWrap(vc).hidden) LCFHidePill(vc);
        LCFSet(vc, kLCFEvalKey, @NO);                   // re-evaluate next time live turns on
        LCFScheduleTick(weakVC, gen);
        return;
    }

    // First time we see live mode for this appearance: pick follow/read by real proximity to
    // the live edge (Apollo opens a thread already scrolled to the comment list top).
    if (!LCFBool(vc, kLCFEvalKey)) {
        LCFSet(vc, kLCFEvalKey, @YES);
        // Compute the live edge offset once and reuse it for both the proximity check and the
        // log line below — each LCFLiveEdgeOffset call enumerates ASTableNode rows.
        CGFloat edge = LCFLiveEdgeOffset(vc, tv);
        BOOL atEdge = fabs(tv.contentOffset.y - edge) <= kLCFEdgeThreshold;
        LCFSet(vc, kLCFFollowKey, @(atEdge));
        // Don't snapshot an anchor here: selecting Live Update rebuilds the comment list, so
        // any baseline captured now is stale. READ mode establishes it lazily once stable.
        LCFSet(vc, kLCFAnchorKey, nil);
        ApolloLog(@"[LiveFollow] live detected — initial mode=%@ (offset=%.0f edge=%.0f)",
                  atEdge ? @"FOLLOW" : @"READ", tv.contentOffset.y, edge);
    }

    // Never act while the user is touching/scrolling. Read the scroll view's own authoritative
    // state rather than a self-managed flag (which could get stuck if an end-callback is missed).
    if (tv.isTracking || tv.isDragging || tv.isDecelerating) {
        LCFScheduleTick(weakVC, gen);
        return;
    }

    // Track contentSize stability so READ mode only (re)establishes its baseline when the
    // list isn't mid-rebuild.
    double h = tv.contentSize.height;
    NSNumber *lastHN = LCFNum(vc, kLCFLastHKey);
    BOOL hStable = (lastHN != nil) && (fabs(h - lastHN.doubleValue) < 1.0);
    LCFSet(vc, kLCFLastHKey, @(h));

    if (LCFBool(vc, kLCFFollowKey)) {
        LCFPinToEdge(vc);                               // keep newest at the top
    } else if (LCFAtEdge(vc, tv)) {
        LCFEnterFollow(vc);                             // user scrolled back up to the live edge
    } else {
        LCFUpdatePill(vc, hStable);                     // recount new arrivals, show/hide pill
    }

    LCFScheduleTick(weakVC, gen);
}

static void LCFScheduleTick(__weak UIViewController *weakVC, long gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLCFPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCFTick(weakVC, gen);
    });
}

// MARK: - hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!sLiveCommentsFollow) return;

    long gen = ++gLCFGen;
    LCFSet(self, kLCFGenKey, @(gen));
    LCFSet(self, kLCFFollowKey, @YES);
    LCFSet(self, kLCFEvalKey, @NO);
    LCFSet(self, kLCFAnchorKey, nil);
    LCFSet(self, kLCFLastHKey, nil);
    LCFSet(self, kLCFCountKey, @(-2));
    UIView *wrap = LCFWrap((UIViewController *)self);
    if (wrap) wrap.hidden = YES;

    LCFScheduleTick((UIViewController *)self, gen);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (!sLiveCommentsFollow) return;
    LCFSet(self, kLCFGenKey, @(++gLCFGen));   // supersede the poll loop
    LCFHidePill((UIViewController *)self);
    LCFSet(self, kLCFAnchorKey, nil);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!sLiveCommentsFollow) return;
    if (![NSThread isMainThread]) return;
    // Only keep the pill anchored under the nav bar across rotations / chrome changes.
    // (Detection + pinning is driven by the poll loop, because this does not fire when the
    // table node's content changes.)
    if (!LCFWrap((UIViewController *)self).hidden) LCFLayoutPill((UIViewController *)self);
}

- (void)scrollViewWillBeginDragging:(id)scrollView {
    %orig;
    if (!sLiveCommentsFollow) return;
    UIViewController *vc = (UIViewController *)self;
    // Snapshot the anchor only on the follow->read transition, so dragging again while already
    // reading keeps the original "new since I left" baseline. (The poll skips pinning whenever
    // the scroll view reports it's tracking/dragging/decelerating, so no interacting flag here.)
    if (LCFIsLive(vc) && !LCFIsIsolatedThread(vc) && LCFBool(vc, kLCFFollowKey)) {
        LCFSet(vc, kLCFFollowKey, @NO);
        LCFSnapshotAnchor(vc);
    }
}

- (void)tintColorDidChange {
    %orig;
    if (!sLiveCommentsFollow) return;
    UIViewController *vc = (UIViewController *)self;
    UIView *wrap = LCFWrap(vc);
    if (wrap && !wrap.hidden) {
        UIButton *btn = LCFButton(vc);
        if (btn) btn.backgroundColor = LCFThemeAccent(vc);
    }
}

%new
- (void)apolloLCFPillTapped:(id)sender {
    UIViewController *vc = (UIViewController *)self;
    UITableView *tv = LCFTableView(vc);
    if (tv) {
        if (@available(iOS 10.0, *)) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
        // Instant jump (animated:NO): a smooth scroll would be immediately overtaken by the
        // poll's instant follow-pin, and the jump distance can be the full post-header height.
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, LCFLiveEdgeOffset(vc, tv)) animated:NO];
    }
    LCFEnterFollow(vc);
    ApolloLog(@"[LiveFollow] pill tapped — jumping to live edge");
}

%end

%ctor {
    ApolloLog(@"[LiveFollow] module loaded");
}

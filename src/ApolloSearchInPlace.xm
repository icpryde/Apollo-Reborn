// ApolloSearchInPlace.xm
//
// Goal: tapping the feed/subreddit search field should NOT move anything.
// Stock Apollo runs a "search takeover" on activation: it slides the nav bar up
// (a -88 transform), reparents + docks the ApolloSearchToolbar (the search field)
// to the top of the screen (growing it 45->99pt), and shrinks the feed table's
// top content-inset so the feed/search-results sit just under the docked field.
// We keep the field exactly where it rests and keep search fully functional:
// type and the results populate the feed in place, directly below the field.
//
// What we do (and nothing else — search content itself is Apollo's):
//   1. Block the nav bar's -88 slide *and* its alpha fade so the "Home" row stays
//      put and fully visible.
//   2. Pin the toolbar to its resting screen-Y and keep it 45pt tall (zero its
//      safe-area so the SwiftUI content doesn't inflate), and re-center Cancel.
//   3. Hold the feed table's top content-inset at the field's bottom PERMANENTLY
//      (both inactive and active). Apollo natively rests the field ~8pt tucked
//      under the nav row and shrinks the inset to the docked position on takeover;
//      holding it constant means the field rests just below the nav bar in both
//      states, so activation moves nothing and the results show below the field.
//
// Most of Apollo's geometry here is re-applied on every layout pass (Texture), so
// we intercept the setters; the toolbar/nav pins are gated on a "search active"
// flag, while the feed inset is held via a persistent reference to the feed.
//
// See docs/search-bar-shift-RE.md for the reverse engineering.

#import "ApolloCommon.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>

// NB: Apollo's classes are Swift, so the ObjC runtime names are mangled
// "_TtC6Apollo<len><Name>" and Logos %hook needs them verbatim (it emits
// objc_getClass("<name>") and the bare names would resolve to nil):
//   ASTableViewController     -> _TtC6Apollo21ASTableViewController
//   ApolloSearchToolbar       -> _TtC6Apollo19ApolloSearchToolbar
//   ApolloSearchBarTextField  -> _TtC6Apollo24ApolloSearchBarTextField
// (ASTableView is an AsyncDisplayKit ObjC class — plain name.)

// Resting screen-Y / height of the field-toolbar when NOT taken over. Tracked
// live from the toolbar's real frame (device / safe-area / scroll independent);
// defaults are only a fallback.
static CGFloat sInPlaceToolbarY = 116.0;
static CGFloat sInPlaceToolbarH = 45.0;

static BOOL sFeedSearchActive = NO;
// Set briefly during teardown to relax the focus-only offset pin so the feed can
// settle naturally as the keyboard dismisses.
static BOOL sDismissing = NO;
// YES once the USER has dragged the feed during a search session (reset on activation
// and when the feed returns to its top). While NO, Apollo's programmatic scroll-ups
// (on focus / on each keystroke) are clamped to the resting top so nothing visibly
// moves — notably a subreddit's banner, which Apollo otherwise scrolls up when you
// type. Once the user scrolls, we stop clamping so they can browse results freely.
static BOOL sFeedScrolledByUser = NO;
// Bumped on every activate/teardown so a stale teardown timer is ignored.
static int sSearchGen = 0;
// Armed on activation; consumed once to give the Cancel button a clean horizontal
// slide-in (replacing Apollo's diagonal one).
static BOOL sCancelNeedsIntro = NO;
// Captured on activation; __weak so a torn-down view auto-nils and the setter
// hooks fall through to %orig.
static __weak UIView *sActiveSearchToolbar = nil;
static __weak UINavigationBar *sActiveNavBar = nil;
static __weak UIViewController *sActiveSearchVC = nil;
static __weak UITextField *sActiveSearchField = nil;
// The searchable feed table — PERSISTENT (set whenever the search VC lays out,
// never cleared on teardown). We hold its top content-inset at the field's bottom
// in BOTH the inactive and active states, so the field always rests just below
// the nav bar and *nothing moves* when you tap it (active geometry == inactive
// geometry). __weak so it auto-nils if the feed is deallocated.
static __weak UIScrollView *sSearchFeed = nil;
// The feed VC's search toolbar (persistent; set when a feed VC lays out). The
// docked-toolbar pins key on THIS instance so they never touch the comment view's
// own search toolbar (which docks the same way but is Apollo's to manage).
static __weak UIView *sFeedToolbar = nil;

#pragma mark - Helpers

static id ivarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar v = class_getInstanceVariable(object_getClass(obj), name);
    return v ? object_getIvar(obj, v) : nil;
}

// YES only for the post-feed search controller (Home / subreddit) — the place the
// "search all posts for X" takeover happens.
//
// NB: `CommentsViewController` ALSO has isSearchable==YES and a `commentsSearch`
// ivar that is nil while idle (only set once a comment search is actually running),
// so `isSearchable && commentsSearch==nil` wrongly includes the idle comment view —
// which would make our persistent feed-inset pin treat the comment table as a feed.
// Exclude it by class. (Other tabs — Profile/Inbox — have isSearchable==NO.)
static BOOL isSearchableFeedVC(id vc) {
    if (!vc) return NO;
    const char *cls = object_getClassName(vc);
    if (cls && strstr(cls, "Comments")) return NO; // comment view, not the post feed
    BOOL isSearchable = NO;
    Ivar sv = class_getInstanceVariable(object_getClass(vc), "isSearchable");
    if (sv) isSearchable = *(BOOL *)((char *)(__bridge void *)vc + ivar_getOffset(sv));
    return isSearchable && ivarObject(vc, "commentsSearch") == nil;
}

// Apollo's feed table (tableNode.view, an ASTableView) — where search results
// are rendered in place of the feed while searching.
static UIScrollView *feedScrollView(UIViewController *vc) {
    id tableNode = ivarObject(vc, "tableNode");
    if (tableNode && [tableNode respondsToSelector:@selector(view)]) {
        UIView *v = [(id)tableNode view];
        if ([v isKindOfClass:[UIScrollView class]]) return (UIScrollView *)v;
    }
    return nil;
}

// The content-inset top that puts the feed/results just below the resting field.
// The feed uses contentInsetAdjustmentBehavior = Never, so adjustedContentInset
// == contentInset (safe area is NOT added) — set the field's bottom directly.
static CGFloat inPlaceInsetTop(UIScrollView *feed) {
    CGFloat extra = feed.adjustedContentInset.top - feed.contentInset.top; // 0 when Never
    CGFloat top = (sInPlaceToolbarY + sInPlaceToolbarH) - extra;
    return top < 0 ? 0 : top;
}

// The toolbar is "docked" while the takeover has reparented it onto the VC's view
// (i.e. its superview is NOT the feed scroll view). In that state we hold it at
// the in-place screen position; resting in the feed it rides the content normally.
// Keyed on the superview type so it engages the instant Apollo reparents it —
// BEFORE textFieldDidBeginEditing sets the active flag (~7ms later) — which is
// what kills the off-screen blank frame on tap.
static BOOL toolbarDocked(UIView *toolbar) {
    UIView *sup = [toolbar superview];
    return sup != nil && ![sup isKindOfClass:[UIScrollView class]];
}

// Only OUR feed toolbar, and only while docked. Excludes the comment view's search
// toolbar (different instance, never captured as sFeedToolbar).
static BOOL feedToolbarDocked(UIView *toolbar) {
    return toolbar == sFeedToolbar && toolbarDocked(toolbar);
}

// YES if this search toolbar belongs to a CommentsViewController — i.e. it's the
// "Find in Comments" find-in-page bar (not the post-feed search). Detected via the
// responder chain (toolbar -> _ASDisplayView -> CommentsViewController). Used to
// give that bar a solid backing while active so the comments don't bleed through.
static BOOL isCommentToolbar(UIView *v) {
    UIResponder *r = [v nextResponder];
    int guard = 0;
    while (r && guard++ < 40) {
        if ([r isKindOfClass:[UIViewController class]]) {
            const char *cls = object_getClassName(r);
            if (cls && strstr(cls, "Comments")) return YES;
        }
        r = [r nextResponder];
    }
    return NO;
}

// The round "X" glyph shown in place of the "Cancel" word. Cached (the symbol is
// theme-independent; the tint is applied on the button). Matches the look of the
// iOS 26 system search-bar cancel button.
static UIImage *roundXImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:12.0
                                                            weight:UIImageSymbolWeightBold];
        // Bake a neutral gray straight into the glyph (AlwaysOriginal) so it can never
        // render in Apollo's accent green — not even for the first frame of the slide-in,
        // which a template + per-pass tintColor briefly missed.
        img = [[UIImage systemImageNamed:@"xmark" withConfiguration:cfg]
                  imageWithTintColor:[UIColor colorWithWhite:0.62 alpha:1.0]
                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return img;
}

// Round-X geometry. The circle is pinned to the toolbar's right edge; the field is
// shrunk so it ends a clean gap to the LEFT of the circle (Apollo sizes the field
// flush to the cancel button — fine for a "Cancel" word, too cramped for a circle).
static const CGFloat kXSize        = 33.0;  // circle diameter
static const CGFloat kXRightMargin = 14.0;  // circle right edge -> toolbar right edge
static const CGFloat kXFieldGap    = 12.0;  // field right edge -> circle left edge

// Resting CENTER of the X circle in the toolbar's coords. Vertically centered on the
// FIELD (which sits in the top of the toolbar, not the toolbar's own middle), so it
// looks aligned with the search pill rather than floating low.
static CGPoint xRestCenter(UIView *toolbar, UITextField *field) {
    CGFloat cx = CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize / 2.0;
    CGFloat cy = field ? CGRectGetMidY(field.frame) : CGRectGetMidY(toolbar.bounds);
    return CGPointMake(cx, cy);
}

// The off-right translation that parks the circle fully past the toolbar's right edge
// (its starting point for the slide-in / ending point for the slide-out).
static CGFloat xSlideDistance(UIView *toolbar, CGPoint restCenter) {
    return CGRectGetWidth(toolbar.bounds) - (restCenter.x - kXSize / 2.0) + 6.0;
}

// Restyle Apollo's "Cancel" text button as a round X — the Liquid-Glass look the
// system search bar (Search tab) uses: clear the title, show the xmark glyph centered
// in a circular fill that matches the search-field pill. Runs every layout pass while
// active, and OWNS the button's geometry: it forces bounds + center (so Apollo can't
// move/resize it) and strips any animation Apollo adds to the button — Apollo otherwise
// drives a "diagonal" slide-in and a jump-to-the-left on dismiss. The slide is run
// separately as a TRANSFORM animation (keys "sipX…", preserved here) that composes with
// the forced center. Also re-asserts the tint each pass (Apollo re-tints it green) and
// shrinks the field to leave a gap before the circle.
static void styleCancelAsRoundX(UIButton *btn, UIView *toolbar, UITextField *field) {
    if (btn.currentImage == nil || btn.currentTitle.length > 0) {
        [btn setTitle:@"" forState:UIControlStateNormal];
        [btn setImage:roundXImage() forState:UIControlStateNormal];
        btn.backgroundColor = field.backgroundColor ?: [UIColor colorWithWhite:0.137 alpha:1.0];
        btn.layer.cornerRadius = kXSize / 2.0;
        btn.layer.masksToBounds = YES;
        btn.contentEdgeInsets = UIEdgeInsetsZero;
        btn.adjustsImageWhenHighlighted = NO;
    }
    if (btn.alpha < 1.0) btn.alpha = 1.0; // Apollo fades it out on dismiss; keep it opaque so the slide-out shows

    // Own the geometry: a fixed-size circle at its resting center, set without implicit
    // animation. center/bounds are independent of `transform`, so the slide animation
    // (below, on transform.translation.x) plays cleanly on top of this.
    CGPoint rest = xRestCenter(toolbar, field);
    if (!CGSizeEqualToSize(btn.bounds.size, CGSizeMake(kXSize, kXSize))) {
        [UIView performWithoutAnimation:^{ btn.bounds = CGRectMake(0, 0, kXSize, kXSize); }];
    }
    if (!CGPointEqualToPoint(btn.center, rest)) {
        [UIView performWithoutAnimation:^{ btn.center = rest; }];
    }
    // Strip Apollo's own animations on the button (its diagonal slide-in / left-jump on
    // dismiss); keep only ours.
    for (NSString *k in [btn.layer.animationKeys copy]) {
        if (![k hasPrefix:@"sipX"]) [btn.layer removeAnimationForKey:k];
    }
    // NB: the FIELD width (which leaves the gap before the circle) is NOT set here —
    // it's clamped in ApolloSearchBarTextField's own setFrame: so Apollo's activation
    // animation flows straight to the clamped width with no fight/bounce.
}

// The field's max right edge while docked — leaves kXFieldGap before the X circle,
// which itself sits kXRightMargin from the toolbar's right edge. Clamping the field's
// width to this (in its setFrame:) lets Apollo's shrink animation settle here directly
// instead of overshooting to its full width and snapping back.
static CGFloat fieldMaxRight(UIView *toolbar) {
    return CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize - kXFieldGap;
}

// Slide the round X OUT to the right (mirrors the intro). Called on dismiss (X tap /
// field resign). Sets the model transform off-screen so it stays parked after the
// animation; styleCancelAsRoundX keeps forcing center/bounds (transform-independent)
// through the teardown window, so the circle slides cleanly off as one unit.
static void animateCancelOut(void) {
    UIView *toolbar = sActiveSearchToolbar;
    UIView *cancel = (UIView *)ivarObject(sActiveSearchVC, "dismissSearchBarButton");
    if (!toolbar || ![cancel isKindOfClass:[UIButton class]]) return;
    if ([cancel.layer animationForKey:@"sipXOut"]) return; // already sliding out
    CGFloat dist = xSlideDistance(toolbar, xRestCenter(toolbar, sActiveSearchField));
    [cancel.layer removeAnimationForKey:@"sipXIn"];
    cancel.transform = CGAffineTransformMakeTranslation(dist, 0.0); // model parks off-right
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @0.0;
    slide.toValue = @(dist);
    slide.duration = 0.24;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [cancel.layer addAnimation:slide forKey:@"sipXOut"];
}

// Style + place the round X every layout pass, and run the slide-in once per
// activation (armed by sCancelNeedsIntro). The slide is a clean horizontal transform
// animation (no opacity fade — fading made the bright glyph appear before its dark
// circle on black). Starts fully off the right edge and eases into its resting spot.
static void recenterCancelButton(void) {
    UIView *toolbar = sActiveSearchToolbar;
    UIView *cancel = (UIView *)ivarObject(sActiveSearchVC, "dismissSearchBarButton");
    if (!toolbar || !cancel || cancel.superview != toolbar) return;
    if (![cancel isKindOfClass:[UIButton class]]) return;
    if (CGRectGetHeight(toolbar.bounds) < 1.0) return; // not laid out yet
    // Only own the X while the toolbar is docked (the active takeover). Once it un-docks
    // (dismiss/teardown), stop forcing its geometry so Apollo can collapse the button —
    // otherwise our forced 33x33 leaves a stray X on the resting search field.
    if (!toolbarDocked(toolbar)) return;
    styleCancelAsRoundX((UIButton *)cancel, toolbar, sActiveSearchField);
    if (sCancelNeedsIntro) {
        sCancelNeedsIntro = NO;
        CGFloat dist = xSlideDistance(toolbar, cancel.center);
        cancel.transform = CGAffineTransformIdentity; // model = resting
        [cancel.layer removeAnimationForKey:@"sipXOut"];
        CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        slide.fromValue = @(dist);
        slide.toValue = @0.0;
        slide.duration = 0.32;
        slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [cancel.layer addAnimation:slide forKey:@"sipXIn"];
    }
}

// Hold the toolbar / nav pins through Apollo's ~0.3s deactivate animation (the
// reparent of the docked toolbar back into the feed), then release. The feed
// inset is NOT released — it stays pinned at the field's bottom permanently (via
// sSearchFeed), so the field's resting position never changes.
static void endFeedSearchInPlace(void) {
    if (!sFeedSearchActive || sDismissing) return;
    sDismissing = YES;  // relax the focus offset pin so the feed settles naturally
    int gen = ++sSearchGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != sSearchGen) return; // re-activated meanwhile
        sFeedSearchActive = NO;
        sDismissing = NO;
        sActiveSearchToolbar = nil;
        sActiveNavBar = nil;
        sActiveSearchVC = nil;
        sActiveSearchField = nil;
        sCancelNeedsIntro = NO; // clear in case it was armed but never consumed
        // sSearchFeed is intentionally left set (persistent inset pin).
        ApolloLog(@"[SearchInPlace] search ended (toolbar/nav pins released)");
    });
}

#pragma mark - Nav bar: block the -88 slide

%hook UINavigationBar

- (void)setTransform:(CGAffineTransform)transform {
    if (sFeedSearchActive && self == sActiveNavBar &&
        (transform.ty != 0.0 || transform.tx != 0.0)) {
        %orig(CGAffineTransformIdentity);
        return;
    }
    %orig;
}

// Apollo's takeover also *fades* the nav bar (the "Home" title + globe/trophy/…
// buttons) out and back in as it slides. We keep the bar in place, so block the
// fade too — clamp alpha to 1 while our search is active (covers the teardown
// window until the pins release).
- (void)setAlpha:(CGFloat)alpha {
    if (sFeedSearchActive && self == sActiveNavBar && alpha < 1.0) {
        %orig(1.0);
        return;
    }
    %orig;
}

%end

#pragma mark - Search toolbar: keep it in place (don't dock to the top)

%hook _TtC6Apollo19ApolloSearchToolbar

// Pin by *screen* Y while docked so it stays exactly in place through the
// takeover's reparent + animation, and keep it 45pt tall (not the docked 99).
- (void)setFrame:(CGRect)frame {
    UIView *sup = [(UIView *)self superview];
    // Pin the toolbar to its resting screen-Y while:
    //   (a) it's docked on the VC view during the takeover, OR
    //   (b) it's being reparented back into OUR feed during teardown.
    // (b) kills the "search bar drops from the top" on Cancel: Apollo briefly sets
    // the toolbar's content-y to -161 (screen 0, the very top) and animates it down
    // to its rest; we override every set so it snaps straight to the resting Y.
    BOOL teardownInFeed = sDismissing && (UIView *)self == sActiveSearchToolbar &&
                          sup != nil && sup == sSearchFeed;
    if (feedToolbarDocked((UIView *)self) || teardownInFeed) {
        CGFloat supScreenY = [sup convertPoint:CGPointZero toView:nil].y;
        if (teardownInFeed) [[(UIView *)self layer] removeAnimationForKey:@"position"];
        %orig(CGRectMake(frame.origin.x, sInPlaceToolbarY - supScreenY,
                         frame.size.width, sInPlaceToolbarH));
        return;
    }
    %orig;
}

// Top safe-area = 0 keeps the SwiftUI content at field local-y 0 / height 45.
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    if (feedToolbarDocked((UIView *)self)) insets.top = 0.0;
    return insets;
}

- (void)layoutSubviews {
    %orig;
    UIView *tbv = (UIView *)self;
    if (sFeedSearchActive && tbv == sActiveSearchToolbar) {
        recenterCancelButton();
    }
    // "Find in Comments" bar: when active it reparents onto the VC view (docked) and
    // floats transparently over the comments, so Done / the find field / the up-down
    // chevrons sit unreadably over the comment text behind them. Give the whole row a
    // solid backing while active; restore it (transparent) at its resting pill.
    if (isCommentToolbar(tbv)) {
        if (toolbarDocked(tbv)) {
            UIColor *solid = [UIColor systemBackgroundColor];
            if (![tbv.backgroundColor isEqual:solid]) {
                tbv.backgroundColor = solid;
                tbv.opaque = YES;
            }
        } else if (tbv.backgroundColor != nil) {
            tbv.backgroundColor = nil;
        }
    }
}

// Kill the on-tap blank: the takeover reparents the toolbar onto the VC's view,
// but its frame still carries the feed content-y (~-45 => off-screen above in the
// VC's coordinate space) for a frame or two until the animation moves it. Pin it
// on-screen the instant it docks (this fires ~7ms before the active flag is set,
// so it bridges the gap the flag-gated pin used to miss).
- (void)didMoveToSuperview {
    %orig;
    if (feedToolbarDocked((UIView *)self)) {
        [(UIView *)self setFrame:[(UIView *)self frame]]; // re-routes through the pin above
    }
    // Reliable end-of-search signal: the active toolbar reparents back INTO the feed
    // scroll view (un-docks) only when the takeover actually ends. Since we no longer
    // tear down on resignFirstResponder (that fired on mere navigation), this catches
    // any dismiss path — incl. ones that never tap the X — without the false teardowns.
    UIView *sup = [(UIView *)self superview];
    if ((UIView *)self == sActiveSearchToolbar && sFeedSearchActive && !sDismissing &&
        sup && sup == sSearchFeed) { // back in OUR feed specifically (not any transient scroll view)
        endFeedSearchInPlace();
    }
}

%end

#pragma mark - Feed table: push the results below the in-place field

%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    // PERMANENT pin (both states): hold the top inset at the in-place field's
    // bottom so the field always rests just below the nav bar and the first row /
    // results sit directly under it. Inactive Apollo rests it ~8pt higher (field
    // tucked under the nav row); the takeover shrinks it to the docked position.
    // We never let it drop below the field bottom — but allow it to GROW (e.g.
    // pull-to-refresh), so use a floor rather than an exact set.
    if ((UIScrollView *)self == sSearchFeed) {
        CGFloat want = inPlaceInsetTop((UIScrollView *)self);
        if (inset.top < want) inset.top = want;
    }
    %orig(inset);
}

- (void)setContentOffset:(CGPoint)offset {
    if ((UIScrollView *)self == sSearchFeed) {
        UIScrollView *sv = (UIScrollView *)self;
        CGFloat rest = -inPlaceInsetTop(sv); // true top rest for the held inset
        BOOL userScrolling = sv.isDragging || sv.isDecelerating;
        // Track who is driving the scroll: a finger drag arms "user scrolled" (so we
        // stop fighting their browsing); returning to the top re-arms the clamp.
        if (sv.isDragging) sFeedScrolledByUser = YES;
        else if (offset.y <= rest + 1.0) sFeedScrolledByUser = NO;
        if (sDismissing && !userScrolling) {
            // Teardown: Apollo's deactivate animates the feed offset UP toward its
            // docked rest, which floats the field to the top of the screen (~y=47)
            // and then visibly drops it back down to its resting spot — the jarring
            // "search bar drops from the top" the user reported on Cancel. Hold the
            // feed at its resting top so the field never moves. Clamp only upward
            // motion (offset above rest); a user mid-scroll is exempt.
            if (offset.y > rest) offset.y = rest;
        } else if (sFeedSearchActive && !sDismissing && !userScrolling &&
                   !sFeedScrolledByUser && offset.y > rest) {
            // Hold the feed at its resting top against Apollo's PROGRAMMATIC scroll-ups:
            // on focus and on each keystroke Apollo scrolls the feed up to surface the
            // results, which in a subreddit visibly shifts the banner upward as soon as
            // you type. Clamp those to the rest position so nothing moves — but only
            // until the user themselves drags (sFeedScrolledByUser), so they can still
            // scroll down through results without being yanked back to the top. Also
            // fixes the Home empty-query clip (Apollo's docked-inset offset).
            offset.y = rest;
        }
    }
    %orig(offset);
}

%end

#pragma mark - Feed list controller: own the flag + keep geometry in place

%hook _TtC6Apollo21ASTableViewController

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    %orig;
    // Only the feed/subreddit search (comments search sets commentsSearch).
    if (!isSearchableFeedVC(self)) return;

    sSearchGen++; // invalidate any pending teardown
    sFeedSearchActive = YES;
    sDismissing = NO;
    sCancelNeedsIntro = YES; // give the Cancel button a clean horizontal slide-in
    sActiveSearchVC = (UIViewController *)self;
    sActiveSearchToolbar = (UIView *)ivarObject(self, "upperToolbar") ?: textField.superview;
    sActiveSearchField = (UITextField *)ivarObject(self, "searchTextField") ?: textField;
    sActiveNavBar = [(UIViewController *)self navigationController].navigationBar;
    UIScrollView *feed = feedScrollView((UIViewController *)self);
    if (feed) sSearchFeed = feed;
    sFeedScrolledByUser = NO; // re-arm the programmatic-scroll clamp for this session
    // The feed already rests at the field's bottom (the inset is held there in
    // both states), so activation moves nothing. Just re-pin the offset so a stale
    // scroll position can't leave the first row clipped under the field.
    if (sSearchFeed) {
        CGPoint off = sSearchFeed.contentOffset;
        off.y = -inPlaceInsetTop(sSearchFeed);
        sSearchFeed.contentOffset = off;
    }
    ApolloLog(@"[SearchInPlace] feed search began (toolbar=%p feed=%p)",
              sActiveSearchToolbar, sSearchFeed);
}

- (void)dismissSearchBarButtonTappedWithSender:(id)sender {
    %orig;
    if ((UIViewController *)self == sActiveSearchVC) {
        // NB: %orig already un-docked the toolbar, so the didMoveToSuperview handler
        // has usually started teardown (sDismissing=YES) by now. animateCancelOut only
        // touches the X's own transform animation, so it's order-independent; the
        // endFeedSearchInPlace here is a guarded no-op if teardown already began.
        animateCancelOut();
        endFeedSearchInPlace();
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    // Anchor the in-place rest position to the nav bar's bottom (the spot the
    // field holds), and remember the feed + toolbar height so the permanent inset
    // pin (in ASTableView's setContentInset) knows where the field's bottom is.
    // Runs in both states; robust across device/safe-area (defaults are fallback).
    if (isSearchableFeedVC(self)) {
        UINavigationBar *nb = [(UIViewController *)self navigationController].navigationBar;
        if (nb && [nb window]) {
            CGFloat navMaxY = CGRectGetMaxY([nb convertRect:[nb bounds] toView:nil]);
            if (navMaxY > 20.0 && navMaxY < 200.0) sInPlaceToolbarY = navMaxY;
        }
        UIView *tb = (UIView *)ivarObject(self, "upperToolbar");
        if (tb) sFeedToolbar = tb; // the feed's own search toolbar (scopes the docked pins)
        CGFloat h = tb ? CGRectGetHeight(tb.bounds) : 0.0;
        if (h > 1.0 && h < 80.0) sInPlaceToolbarH = h;
        UIScrollView *feed = feedScrollView((UIViewController *)self);
        if (feed) sSearchFeed = feed;
    }
    if (sFeedSearchActive && (UIViewController *)self == sActiveSearchVC) {
        recenterCancelButton();
    }
}

%end

#pragma mark - Search field: end search when it resigns

%hook _TtC6Apollo24ApolloSearchBarTextField

// Clamp the field's width so its right edge never passes the gap before the X circle.
// Apollo animates the field's frame on activation; by clamping the target here (the
// field's single source of truth) rather than snapping a different width from a layout
// pass, the shrink animation flows straight to the gap with no overshoot/bounce-back.
// Gated on the feed toolbar being docked (engages at the takeover, before the active
// flag) and released during teardown so Apollo can grow the field back full-width.
- (void)setFrame:(CGRect)frame {
    UIView *sup = [(UIView *)self superview];
    if (sup && sup == sFeedToolbar && toolbarDocked(sup) && !sDismissing) {
        CGFloat maxRight = fieldMaxRight(sup);
        if (frame.origin.x < maxRight && CGRectGetMaxX(frame) > maxRight) {
            frame.size.width = maxRight - frame.origin.x;
        }
    }
    %orig(frame);
}

- (BOOL)resignFirstResponder {
    BOOL ok = %orig;
    // NB: do NOT tear down here. The field resigns on ANY keyboard dismissal —
    // tapping a result, "Search all posts", another tab — none of which dismiss the
    // search (the field stays docked showing results). Tearing down here desynced our
    // state from the still-active search (field flush to X / results behind field /
    // nav gone after navigating away and back). The real dismiss is the X button
    // (dismissSearchBarButtonTappedWithSender:) or the toolbar un-docking; both are
    // handled there. (On an X tap, resign also fires, but the X path already ran the
    // teardown — this was redundant anyway.)
    return ok;
}

%end

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        %init;
        ApolloLog(@"[SearchInPlace] module loaded");
    }
}

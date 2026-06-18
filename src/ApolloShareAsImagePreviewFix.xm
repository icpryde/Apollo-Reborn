// ApolloShareAsImagePreviewFix.xm
//
// Two preview-only fixes for Apollo's "Share as Image" sheet
// (_TtC6Apollo26ShareAsImageViewController), found while finishing #484.
//
//   #1  SQUISHED COMMENT MEDIA. When you Share-as-Image a comment that contains an
//       inline GIF/image, the preview renders the media squished into a short card
//       until you toggle an option or drag the sheet. Apollo snapshots the preview
//       node into `previewSnapshotImageView` ONCE on present, and in
//       viewDidLayoutSubviews only RE-snapshots when the preview node's frame SIZE
//       differs from the current snapshot's size. A comment's media finishes
//       loading AFTER present and grows the node, but that internal Texture
//       re-measure never drives the view controller's viewDidLayoutSubviews — so the
//       initial (short, squished) snapshot sticks. Any settings toggle or drag
//       forces a relayout, which is why it "fixes itself." Fix: after present, force
//       a few view-controller relayouts (the same path a toggle takes) so the
//       snapshot is refreshed once the media has loaded and the node measures its
//       true height. The native re-snapshot is size-gated, so a relayout that finds
//       nothing changed is a no-op.
//
//   #3  UPWARD-DRAG GLITCH. Press-dragging the preview sheet UPWARD lifts it off the
//       bottom of the screen: the pan handler moves the presented view's origin.y up
//       by up to ~40pt (rubber-banded) while keeping its height fixed, so the card's
//       bottom edge rises and exposes an empty gap beneath it that snaps back on
//       release — it reads as a glitch. Dragging up serves no purpose (the sheet
//       already shows all of its content; only a downward drag dismisses), so we
//       clamp the presented view during the drag so it can never rise above its
//       resting top. Downward (dismiss) drags are untouched.
//
//   #4  SHEET STAYS OPEN AFTER A SHARE COMPLETES. Tapping Share presents the iOS
//       activity sheet on top of the preview; after you actually save/message/mail
//       the image or video, the activity sheet dismisses but the preview sheet is
//       left sitting there. Both share paths (Apollo's native image share and our
//       own video share) present the activity sheet FROM the preview view controller,
//       so we hook its presentViewController: and wrap the activity sheet's
//       completion handler to also dismiss the preview — but only when the share
//       actually COMPLETED (cancelling the activity sheet leaves the preview up so
//       you can tweak options and try again).
//
// Pure ObjC-runtime access + public UIKit; no hardcoded binary addresses.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// Associated-object key: marks that the post-present snapshot refresh has been
// armed for this VC (so we only schedule it once).
static char kApolloSIPFRefreshArmedKey;

// Forces Apollo's own preview relayout + re-snapshot. This mirrors the relayout a
// settings toggle performs (lay out the presentation container, then the VC view):
// the native viewDidLayoutSubviews re-snapshots the preview node whenever its frame
// size has changed since the last snapshot — exactly what happens once a comment's
// async media finishes loading and the node measures its true height.
static void ApolloSIPFForceRelayout(UIViewController *vc) {
    if (![vc isViewLoaded] || !vc.viewIfLoaded.window) return;
    UIPresentationController *pc = vc.presentationController;
    UIView *container = pc.containerView;
    if (container) {
        [container setNeedsLayout];
        [container layoutIfNeeded];
    }
    [vc.view setNeedsLayout];
    [vc.view layoutIfNeeded];
}

%hook _TtC6Apollo26ShareAsImageViewController

- (void)viewDidLayoutSubviews {
    %orig;

    // Arm a short series of relayouts once, on the first layout after present, so
    // the snapshot is refreshed as soon as any async comment/post media loads (it's
    // usually already cached from the thread the user shared from, so this resolves
    // almost immediately). Idempotent and self-limiting; each relayout is a no-op if
    // nothing changed.
    if ([objc_getAssociatedObject(self, &kApolloSIPFRefreshArmedKey) boolValue]) return;
    objc_setAssociatedObject(self, &kApolloSIPFRefreshArmedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak __typeof__(self) weakSelf = self;
    static const double kDelays[] = { 0.1, 0.3, 0.6, 1.2, 2.0, 3.5 };
    for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloSIPFForceRelayout((UIViewController *)weakSelf);
        });
    }
    ApolloLog(@"[SharePreviewFix] armed snapshot refreshes");
}

// #4: auto-dismiss the preview once a share completes. Both the native image share
// and our video share present a UIActivityViewController from this view controller,
// so wrap that activity sheet's completion handler (preserving any existing one,
// e.g. the video share's temp-file cleanup) and dismiss the preview when the user
// actually completed a share. Cancelling leaves the preview open.
- (void)presentViewController:(UIViewController *)vcToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    @try {
        if ([vcToPresent isKindOfClass:[UIActivityViewController class]]) {
            UIActivityViewController *avc = (UIActivityViewController *)vcToPresent;
            __weak __typeof__(self) weakSelf = self;
            void (^existing)(UIActivityType, BOOL, NSArray *, NSError *) = avc.completionWithItemsHandler;
            avc.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                               NSArray *returnedItems, NSError *activityError) {
                if (existing) existing(activityType, completed, returnedItems, activityError);
                if (!completed) return; // cancelled — keep the preview up
                __typeof__(self) strongSelf = weakSelf;
                UIViewController *previewVC = (UIViewController *)strongSelf;
                if (previewVC.viewIfLoaded.window) {
                    [previewVC dismissViewControllerAnimated:YES completion:nil];
                    ApolloLog(@"[SharePreviewFix] share completed — dismissed preview");
                }
            };
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

%hook _TtC6Apollo31SourdoughPresentationController

// After the native pan moves the sheet, clamp the presented view so an upward drag
// can never lift it above its resting top (which would expose an empty gap under the
// card). Only acts while the gesture is actively dragging the Share-as-Image sheet;
// the end-of-gesture dismiss/snap-back animation runs untouched.
- (void)pannedWithPanGestureRecognizer:(id)gestureRecognizer {
    %orig;
    @try {
        if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return;
        UIGestureRecognizerState state = ((UIPanGestureRecognizer *)gestureRecognizer).state;
        if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return;

        UIPresentationController *pc = (UIPresentationController *)self;
        id presented = [pc presentedViewController];
        Class shareVCClass = objc_getClass("_TtC6Apollo26ShareAsImageViewController");
        if (!shareVCClass || ![presented isKindOfClass:shareVCClass]) return;

        UIView *presentedView = [(UIViewController *)presented view];
        if (![presentedView isKindOfClass:[UIView class]]) return;

        CGRect resting = [pc frameOfPresentedViewInContainerView];
        if (!isfinite(resting.origin.y)) return;

        CGRect frame = presentedView.frame;
        if (frame.origin.y < resting.origin.y - 0.5) {
            frame.origin.y = resting.origin.y;
            presentedView.frame = frame;
        }
    } @catch (__unused NSException *e) {}
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo26ShareAsImageViewController")) {
            %init();
            ApolloLog(@"[SharePreviewFix] module loaded");
        } else {
            ApolloLog(@"[SharePreviewFix] ShareAsImageViewController not found — skipping");
        }
    }
}

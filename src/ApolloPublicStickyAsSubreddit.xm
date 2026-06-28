// ApolloPublicStickyAsSubreddit.xm
//
// Issue #515: add a 4th post-removal notify option, "Public Sticky from
// Subreddit", that posts the stickied removal comment AS the subreddit
// (u/<Sub>-ModTeam) instead of from the moderator's personal account.
//
// Background (all native Apollo, reverse-engineered from the binary):
//
//   When a mod removes a post and adds a removal reason, Apollo presents a
//   "Notify user via…" menu with three options:
//       "Public Sticky"            (or "Public Reply" for a comment)
//       "Mod Mail from Subreddit"
//       "Mod Mail from You"
//   Picking one walks a short compose flow (message → optional private mod
//   note → submit) that ultimately calls, on RDKClient:
//
//     -[RDKClient addRemovalReasonToRemovedThingWithFullName:title:message:
//                   type:reasonID:modNote:completion:]
//
//   which POSTs `api/v1/modactions/removal_reasons` with a `type` parameter.
//   The three options pass type = "public" / "private" / "private_exposed".
//   Reddit's API (confirmed via PRAW) accepts a FOURTH value the three options
//   never use:
//       "public_as_subreddit" -> stickied comment as u/<Sub>-ModTeam.
//   That single value IS the requested feature — same endpoint, same method.
//
// How the option is added:
//
//   On iOS 26 the tweak's own ApolloNativeActionMenus module converts Apollo's
//   ActionController action sheets into native UIKit context menus
//   (UIMenu/UIAction) — so the "Notify user via…" sheet renders as a UIMenu.
//   `ApolloNativeActionMenuBuildMenu` builds that menu from the controller's
//   `textActions`; it calls ApolloInjectPublicStickyAsSubredditIfNeeded() (this
//   file) just before constructing the UIMenu. For the "Notify user via…" menu
//   we append a 4th UIAction that clones the "Public Sticky"/"Public Reply"
//   action's title (+ " from Subreddit") and, on tap, arms a one-shot flag and
//   runs the ORIGINAL action's handler — so the entire native compose flow runs
//   unchanged. (Injecting at the single build site avoids a second
//   -[UIMenu children] hook, which would collide with the video-speed one.)
//
//   The RDKClient hook below is UI-independent — every notify path funnels
//   through it — and rewrites type "public" → "public_as_subreddit" while the
//   flag is set, then consumes it. Every other option/path is untouched.
//
// Mod-only and additive: non-mods never see this menu; untouched options behave
// exactly like stock Apollo. No settings toggle in v1.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// Title prefix of the menu we augment (ellipsis is U+2026; matched with
// hasPrefix so the exact trailing glyph never matters).
static NSString *const kNotifyMenuTitlePrefix = @"Notify user via";

// Title prefix of the action we clone ("Public Sticky" / "Public Reply").
static NSString *const kPublicActionPrefix = @"Public ";

// Suffix that labels (and marks) our injected action.
static NSString *const kAsSubredditSuffix = @" from Subreddit";

// Reddit removal-message `type` values.
static NSString *const kTypePublic            = @"public";
static NSString *const kTypePublicAsSubreddit = @"public_as_subreddit";

// One-shot flag: the next removal submission should go out as the subreddit.
// Armed when our injected action fires; consumed by the RDKClient hook; reset
// each time the "Notify user via…" menu is rebuilt so a cancelled compose can't
// leak into a later genuine "Public Sticky". UI is main-thread only, so a plain
// BOOL is sufficient.
static BOOL sSendNextRemovalAsSubreddit = NO;

#pragma mark - Runtime helper

// Read an object-typed ivar by name, walking the superclass chain. Used to
// recover a UIAction's private handler block so our injected action can run it.
static id PSObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// Is this ActionController the removal "Notify user via…" action sheet? Its own
// `tableView:titleForHeaderInSection:` returns the header String (and ignores
// both arguments), so it's a safe probe. Used for the non-Liquid-Glass path,
// where Apollo presents the real ActionController sheet instead of a UIMenu.
static BOOL PSIsNotifyActionSheet(id actionController) {
    if (![actionController respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) return NO;
    UITableView *tv = (UITableView *)PSObjectIvar(actionController, "tableView");
    NSString *header = nil;
    @try {
        header = [(id<UITableViewDataSource>)actionController tableView:tv titleForHeaderInSection:0];
    } @catch (__unused NSException *e) {
        return NO;
    }
    return [header isKindOfClass:[NSString class]] && [header hasPrefix:kNotifyMenuTitlePrefix];
}

#pragma mark - Menu injection (called from ApolloNativeActionMenuBuildMenu)

// If `menuTitle` is the removal "Notify user via…" menu, append a
// "… from Subreddit" UIAction right after the existing "Public Sticky"/"Public
// Reply" action. The injected action arms the flag, then invokes the original
// action's handler (which runs Apollo's native compose+submit flow); the
// RDKClient hook then rewrites the removal type. No-op for every other menu.
void ApolloInjectPublicStickyAsSubredditIfNeeded(NSMutableArray *children, NSString *menuTitle) {
    if (![menuTitle isKindOfClass:[NSString class]] ||
        ![menuTitle hasPrefix:kNotifyMenuTitlePrefix]) {
        return;
    }
    if (![children isKindOfClass:[NSMutableArray class]]) return;

    // Fresh Notify menu -> disarm, so a previously-cancelled "as subreddit"
    // intent never leaks into a genuine "Public Sticky" chosen later.
    sSendNextRemovalAsSubreddit = NO;

    // Locate the "Public Sticky"/"Public Reply" action to clone. Our injected
    // action is identified by BOTH the "Public " prefix AND the " from
    // Subreddit" suffix — checking the suffix alone would false-match the
    // existing "Mod Mail from Subreddit" option and abort.
    UIAction *publicAction = nil;
    NSUInteger publicIndex = NSNotFound;
    for (NSUInteger i = 0; i < children.count; i++) {
        UIMenuElement *e = children[i];
        if (![e isKindOfClass:[UIAction class]]) continue;
        NSString *t = ((UIAction *)e).title;
        if (![t hasPrefix:kPublicActionPrefix]) continue;
        if ([t hasSuffix:kAsSubredditSuffix]) return; // our action already present
        if (!publicAction) {
            publicAction = (UIAction *)e;
            publicIndex = i;
        }
    }
    if (!publicAction) {
        ApolloLog(@"[PublicStickyAsSub] Notify menu found but no 'Public …' action; leaving as-is");
        return;
    }

    // Recover the original action's handler so ours can run the exact native
    // compose flow after arming the flag.
    void (^publicHandler)(UIAction *) = (void (^)(UIAction *))PSObjectIvar(publicAction, "_handler");
    NSString *newTitle = [publicAction.title stringByAppendingString:kAsSubredditSuffix];

    UIAction *injected =
        [UIAction actionWithTitle:newTitle
                            image:publicAction.image
                       identifier:nil
                          handler:^(__unused __kindof UIAction *action) {
            ApolloLog(@"[PublicStickyAsSub] '%@' tapped; arming + running native public-sticky flow", newTitle);
            sSendNextRemovalAsSubreddit = YES;
            if (publicHandler) {
                publicHandler(publicAction);
            } else {
                ApolloLog(@"[PublicStickyAsSub] WARN: original 'Public …' handler was nil");
            }
        }];
    injected.attributes = publicAction.attributes;

    // Match the original action's title color (Apollo tints these moderator
    // actions green via a private attributedTitle); copy whatever color it has
    // so our clone never looks out of place, in any menu style.
    NSAttributedString *origAttributed = nil;
    @try {
        origAttributed = [publicAction valueForKey:@"attributedTitle"];
    } @catch (__unused NSException *e) {
        origAttributed = (NSAttributedString *)PSObjectIvar(publicAction, "_attributedTitle");
    }
    if ([origAttributed isKindOfClass:[NSAttributedString class]] && origAttributed.length > 0) {
        UIColor *color = [origAttributed attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (color && [injected respondsToSelector:@selector(setAttributedTitle:)]) {
            NSAttributedString *attr = [[NSAttributedString alloc] initWithString:newTitle
                                                                      attributes:@{NSForegroundColorAttributeName: color}];
            ((void (*)(id, SEL, id))objc_msgSend)(injected, @selector(setAttributedTitle:), attr);
        }
    }

    [children insertObject:injected atIndex:publicIndex + 1];
    ApolloLog(@"[PublicStickyAsSub] injected '%@' into Notify menu (now %lu items)",
              newTitle, (unsigned long)children.count);
}

#pragma mark - Action-sheet injection (non-Liquid-Glass path)

// Without Liquid Glass, ApolloNativeActionMenus does NOT convert the sheet to a
// UIMenu, so the menu injection above never runs — Apollo shows its real
// `ActionController` table-based sheet. Here we add the 4th row directly to that
// table: one extra row cloned from row 0 ("Public Sticky"/"Public Reply",
// always first in this sheet), retitled, that arms the flag and triggers row 0's
// native handler. We only ever touch the "Notify user via…" sheet; every other
// ActionController and the Liquid-Glass UIMenu path are untouched (in LG the
// sheet isn't shown, so these hooks no-op there).
//
// NOTE: ApolloNativeActionMenus already hooks this class's viewWillAppear:, so we
// must not — we reset the one-shot flag in numberOfRowsInSection: (called each
// time the sheet's table loads) instead.
%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
    if (PSIsNotifyActionSheet(self)) {
        sSendNextRemovalAsSubreddit = NO; // fresh sheet display -> disarm
        n += 1;
    }
    return n;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self)) return %orig;

    NSInteger r = indexPath.row;
    if (r == 0) return %orig; // row 0 = the "Public Sticky"/"Public Reply" option

    if (r == 1) {
        // Our injected row: clone row 0's cell (inherits styling) and retitle.
        NSIndexPath *zero = [NSIndexPath indexPathForRow:0 inSection:indexPath.section];
        UITableViewCell *cell = %orig(tableView, zero);
        UILabel *label = (UILabel *)PSObjectIvar(cell, "actionTitleLabel");
        if ([label isKindOfClass:[UILabel class]]) {
            NSString *base = label.text ?: @"Public Sticky";
            if (![base hasSuffix:kAsSubredditSuffix]) {
                label.text = [base stringByAppendingString:kAsSubredditSuffix];
            }
        }
        return cell;
    }

    NSIndexPath *mapped = [NSIndexPath indexPathForRow:(r - 1) inSection:indexPath.section];
    return %orig(tableView, mapped);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self)) return %orig;
    NSInteger r = indexPath.row;
    NSInteger src = (r <= 1) ? 0 : (r - 1); // our row (1) clones row 0's height
    if (r == 0) src = 0;
    NSIndexPath *clone = [NSIndexPath indexPathForRow:src inSection:indexPath.section];
    return %orig(tableView, clone);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self)) { %orig; return; }

    NSInteger r = indexPath.row;
    if (r == 0) { %orig; return; }

    if (r == 1) {
        // Our injected row: arm the flag, then run row 0's native handler.
        sSendNextRemovalAsSubreddit = YES;
        ApolloLog(@"[PublicStickyAsSub] (sheet) 'from Subreddit' tapped; arming + running row-0 flow");
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        NSIndexPath *zero = [NSIndexPath indexPathForRow:0 inSection:indexPath.section];
        %orig(tableView, zero);
        return;
    }

    NSIndexPath *mapped = [NSIndexPath indexPathForRow:(r - 1) inSection:indexPath.section];
    %orig(tableView, mapped);
}

%end

#pragma mark - Type rewrite at the API boundary

%hook RDKClient

- (id)addRemovalReasonToRemovedThingWithFullName:(id)fullName
                                           title:(id)title
                                         message:(id)message
                                            type:(id)type
                                        reasonID:(id)reasonID
                                         modNote:(id)modNote
                                      completion:(id)completion {
    if (sSendNextRemovalAsSubreddit) {
        sSendNextRemovalAsSubreddit = NO; // consume regardless, one-shot
        if ([type isKindOfClass:[NSString class]] && [type isEqualToString:kTypePublic]) {
            ApolloLog(@"[PublicStickyAsSub] rewriting removal type 'public' -> 'public_as_subreddit'");
            type = kTypePublicAsSubreddit;
        } else {
            ApolloLog(@"[PublicStickyAsSub] flag set but type was %@ (not 'public'); left unchanged", type);
        }
    }
    // Explicit args: bare %orig would re-pass the ORIGINAL captured `type`,
    // discarding our rewrite (see CLAUDE.md Logos note).
    return %orig(fullName, title, message, type, reasonID, modNote, completion);
}

%end

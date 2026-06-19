// ApolloChatsFilter.xm
//
// Feature 2 of the chat upgrade: add a "Direct Chat" filter row to the inbox "Boxes"
// list, directly above "Messages". Tapping it opens the normal messages list but filtered
// to direct/group chats (Reddit bridges chat into private messages with the subject
// "[direct chat room]"; group chats use a "chat room" subject too).
//
// Boxes screen = _TtC6Apollo23InboxListViewController (a UITableViewController whose
// data-source methods are ObjC-visible). The "Messages" row maps to InboxType.messages and
// pushes a _TtC6Apollo19InboxViewController (inboxType=messages, messages:[RDKMessage],
// IGListKit listAdapter). We:
//   1. Detect the Messages section by the stock cell's text (layout is account-dependent).
//   2. Add one extra row at the top of that section, styled "Direct Chat".
//   3. On tap, set a one-shot flag and invoke the *real* Messages row so Apollo opens the
//      messages list normally; the flag marks that VC to filter its list to chats.
//   4. In the messages list, filter the IGListKit objects to chat-subject messages.

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ChatsFilterLog(fmt, ...) ApolloLog(@"[ChatsFilter] " fmt, ##__VA_ARGS__)

static NSInteger sMessagesSection = -1;     // detected section index of the "Messages" row
static NSInteger sMessagesRow = -1;         // detected row index of "Messages" within that section
// "Direct Chat" Boxes row. The earlier "3 Direct Chat / Messages gone" turned out to be the tweak
// double-loading (a stale baked LC_LOAD_DYLIB + the injected copy), so EVERY hook ran twice and
// numberOfRows added +1 twice (1 real row -> 3). With a single load this inserts one row correctly.
static const BOOL sDirectChatRowEnabled = YES;
static BOOL sNextInboxIsChatFilter = NO;    // armed when the Direct Chat row is tapped
static char kChatFilterKey;                 // on InboxViewController: this list is chat-filtered

#pragma mark - helpers

// Find the cell's primary text whether it uses textLabel or a custom UILabel subview.
static NSString *ApolloCellText(UITableViewCell *cell) {
    if (cell.textLabel.text.length) return cell.textLabel.text;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) return ((UILabel *)v).text;
        [q addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void ApolloRestyleAsDirectChat(UITableViewCell *cell) {
    if (!cell) return;
    // IconTextTableViewCell uses a CUSTOM label, not cell.textLabel (which is lazy and always
    // non-nil — setting it just overlays a 2nd "Direct Chat" on top of "Messages"). Find the
    // label that actually shows the row text and the leading icon image view, and relabel both.
    UILabel *label = nil; UIImageView *icon = nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if (!label && [v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) label = (UILabel *)v;
        if (!icon  && [v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) icon = (UIImageView *)v;
        [q addObjectsFromArray:v.subviews];
    }
    if (label) label.text = @"Direct Chat";
    if (@available(iOS 13.0, *)) {
        UIImage *glyph = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
        if (icon && glyph) icon.image = [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

#pragma mark - Boxes list: add the Direct Chat row

%hook _TtC6Apollo23InboxListViewController

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    long long n = %orig;
    if (sDirectChatRowEnabled && sMessagesSection >= 0 && section == sMessagesSection) {
        n += 1;   // + our Direct Chat row
    }
    return n;
}

// Map a displayed row (with our inserted Direct Chat row) back to Apollo's real row in the
// Messages section. The Direct Chat row sits AT sMessagesRow (just above Messages); rows below it
// shift down by one. Returns -1 for the Direct Chat slot itself.
static NSInteger ApolloRealMessagesRow(NSInteger displayedRow) {
    if (displayedRow < sMessagesRow) return displayedRow;     // rows above Messages: unchanged
    if (displayedRow == sMessagesRow) return -1;              // our inserted Direct Chat row
    return displayedRow - 1;                                  // rows at/after Messages: shifted down
}

- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!sDirectChatRowEnabled) return %orig;   // Direct Chat row disabled — leave Boxes untouched
    // Detection pass: until we know which section/row holds "Messages", just observe.
    if (sMessagesSection < 0) {
        UITableViewCell *cell = %orig;
        NSString *text = ApolloCellText(cell);
        ChatsFilterLog(@"probe s=%ld r=%ld text=%@ cls=%@", (long)indexPath.section, (long)indexPath.row, text, NSStringFromClass([cell class]));
        if ([text isEqualToString:@"Messages"]) {
            sMessagesSection = indexPath.section;
            sMessagesRow = indexPath.row;
            ChatsFilterLog(@"Messages at s=%ld r=%ld; inserting Direct Chat row + reloading", (long)sMessagesSection, (long)sMessagesRow);
            UITableView *tv = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{ [tv reloadData]; });
        }
        return cell;
    }

    if (indexPath.section == sMessagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(indexPath.row);
        if (realRow < 0) {
            // our inserted Direct Chat row: borrow the Messages cell and restyle it
            NSIndexPath *real = [NSIndexPath indexPathForRow:sMessagesRow inSection:sMessagesSection];
            UITableViewCell *cell = %orig(tableView, real);
            ChatsFilterLog(@"cellFor displayed=%ld -> DirectChat (borrow r%ld, was '%@')", (long)indexPath.row, (long)sMessagesRow, ApolloCellText(cell));
            ApolloRestyleAsDirectChat(cell);
            return cell;
        }
        // every other row maps to its real Apollo row (Messages, and anything after it)
        NSIndexPath *real = [NSIndexPath indexPathForRow:realRow inSection:sMessagesSection];
        UITableViewCell *cell = %orig(tableView, real);
        ChatsFilterLog(@"cellFor displayed=%ld -> real r%ld text='%@'", (long)indexPath.row, (long)realRow, ApolloCellText(cell));
        return cell;
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (sDirectChatRowEnabled && sMessagesSection >= 0 && indexPath.section == sMessagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(indexPath.row);
        if (realRow < 0) {
            ChatsFilterLog(@"Direct Chat tapped -> opening filtered messages list");
            sNextInboxIsChatFilter = YES;   // one-shot: the next InboxViewController filters to chats
            realRow = sMessagesRow;          // open the real Messages list (which we then filter)
        }
        %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:sMessagesSection]);
        // We handed Apollo the REAL indexPath, so its own deselect-on-return clears the wrong row.
        // Defer to after the push settles and clear ALL selected rows (the index remap can leave
        // more than one marked) so the tapped row doesn't stay highlighted.
        NSIndexPath *tapped = indexPath;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSIndexPath *ip in ([tableView indexPathsForSelectedRows] ?: @[]))
                [tableView deselectRowAtIndexPath:ip animated:NO];
            [tableView deselectRowAtIndexPath:tapped animated:NO];
        });
        return;
    }
    %orig;
}

%end

#pragma mark - messages list: filter to chats

// Keep only chat-subject messages (direct + group chats both carry a "chat room" subject;
// regular PMs/modmail have a real subject, so they fall away).
static NSArray *ApolloChatFilterToChats(NSArray *messages) {
    if (![messages isKindOfClass:[NSArray class]]) return messages;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msg in messages) {
        NSString *subject = nil;
        if ([msg respondsToSelector:@selector(subject)])
            subject = ((NSString *(*)(id, SEL))objc_msgSend)(msg, @selector(subject));
        if (subject && [subject localizedCaseInsensitiveContainsString:@"chat room"]) [out addObject:msg];
    }
    ChatsFilterLog(@"filtered messages %lu -> %lu chats", (unsigned long)messages.count, (unsigned long)out.count);
    return out;
}

// Apollo's list is fed by a Swift Apollo.ListAdapterDataSource (not ObjC-hookable) reading the
// `messages` ivar, so we filter one level up: at the RDKClient message-inbox fetch, while the
// chat-filtered list is the visible one (sChatFilterActive). The Messages box itself never sets
// the flag, so it stays unfiltered.
static BOOL sChatFilterActive = NO;

%hook _TtC6Apollo19InboxViewController

- (void)viewDidLoad {
    // Set the flag BEFORE %orig — Apollo's viewDidLoad kicks off the initial fetch, so the flag
    // must already be armed or that fetch slips through unfiltered.
    if (sNextInboxIsChatFilter) {
        sNextInboxIsChatFilter = NO;
        objc_setAssociatedObject(self, &kChatFilterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sChatFilterActive = YES;
        ChatsFilterLog(@"InboxViewController marked chat-filtered");
    }
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue])
        ((UIViewController *)self).title = @"Direct Chat";   // after %orig so Apollo doesn't override it
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = YES;
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = NO;
}
%end

// Safety: opening a chat THREAD must never run with the inbox-list filter armed, or a thread
// refresh that happens to use messagesInCategory could be filtered. Clear the flag on thread show.
%hook _TtC6Apollo28PrivateMessageViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sChatFilterActive = NO;
}
%end

%hook RDKClient
// NOTE: `category` is an enum (NSInteger), NOT an object — declaring it `id` makes ARC retain
// the integer value as a pointer (EXC_BAD_ACCESS at 0x2). It MUST be a scalar type.
- (id)messagesInCategory:(long long)category pagination:(id)pagination markRead:(BOOL)markRead completion:(id)completion {
    ChatsFilterLog(@"messagesInCategory cat=%lld active=%d", category, sChatFilterActive);
    if (!completion || !sChatFilterActive) return %orig;
    id wrapped = ^(NSArray *messages, id page, NSError *error) {
        ((void (^)(NSArray *, id, NSError *))completion)(ApolloChatFilterToChats(messages), page, error);
    };
    return %orig(category, pagination, NO, wrapped);   // markRead:NO so the filtered view doesn't mark PMs read
}
%end

#pragma mark - sender avatar in the Direct Chat list

// The inbox is AsyncDisplayKit (Texture): each row is an Apollo.InboxCellNode whose username is an
// ApolloButtonNode (text "to <user>" / "<user>") near the bottom-left. We overlay a small circular
// avatar just to its left, scoped to chat-room cells, gated by the Show User Avatars toggle.
static char kInboxAvatarKey;       // on the cell's view: our avatar UIImageView
static char kInboxAvatarUserKey;   // on the avatar view: username it currently shows

static CGRect ApolloNodeFrame(id node) {
    if (![node respondsToSelector:@selector(frame)]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame));
}
static NSString *ApolloNodeText(id node) {
    if (![node respondsToSelector:@selector(attributedText)]) return nil;
    id at = ((id (*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
    return [at isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)at string] : nil;
}
static NSArray *ApolloNodeSubnodes(id node) {
    if (![node respondsToSelector:@selector(subnodes)]) return nil;
    id s = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
    return [s isKindOfClass:[NSArray class]] ? s : nil;
}

static void ApolloInboxCellApplyAvatar(id cellNode) {
    UIView *cellView = [cellNode respondsToSelector:@selector(view)]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view)) : nil;
    if (![cellView isKindOfClass:[UIView class]]) return;
    UIImageView *av = objc_getAssociatedObject(cellView, &kInboxAvatarKey);

    if (!sShowUserAvatars) { if (av) av.hidden = YES; return; }   // toggle off — definitive hide

    // Walk the node tree: detect a "chat room" subject (scope to chats) and find the leftmost
    // username button (an ApolloButtonNode whose text has letters and isn't the "…" overflow glyph).
    BOOL isChat = NO, foundAnyText = NO;
    id usernameBtn = nil; CGRect ubf = CGRectZero; NSString *ubText = nil;
    NSMutableArray *q = [NSMutableArray arrayWithObject:cellNode];
    while (q.count) {
        id nd = q.firstObject; [q removeObjectAtIndex:0];
        NSString *t = ApolloNodeText(nd);
        if (t.length) { foundAnyText = YES; if ([t localizedCaseInsensitiveContainsString:@"chat room"]) isChat = YES; }
        if ([NSStringFromClass([nd class]) containsString:@"ApolloButtonNode"]) {
            for (id sub in ApolloNodeSubnodes(nd)) {
                NSString *st = ApolloNodeText(sub);
                if (st.length && ![st hasPrefix:@"…"] &&
                    [st rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
                    CGRect f = ApolloNodeFrame(nd);
                    if (!usernameBtn || f.origin.x < ubf.origin.x) { usernameBtn = nd; ubf = f; ubText = st; }
                }
            }
        }
        NSArray *subs = ApolloNodeSubnodes(nd);
        if (subs) [q addObjectsFromArray:subs];
    }

    // Texture removes foreign subviews on cell reuse, so we must re-add + re-position the avatar on
    // EVERY layout pass — not bail early — or it vanishes during scroll.
    //  - a populated NON-chat cell (comment reply, etc.) -> hide and stop
    //  - nothing known yet and no existing avatar -> wait
    if (foundAnyText && !isChat) { if (av) av.hidden = YES; return; }
    if (!isChat && !av) return;

    static const CGFloat d = 20.0, gap = 6.0;
    if (!av) {
        av = [[UIImageView alloc] init];
        av.contentMode = UIViewContentModeScaleAspectFill;
        av.clipsToBounds = YES;
        av.layer.cornerRadius = d / 2.0;
        av.backgroundColor = [UIColor secondarySystemFillColor];
        objc_setAssociatedObject(cellView, &kInboxAvatarKey, av, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (av.superview != cellView) [cellView addSubview:av];   // re-add if Texture stripped it
    [cellView bringSubviewToFront:av];
    av.hidden = NO;
    // Use the username button's frame when it's resolved; fall back to a cell-relative position
    // (the username row sits ~25px above the cell bottom) so the avatar stays put mid-reconfigure.
    BOOL frameOK = usernameBtn && ubf.origin.x > 10.0;
    CGFloat ax = frameOK ? ubf.origin.x - d - gap : 12.0;
    CGFloat ay = frameOK ? ubf.origin.y + (ubf.size.height - d) / 2.0 : cellView.bounds.size.height - 27.0;
    av.frame = CGRectMake(ax, ay, d, d);

    // Refresh the image only when a username is actually resolved (skip transient passes).
    if (!usernameBtn || ubText.length == 0) return;
    NSString *username = [ubText hasPrefix:@"to "] ? [ubText substringFromIndex:3] : ubText;
    username = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (username.length == 0) return;
    if ([objc_getAssociatedObject(av, &kInboxAvatarUserKey) isEqualToString:username]) return;   // already set
    objc_setAssociatedObject(av, &kInboxAvatarUserKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    av.image = nil;
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    __weak UIImageView *wav = av;
    void (^applyImg)(UIImage *) = ^(UIImage *img) {
        UIImageView *sav = wav;
        if (img && sav && [objc_getAssociatedObject(sav, &kInboxAvatarUserKey) isEqualToString:username]) sav.image = img;
    };
    ApolloUserProfileInfo *info = [cache cachedInfoForUsername:username];
    NSURL *u = info ? (info.iconURL ?: info.snoovatarURL) : nil;
    UIImage *ci = u ? [cache cachedImageForURL:u] : nil;
    if (ci) { applyImg(ci); return; }
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *i2) {
        NSURL *uu = i2.iconURL ?: i2.snoovatarURL;
        if (uu) [cache requestImageForURL:uu completion:applyImg];
    }];
}

%hook _TtC6Apollo13InboxCellNode
- (void)layout {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
}
- (void)didEnterVisibleState {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
    // The username ASTextNode may not have its attributedText yet on first visibility; re-apply a
    // couple of times shortly after so the avatar resolves + re-attaches without needing a scroll.
    __weak id wself = self;
    for (NSTimeInterval delay = 0.25; delay <= 0.8; delay += 0.55) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { if (wself) ApolloInboxCellApplyAvatar(wself); } @catch (__unused id e) {}
        });
    }
}
%end

%ctor {
    ChatsFilterLog(@"module loaded");
}

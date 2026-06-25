// ApolloFiltersBlocksInject
//
// Beefs out Apollo's native Filters & Blocks screen
// (_TtC6Apollo29SettingsFiltersViewController) by APPENDING two Reborn sections
// below the native Keywords / Subreddits / Users sections:
//
//   • SUBREDDIT-SPECIFIC FILTERS — a list of configured subreddits; tap one to
//     open ApolloSubredditFilterDetailViewController and manage its keyword/flair
//     lists, plus an "Add Subreddit..." row.
//   • FILTER SUBREDDITS BY NAME — a list of name substrings (hide any subreddit
//     whose name contains the word), plus an "Add Word..." row.
//
// Native sections are left fully intact (we append, so their indices never shift;
// every native section/row routes straight to %orig). Cells are borrowed from a
// native row so they inherit Apollo's exact theme; our section headers/footers are
// self-sizing label views. Enforcement lives in ApolloPostFilters.xm; storage in
// ApolloPostFilterStore.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloPostFilterStore.h"
#import "ApolloSubredditFilterDetailViewController.h"

// Native Filters & Blocks screen (Apollo.SettingsFiltersViewController). Declared
// for the compiler so our self-calls (the dataSource method + the %new helpers
// below) type-check; the real class is hooked/resolved at runtime.
@interface _TtC6Apollo29SettingsFiltersViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView;
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView;
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView;
@end

// Number of Reborn sections appended after the native ones.
static const NSInteger kApolloPFExtraSections = 2;

// Reuse identifier for the Blocked Users toggle row. It has its OWN identifier so
// it never enters Apollo's cell-reuse pool — otherwise its chevron / accessoryType
// would leak onto recycled username / "Add User" cells.
static NSString *const kApolloPFBlockedToggleReuse = @"ApolloPFBlockedUsersToggle";

// Collapsible native Blocked Users section (the last native section): collapsed by
// default to a single tappable header so a long block list doesn't bloat the page.
// Expanding restores Apollo's own rows (Add User + swipe-delete) unchanged — we only
// vary the row COUNT (0 vs %orig), never re-map indices, so native editing is intact.
static const void *kApolloPFBlockedExpandedKey   = &kApolloPFBlockedExpandedKey;   // NSNumber BOOL on the VC
static const void *kApolloPFBlockedNativeCountKey = &kApolloPFBlockedNativeCountKey; // NSNumber on the VC (rows incl. Add)

#pragma mark - Section header / footer views (self-sizing)

static UIView *ApolloPFSectionHeaderView(NSString *title) {
    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title.uppercaseString;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:18.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}

static UIView *ApolloPFSectionFooterView(NSString *text) {
    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:6.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}

#pragma mark - Hook

%hook _TtC6Apollo29SettingsFiltersViewController

// origCount: our numberOfSectionsInTableView: returns native + kApolloPFExtraSections,
// so subtracting it back yields the native count without needing %orig outside the
// numberOfSections hook.
%new
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView {
    return [self numberOfSectionsInTableView:tableView] - kApolloPFExtraSections;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + kApolloPFExtraSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        // Blocked Users = last native section. Row 0 is always our "Blocked Users (N)"
        // toggle; when expanded, Apollo's own rows follow (offset by 1) in the SAME
        // group, so it reads as one continuous list rather than a floating header.
        if (native > 0 && section == native - 1) {
            NSInteger n = %orig; // native row count (blocked users + "Add User")
            objc_setAssociatedObject(self, kApolloPFBlockedNativeCountKey, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue] ? (n + 1) : 1;
        }
        return %orig;
    }
    if (section == native) return (NSInteger)[ApolloPostFilterStore allSubreddits].count + 1; // + Add
    return (NSInteger)[ApolloPostFilterStore nameSubstrings].count + 1;                        // + Add
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            // Row 0 = the "Blocked Users (N)" toggle (chevron points right collapsed,
            // down expanded). Rows >0 are Apollo's own rows, offset by 1.
            if (indexPath.row == 0) {
                BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
                NSInteger n = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
                NSInteger count = MAX((NSInteger)0, n - 1); // exclude the "Add User" row
                // Our OWN cell (separate reuse pool) so nothing leaks onto Apollo's rows.
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kApolloPFBlockedToggleReuse];
                if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kApolloPFBlockedToggleReuse];
                // Match Apollo's themed cell background by sampling a native cell.
                @try {
                    UITableViewCell *probe = %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:0]);
                    UIColor *bg = probe.backgroundColor ?: probe.contentView.backgroundColor;
                    if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) cell.backgroundColor = bg;
                } @catch (__unused id e) {}
                cell.textLabel.text = [NSString stringWithFormat:@"Blocked Users (%ld)", (long)count];
                cell.textLabel.textColor = [UIColor labelColor];
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(expanded ? @"chevron.down" : @"chevron.right")]];
                chevron.tintColor = [UIColor tertiaryLabelColor];
                [chevron sizeToFit];
                cell.accessoryView = chevron;
                return cell;
            }
            // Apollo's own rows — returned untouched (their native disclosures etc. intact).
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }

    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];
    BOOL isAddRow = ((NSUInteger)indexPath.row >= items.count);

    // Borrow a native cell (the "Add" row of section 0) so we inherit Apollo's
    // exact theme — background, fonts, and the accent text color used for Add rows.
    NSInteger nativeRows0 = [self tableView:tableView numberOfRowsInSection:0];
    NSIndexPath *borrow = [NSIndexPath indexPathForRow:MAX((NSInteger)0, nativeRows0 - 1) inSection:0];
    UITableViewCell *cell = %orig(tableView, borrow);
    cell.imageView.image = nil;
    cell.accessoryView = nil;

    if (isAddRow) {
        cell.textLabel.text = isSubSection ? @"Add Subreddit..." : @"Add Word...";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // Keep the borrowed accent text color (this IS a native Add cell).
    } else {
        NSString *item = items[indexPath.row];
        cell.textLabel.textColor = [UIColor labelColor]; // override accent → normal item text
        if (isSubSection) {
            cell.textLabel.text = [NSString stringWithFormat:@"r/%@", item];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = item;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        // No header for Blocked Users — the toggle row leads the group in both states.
        if (native > 0 && section == native - 1) return [[UIView alloc] init];
        return %orig;
    }
    NSString *title = (section == native) ? @"Subreddit-Specific Filters" : @"Filter Subreddits by Name";
    return ApolloPFSectionHeaderView(title);
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        // Hide the native Blocked Users footer while collapsed (the lone summary row reads cleaner without it).
        if (native > 0 && section == native - 1 && ![objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue]) {
            return [[UIView alloc] init];
        }
        return %orig;
    }
    NSString *text = (section == native)
        ? @"Hide posts in a specific subreddit by title keyword or post flair. Tap a subreddit to configure. Applies on this device."
        : @"Hide any subreddit whose name contains one of these words, in feeds and in search (e.g. 'circlejerk' hides r/carscirclejerk). Applies on this device.";
    return ApolloPFSectionFooterView(text);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            // Row 0 toggles; deeper rows are Apollo's own (offset by 1).
            if (indexPath.row == 0) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
                [self apollo_pfSetBlockedExpanded:!expanded table:tableView];
                return;
            }
            %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
            return;
        }
        %orig; return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == native) {
        NSArray<NSString *> *subs = [ApolloPostFilterStore allSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            [self apollo_pfOpenDetailForSubreddit:subs[indexPath.row] fromTable:tableView];
        } else {
            [self apollo_pfPromptAddSubredditFromTable:tableView];
        }
    } else {
        NSArray<NSString *> *names = [ApolloPostFilterStore nameSubstrings];
        if ((NSUInteger)indexPath.row >= names.count) {
            [self apollo_pfPromptAddNameFromTable:tableView];
        }
        // Existing name rows: no detail; remove via swipe / Edit.
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            // Row 0 = toggle, last row = Apollo's "Add User" — neither is swipe-deletable;
            // the blocked-user rows in between map to Apollo's rows (offset by 1).
            NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            if (indexPath.row == 0 || (nativeCount > 0 && indexPath.row >= nativeCount)) return NO;
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    NSArray<NSString *> *items = (indexPath.section == native) ? [ApolloPostFilterStore allSubreddits]
                                                              : [ApolloPostFilterStore nameSubstrings];
    return (NSUInteger)indexPath.row < items.count; // item rows deletable; Add row not
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            if (indexPath.row == 0) return NO;
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        // Expanded Blocked Users: deletions act on Apollo's own row (offset by 1).
        // Re-render afterward so the row list AND the "(N)" count in the toggle row
        // stay correct no matter how Apollo animates its own deletion.
        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            %orig(tableView, editingStyle, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
            __weak UITableView *weakTable = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakTable reloadData]; });
            return;
        }
        %orig; return;
    }
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];
    if ((NSUInteger)indexPath.row >= items.count) return;
    NSString *item = items[indexPath.row];
    if (isSubSection) [ApolloPostFilterStore removeSubreddit:item];
    else [ApolloPostFilterStore removeNameSubstring:item];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return @"Delete";
}

#pragma mark - Added actions

%new
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView {
    ApolloSubredditFilterDetailViewController *detail = [[ApolloSubredditFilterDetailViewController alloc] initWithSubreddit:sub];
    __weak UITableView *weakTable = tableView;
    detail.onChange = ^{ [weakTable reloadData]; };
    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.navigationController) {
        [selfVC.navigationController pushViewController:detail animated:YES];
    } else {
        [selfVC presentViewController:[[UINavigationController alloc] initWithRootViewController:detail] animated:YES completion:nil];
    }
}

%new
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filter a Subreddit"
                                                                  message:@"Enter the subreddit to configure (without r/). You'll then add keywords or flairs to hide in it."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"funny";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *sub = [ApolloPostFilterStore normalizeSubreddit:weakAlert.textFields.firstObject.text];
        if (sub.length == 0) return;
        [ApolloPostFilterStore ensureSubreddit:sub];
        [tableView reloadData];
        [self apollo_pfOpenDetailForSubreddit:sub fromTable:tableView];
    }]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filter Subreddits by Name"
                                                                  message:@"Enter a word. Any subreddit whose name contains it is hidden from feeds and search (e.g. 'circlejerk' hides r/carscirclejerk)."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"circlejerk";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *term = [ApolloPostFilterStore normalizeTerm:weakAlert.textFields.firstObject.text];
        if (term.length == 0) return;
        [ApolloPostFilterStore addNameSubstring:term];
        [tableView reloadData];
    }]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Collapsible Blocked Users toggle

%new
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView {
    objc_setAssociatedObject(self, kApolloPFBlockedExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![tableView isKindOfClass:[UITableView class]]) return;
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (native <= 0) return;
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:native - 1] withRowAnimation:UITableViewRowAnimationAutomatic];
}

%end

%ctor {
    %init(_TtC6Apollo29SettingsFiltersViewController = objc_getClass("_TtC6Apollo29SettingsFiltersViewController"));
}

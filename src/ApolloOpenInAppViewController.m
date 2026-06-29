#import "ApolloOpenInAppViewController.h"

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// Sections of the "Open in App" screen. The Apps section gathers the
// "open links of type X in app X" toggles; the Browser section is the default
// browser picker (which governs every other web link).
typedef NS_ENUM(NSInteger, ApolloOpenInAppSection) {
    ApolloOpenInAppSectionApps = 0,
    ApolloOpenInAppSectionBrowser,
    ApolloOpenInAppSectionCount,
};

// Rows within the Apps section. (X/Twitter is intentionally not here — Apollo
// already ships a native "Open Tweets in" picker that even supports third-party
// clients, so a Reborn toggle would just duplicate it. See ApolloShareLinks.xm.)
typedef NS_ENUM(NSInteger, ApolloOpenInAppAppsRow) {
    ApolloOpenInAppAppsRowSteam = 0,
    ApolloOpenInAppAppsRowYouTube,
    ApolloOpenInAppAppsRowGitHub,
    ApolloOpenInAppAppsRowBluesky,
    ApolloOpenInAppAppsRowCount,
};

// Apollo's native "Open Links in" picker persists a String token under this key
// (default "in-app-safari"). We expose just two of its values:
//   - "in-app-safari"  -> opens links inside Apollo (SFSafariViewController)
//   - "external-safari" -> Apollo does a plain -[UIApplication openURL:] of the
//     https URL, which on iOS 14+ already routes to the user's *system default*
//     browser. So "Default Browser" is simply this token relabeled — no behavior
//     hook needed. (Apollo also supports chrome/firefox/etc. tokens, but those
//     only appear when those browsers are installed; we keep it to the two the
//     stock picker shows.)
static NSString *const kApolloOpenLinksInKey      = @"OpenLinksIn";
static NSString *const kApolloBrowserInAppToken   = @"in-app-safari";
static NSString *const kApolloBrowserDefaultToken = @"external-safari";

@implementation ApolloOpenInAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Open in App";
    self.tableView.estimatedRowHeight = 44.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Switch rows

- (UITableViewCell *)switchCellWithIdentifier:(NSString *)identifier
                                        label:(NSString *)label
                                           on:(BOOL)on
                                       action:(SEL)action {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    cell.textLabel.text = label;
    ((UISwitch *)cell.accessoryView).on = on;
    return cell;
}

- (void)steamSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInSteamApp];
}

- (void)youTubeSwitchToggled:(UISwitch *)sender {
    // Mirrors Apollo's own native key, so the native YouTube-app integration and
    // Reborn's Shorts deep-linking both pick up the change.
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenVideosInYouTubeApp];
}

- (void)gitHubSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInGitHubApp];
}

- (void)blueskySwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInBlueskyApp];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloOpenInAppSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloOpenInAppSectionApps:    return ApolloOpenInAppAppsRowCount;
        case ApolloOpenInAppSectionBrowser: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloOpenInAppSectionApps:    return @"Apps";
        case ApolloOpenInAppSectionBrowser: return @"Browser";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloOpenInAppSectionApps) {
        return @"When on, links to these services open directly in their app (if installed) instead of a web view.";
    }
    if (section == ApolloOpenInAppSectionBrowser) {
        return @"Choose how other web links open. In-App Safari opens inside Apollo; Default Browser uses your iOS default browser.";
    }
    return nil;
}

- (UITableViewCell *)appsCellForRow:(NSInteger)row {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (row) {
        case ApolloOpenInAppAppsRowSteam:
            return [self switchCellWithIdentifier:@"Cell_OIA_Steam"
                                            label:@"Open Steam Links in App"
                                               on:[defaults boolForKey:UDKeyOpenLinksInSteamApp]
                                           action:@selector(steamSwitchToggled:)];
        case ApolloOpenInAppAppsRowYouTube:
            return [self switchCellWithIdentifier:@"Cell_OIA_YouTube"
                                            label:@"Open Videos in YouTube App"
                                               on:[defaults boolForKey:UDKeyOpenVideosInYouTubeApp]
                                           action:@selector(youTubeSwitchToggled:)];
        case ApolloOpenInAppAppsRowGitHub:
            return [self switchCellWithIdentifier:@"Cell_OIA_GitHub"
                                            label:@"Open GitHub Links in App"
                                               on:[defaults boolForKey:UDKeyOpenLinksInGitHubApp]
                                           action:@selector(gitHubSwitchToggled:)];
        case ApolloOpenInAppAppsRowBluesky:
            return [self switchCellWithIdentifier:@"Cell_OIA_Bluesky"
                                            label:@"Open Bluesky Links in App"
                                               on:[defaults boolForKey:UDKeyOpenLinksInBlueskyApp]
                                           action:@selector(blueskySwitchToggled:)];
        default:
            return [[UITableViewCell alloc] init];
    }
}

// "In-App Safari" when the stored token is in-app (or unset = Apollo's default);
// "Default Browser" for the external token (or any other external browser token).
- (NSString *)browserModeLabel {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kApolloOpenLinksInKey];
    if (token.length == 0 || [token isEqualToString:kApolloBrowserInAppToken]) {
        return @"In-App Safari";
    }
    return @"Default Browser";
}

- (UITableViewCell *)browserCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"Default Browser";
    cell.detailTextLabel.text = [self browserModeLabel];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)presentBrowserSheetFromCell:(UITableViewCell *)cell {
    NSString *current = [self browserModeLabel];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Default Browser"
                         message:@"In-App Safari opens links inside Apollo. Default Browser opens them in your iOS default browser (Safari, Chrome, etc.)."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSArray<NSString *> *> *options = @[
        @[@"In-App Safari",   kApolloBrowserInAppToken],
        @[@"Default Browser", kApolloBrowserDefaultToken],
    ];
    for (NSArray<NSString *> *option in options) {
        NSString *label = option[0];
        NSString *token = option[1];
        NSString *title = [label isEqualToString:current] ? [NSString stringWithFormat:@"%@ (Current)", label] : label;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:token forKey:kApolloOpenLinksInKey];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloOpenInAppSectionApps) {
        return [self appsCellForRow:indexPath.row];
    }
    if (indexPath.section == ApolloOpenInAppSectionBrowser) {
        return [self browserCell];
    }
    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == ApolloOpenInAppSectionBrowser) {
        [self presentBrowserSheetFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

@end

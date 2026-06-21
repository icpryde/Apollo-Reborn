#import "ApolloAISettingsViewController.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloAISettingsSection) {
    ApolloAISettingsSectionGeneral = 0,
    ApolloAISettingsSectionSummaries,
    ApolloAISettingsSectionAvailability,
    ApolloAISettingsSectionCount,
};

// ObjC surface exported by ApolloFoundationModels.swift. Resolve it dynamically
// so this settings screen remains loadable when the build SDK does not contain
// FoundationModels and the Swift bridge reports the feature unavailable.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
@end

@implementation ApolloAISettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apollo AI";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (UITableViewCell *)switchCellWithLabel:(NSString *)label
                                      on:(BOOL)on
                                 enabled:(BOOL)enabled
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = on;
    toggle.enabled = enabled;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (NSInteger)modelAvailabilityStatus {
    Class bridgeClass = NSClassFromString(@"ApolloFoundationModels");
    if (!bridgeClass || ![bridgeClass respondsToSelector:@selector(shared)]) return 4;

    ApolloFoundationModels *bridge = [(id)bridgeClass shared];
    if (![bridge respondsToSelector:@selector(availabilityStatus)]) return 5;
    return [bridge availabilityStatus];
}

- (NSString *)modelAvailabilityText {
    switch ([self modelAvailabilityStatus]) {
        case 0: return @"Ready";
        case 1: return @"Reported Disabled";
        case 2: return @"Model Downloading";
        case 3: return @"Unsupported Device";
        case 4: return @"Requires iOS 26";
        default: return @"Unknown";
    }
}

- (void)reloadSummaryControls {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloAISettingsSectionSummaries]
                  withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloAISettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return 1;
        case ApolloAISettingsSectionSummaries: return 3;
        case ApolloAISettingsSectionAvailability: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return @"General";
        case ApolloAISettingsSectionSummaries: return @"Summaries";
        case ApolloAISettingsSectionAvailability: return @"Availability";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloAISettingsSectionGeneral) {
        return @"Apollo AI runs entirely on-device using Apple Intelligence. No post or comment text is sent to an external AI service.";
    }
    if (section == ApolloAISettingsSectionSummaries) {
        return @"Tap to Summarize generates only the card you request. Leave it off to generate enabled summaries automatically when opening a thread.";
    }
    if (section == ApolloAISettingsSectionAvailability) {
        return @"Availability is diagnostic. On some iOS versions, sideloaded apps may report Apple Intelligence as disabled even when generation still works.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == ApolloAISettingsSectionGeneral) {
        return [self switchCellWithLabel:@"Enable Apollo AI"
                                      on:[defaults boolForKey:UDKeyEnableAISummaries]
                                 enabled:YES
                                  action:@selector(masterSwitchChanged:)];
    }

    if (indexPath.section == ApolloAISettingsSectionSummaries) {
        BOOL enabled = sEnableAISummaries;
        switch (indexPath.row) {
            case 0:
                return [self switchCellWithLabel:@"Post & Link Summaries"
                                              on:[defaults boolForKey:UDKeyEnableAIPostSummaries]
                                         enabled:enabled
                                          action:@selector(postSummariesSwitchChanged:)];
            case 1:
                return [self switchCellWithLabel:@"Comment Summaries"
                                              on:[defaults boolForKey:UDKeyEnableAICommentSummaries]
                                         enabled:enabled
                                          action:@selector(commentSummariesSwitchChanged:)];
            case 2:
                return [self switchCellWithLabel:@"Tap to Summarize"
                                              on:[defaults boolForKey:UDKeyEnableTapToSummarize]
                                         enabled:enabled
                                          action:@selector(tapToSummarizeSwitchChanged:)];
            default:
                break;
        }
    }

    if (indexPath.section == ApolloAISettingsSectionAvailability) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"On-Device Model";
        cell.detailTextLabel.text = [self modelAvailabilityText];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

#pragma mark - Actions

- (void)masterSwitchChanged:(UISwitch *)sender {
    sEnableAISummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAISummaries forKey:UDKeyEnableAISummaries];
    [self reloadSummaryControls];
}

- (void)postSummariesSwitchChanged:(UISwitch *)sender {
    sEnableAIPostSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAIPostSummaries forKey:UDKeyEnableAIPostSummaries];
}

- (void)commentSummariesSwitchChanged:(UISwitch *)sender {
    sEnableAICommentSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAICommentSummaries forKey:UDKeyEnableAICommentSummaries];
}

- (void)tapToSummarizeSwitchChanged:(UISwitch *)sender {
    sEnableTapToSummarize = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableTapToSummarize forKey:UDKeyEnableTapToSummarize];
}

@end

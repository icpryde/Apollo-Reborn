#import "ApolloLinkPreviewSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloLPSettingsSection) {
    ApolloLPSettingsSectionModes = 0,  // Body + Comments preview modes
    ApolloLPSettingsSectionColor,      // Card color picker + quick swatches + reset
    ApolloLPSettingsSectionCount,
};

// Rows within the Color section. The reset row only exists while a custom color
// is set; numberOfRowsInSection reflects that.
typedef NS_ENUM(NSInteger, ApolloLPColorRow) {
    ApolloLPColorRowPicker = 0,
    ApolloLPColorRowSwatches,
    ApolloLPColorRowReset,
};

// Vivid quick-pick palette (Apple system colors). These write the same hex the
// full picker would, so the two paths stay consistent. Kept to nine so the row
// of fixed-size swatches fits without clipping even on the narrowest screens.
static NSArray<NSString *> *ApolloLPQuickSwatchHexes(void) {
    return @[@"FF3B30", @"FF9500", @"FFCC00", @"34C759", @"30B0C7",
             @"007AFF", @"5856D6", @"AF52DE", @"FF2D55"];
}

@interface ApolloLinkPreviewSettingsViewController () <UIColorPickerViewControllerDelegate>
@end

@implementation ApolloLinkPreviewSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Rich Link Previews";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - State helpers

- (BOOL)hasCustomColor {
    return [sLinkPreviewCardColorHex isKindOfClass:[NSString class]] && sLinkPreviewCardColorHex.length > 0;
}

- (UIColor *)currentCardColor {
    return ApolloColorFromHexString(sLinkPreviewCardColorHex);
}

- (NSString *)modeTextForMode:(NSInteger)mode {
    switch (mode) {
        case ApolloLinkPreviewModeOff:     return @"Off";
        case ApolloLinkPreviewModeCompact: return @"Compact";
        case ApolloLinkPreviewModeFull:
        default:                           return @"Full";
    }
}

// A rounded color swatch for the Color row's left image. Default (no color) is a
// neutral gray chip so the row never looks broken before a color is chosen.
- (UIImage *)swatchImageForColor:(UIColor *)color {
    CGSize size = CGSizeMake(26.0, 26.0);
    UIColor *fill = color ?: [UIColor systemGray3Color];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.0, 1.0, 24.0, 24.0) cornerRadius:6.0];
        [fill setFill];
        [path fill];
        [[UIColor colorWithWhite:0.5 alpha:0.35] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - Mutation

- (void)storeCardColorHex:(NSString *)hex {
    // Updates the main-thread NSString + the render-safe packed snapshot together.
    ApolloSetLinkPreviewCardColorHex(hex);
    [[NSUserDefaults standardUserDefaults] setObject:(sLinkPreviewCardColorHex ?: @"") forKey:UDKeyLinkPreviewCardColorHex];
}

- (void)broadcastChangeForArea:(NSString *)area {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                        object:nil
                                                      userInfo:@{@"area": area}];
    if (self.settingsDidChange) self.settingsDidChange(area);
}

// Commit a card color (or "" / nil to reset to Default) and refresh everything.
- (void)applyCardColorHex:(NSString *)hex {
    [self storeCardColorHex:hex];
    [self broadcastChangeForArea:@"card-color"];
    [self.tableView reloadData];
}

- (void)setLinkPreviewMode:(NSInteger)mode body:(BOOL)body {
    if (mode < ApolloLinkPreviewModeOff || mode > ApolloLinkPreviewModeFull) mode = ApolloLinkPreviewModeFull;
    if (body) {
        sLinkPreviewBodyMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewBodyMode];
    } else {
        sLinkPreviewCommentsMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewCommentsMode];
    }
    [self broadcastChangeForArea:body ? @"body" : @"comments"];
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)swatchTapped:(UIButton *)sender {
    NSArray<NSString *> *hexes = ApolloLPQuickSwatchHexes();
    if (sender.tag < 0 || sender.tag >= (NSInteger)hexes.count) return;
    [self applyCardColorHex:hexes[sender.tag]];
}

- (void)presentCardColorPicker {
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = NO;
    picker.title = @"Preview Card Color";
    picker.selectedColor = [self currentCardColor] ?: [UIColor systemBlueColor];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentModeSheetForBody:(BOOL)body fromCell:(UITableViewCell *)cell {
    NSInteger currentMode = body ? sLinkPreviewBodyMode : sLinkPreviewCommentsMode;
    NSString *title = body ? @"Body Link Previews" : @"Comment Link Previews";
    NSString *message = body
        ? @"Choose how rich link preview cards appear in feeds and post bodies."
        : @"Choose how rich link preview cards appear in comments.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSNumber *> *modes = @[@(ApolloLinkPreviewModeFull), @(ApolloLinkPreviewModeCompact), @(ApolloLinkPreviewModeOff)];
    for (NSNumber *modeNumber in modes) {
        NSInteger mode = modeNumber.integerValue;
        NSString *name = [self modeTextForMode:mode];
        NSString *actionTitle = (mode == currentMode) ? [NSString stringWithFormat:@"%@ (Current)", name] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setLinkPreviewMode:mode body:body];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    // Fires continuously while dragging — store the value and lightly refresh the
    // Color section, but defer the heavy feed broadcast to didFinish.
    [self storeCardColorHex:ApolloHexStringFromColor(viewController.selectedColor)];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloLPSettingsSectionColor]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self applyCardColorHex:ApolloHexStringFromColor(viewController.selectedColor)];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloLPSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloLPSettingsSectionModes: return 2;
        case ApolloLPSettingsSectionColor: return [self hasCustomColor] ? 3 : 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloLPSettingsSectionModes: return @"Previews";
        case ApolloLPSettingsSectionColor: return @"Card Color";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloLPSettingsSectionModes) {
        return @"Off hides the card, Compact shows a small thumbnail row, Full shows a large hero image card.";
    }
    if (section == ApolloLPSettingsSectionColor) {
        return @"The card is painted the exact color you pick, the same in light and dark mode, with title and description text automatically set to black or white for contrast. Default keeps the standard neutral card.";
    }
    return nil;
}

- (UITableViewCell *)modeCellForBody:(BOOL)body {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = body ? @"Body" : @"Comments";
    cell.detailTextLabel.text = [self modeTextForMode:body ? sLinkPreviewBodyMode : sLinkPreviewCommentsMode];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (UITableViewCell *)colorPickerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"Color";
    cell.imageView.image = [self swatchImageForColor:[self currentCardColor]];
    cell.detailTextLabel.text = [self hasCustomColor]
        ? [NSString stringWithFormat:@"#%@", [sLinkPreviewCardColorHex uppercaseString]]
        : @"Default";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (UITableViewCell *)swatchPickerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:11.0],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-11.0],
    ]];

    NSArray<NSString *> *hexes = ApolloLPQuickSwatchHexes();
    NSString *current = [self hasCustomColor] ? [sLinkPreviewCardColorHex uppercaseString] : nil;
    for (NSInteger i = 0; i < (NSInteger)hexes.count; i++) {
        NSString *hex = hexes[i];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.backgroundColor = ApolloColorFromHexString(hex);
        button.layer.cornerRadius = 14.0;
        button.tag = i;
        button.accessibilityLabel = [NSString stringWithFormat:@"Card color #%@", hex];
        [button addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        if (current && [current isEqualToString:hex]) {
            button.layer.borderColor = [UIColor labelColor].CGColor;
            button.layer.borderWidth = 2.5;
        }
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintEqualToConstant:28.0],
            [button.heightAnchor constraintEqualToConstant:28.0],
        ]];
        [stack addArrangedSubview:button];
    }
    return cell;
}

- (UITableViewCell *)resetCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"Use Default (No Color)";
    cell.textLabel.textColor = self.view.tintColor;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloLPSettingsSectionModes) {
        return [self modeCellForBody:(indexPath.row == 0)];
    }
    if (indexPath.section == ApolloLPSettingsSectionColor) {
        switch (indexPath.row) {
            case ApolloLPColorRowPicker:   return [self colorPickerCell];
            case ApolloLPColorRowSwatches: return [self swatchPickerCell];
            case ApolloLPColorRowReset:    return [self resetCell];
            default: break;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    if (indexPath.section == ApolloLPSettingsSectionModes) {
        [self presentModeSheetForBody:(indexPath.row == 0) fromCell:cell];
        return;
    }
    if (indexPath.section == ApolloLPSettingsSectionColor) {
        if (indexPath.row == ApolloLPColorRowPicker) {
            [self presentCardColorPicker];
        } else if (indexPath.row == ApolloLPColorRowReset) {
            [self applyCardColorHex:@""];
        }
    }
}

@end

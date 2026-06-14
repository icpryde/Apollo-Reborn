#import "ApolloThemeBuilderViewController.h"
#import "ApolloThemeBuilder.h"
#import "ApolloCommon.h"

// Relative luminance (sRGB-weighted; good enough for a contrast hint) + WCAG
// contrast ratio, used to warn about color combos that can't be auto-fixed.
static CGFloat ATBLuminance(NSString *hex) {
    UIColor *c = ApolloThemeBuilderColorFromHex(hex);
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (!c || ![c getRed:&r green:&g blue:&b alpha:&a]) return 0.5;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
static CGFloat ATBContrast(CGFloat l1, CGFloat l2) {
    CGFloat hi = l1 > l2 ? l1 : l2, lo = l1 < l2 ? l1 : l2;
    return (hi + 0.05) / (lo + 0.05);
}

// Sections
typedef NS_ENUM(NSInteger, ThemeBuilderSection) {
    SectionEnable = 0,
    SectionPreset,
    SectionLightColors,
    SectionDarkColors,
    SectionReset,
    ThemeBuilderSectionCount,
};

// A starting palette the user can seed the builder with. Accents come from the
// runtime-derived per-theme tables in docs/theme-builder-RE.md; backgrounds are
// the stock values for that theme (tinted themes have full bespoke palettes,
// the rest share Apollo's standard neutrals).
@interface ThemeBuilderPreset : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *colors; // "<role>.<mode>" -> hex
@end
@implementation ThemeBuilderPreset
@end

@interface ApolloThemeBuilderViewController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *editingRole;
@property (nonatomic, copy) NSString *editingMode;
@property (nonatomic, strong) NSTimer *repaintDebounce;
@property (nonatomic, assign) CGFloat lastPreviewWidth;
@end

@implementation ApolloThemeBuilderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theme Builder";
    [self refreshPreview];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Rebuild the preview header when the table width changes (rotation, first
    // layout) — tableHeaderView needs an explicit, correct width.
    CGFloat w = self.tableView.bounds.size.width;
    if (w > 0 && fabs(w - self.lastPreviewWidth) > 0.5) {
        [self refreshPreview];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.traitCollection.userInterfaceStyle != previous.userInterfaceStyle) {
        [self refreshPreview];
    }
}

#pragma mark - Live preview

// Which appearance the preview (and the live app behind us) is currently
// showing — picks the matching saved color set.
- (NSString *)previewMode {
    return (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
}

- (UIColor *)previewColorForRole:(NSString *)role {
    return ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(role, [self previewMode]))
        ?: UIColor.systemGrayColor;
}

- (void)refreshPreview {
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) return;
    self.lastPreviewWidth = width;
    self.tableView.tableHeaderView = [self makePreviewViewWithWidth:width];
}

// A mock Apollo post card rendered with the current role colors, so the user
// sees their theme update in place (this settings screen itself is not painted
// by Apollo's theme system, so without this nothing visibly changes here).
- (UIView *)makePreviewViewWithWidth:(CGFloat)width {
    UIColor *page      = [self previewColorForRole:kApolloThemeRoleSecondaryBG];
    UIColor *card      = [self previewColorForRole:kApolloThemeRolePrimaryBG];
    UIColor *accent    = [self previewColorForRole:kApolloThemeRoleAccent];
    UIColor *separator = [self previewColorForRole:kApolloThemeRoleSeparator];
    UIColor *bar       = [self previewColorForRole:kApolloThemeRoleBar];
    UIColor *tertiary  = [self previewColorForRole:kApolloThemeRoleTertiaryBG];
    UIColor *gray      = [self previewColorForRole:kApolloThemeRoleGray];

    BOOL dark = [[self previewMode] isEqualToString:@"dark"];
    UIColor *primaryText = dark ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0];

    CGFloat margin = 16, cardInset = 16;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 210)];
    container.backgroundColor = page;

    // Faux nav/tab bar strip (chrome color).
    UIView *barStrip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 8)];
    barStrip.backgroundColor = bar;
    [container addSubview:barStrip];

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(margin, 14, width - 2 * margin, 16)];
    caption.text = [NSString stringWithFormat:@"Live preview · %@ mode", dark ? @"Dark" : @"Light"];
    caption.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    caption.textColor = gray;
    [container addSubview:caption];

    CGFloat cardX = margin, cardY = 38, cardW = width - 2 * margin, cardH = 152;
    UIView *postCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    postCard.backgroundColor = card;
    postCard.layer.cornerRadius = 12;
    [container addSubview:postCard];

    // Header row: accent avatar + subreddit/title.
    UIView *avatar = [[UIView alloc] initWithFrame:CGRectMake(cardInset, 14, 34, 34)];
    avatar.backgroundColor = accent;
    avatar.layer.cornerRadius = 17;
    [postCard addSubview:avatar];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(cardInset + 44, 14, cardW - cardInset * 2 - 44, 18)];
    sub.text = @"r/apolloapp";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sub.textColor = accent;
    [postCard addSubview:sub];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectMake(cardInset + 44, 32, cardW - cardInset * 2 - 44, 16)];
    meta.text = @"u/christianselig · 2h";
    meta.font = [UIFont systemFontOfSize:13];
    meta.textColor = gray;
    [postCard addSubview:meta];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(cardInset, 58, cardW - cardInset * 2, 38)];
    title.text = @"Your custom theme, live as you build it";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = primaryText;
    title.numberOfLines = 2;
    [postCard addSubview:title];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(cardInset, 104, cardW - cardInset * 2, 1)];
    line.backgroundColor = separator;
    [postCard addSubview:line];

    // Footer: accent vote pill + tertiary comment chip.
    UILabel *vote = [[UILabel alloc] initWithFrame:CGRectMake(cardInset, 116, 92, 26)];
    vote.text = @"▲ 1.2k";
    vote.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    vote.textColor = UIColor.whiteColor;
    vote.textAlignment = NSTextAlignmentCenter;
    vote.backgroundColor = accent;
    vote.layer.cornerRadius = 13;
    vote.clipsToBounds = YES;
    [postCard addSubview:vote];

    UILabel *comments = [[UILabel alloc] initWithFrame:CGRectMake(cardInset + 100, 116, 96, 26)];
    comments.text = @"💬 42";
    comments.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    comments.textColor = primaryText;
    comments.textAlignment = NSTextAlignmentCenter;
    comments.backgroundColor = tertiary;
    comments.layer.cornerRadius = 13;
    comments.clipsToBounds = YES;
    [postCard addSubview:comments];

    return container;
}

#pragma mark - Presets

+ (NSArray<ThemeBuilderPreset *> *)presets {
    static NSArray<ThemeBuilderPreset *> *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Standard neutral backgrounds shared by Apollo's non-tinted themes.
        NSDictionary *neutrals = @{
            @"primaryBG.light": @"FFFFFF",   @"primaryBG.dark": @"131516",
            @"secondaryBG.light": @"F2F3F7", @"secondaryBG.dark": @"000000",
            @"tertiaryBG.light": @"F8F8F8",  @"tertiaryBG.dark": @"1A1A1A",
            @"separator.light": @"EEEEEF",   @"separator.dark": @"232323",
            @"bar.light": @"FBFBFB",         @"bar.dark": @"131516",
            @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
        };
        ThemeBuilderPreset *(^standard)(NSString *, NSString *, NSString *) =
        ^(NSString *name, NSString *accentLight, NSString *accentDark) {
            ThemeBuilderPreset *p = [ThemeBuilderPreset new];
            p.name = name;
            NSMutableDictionary *c = [neutrals mutableCopy];
            c[@"accent.light"] = accentLight;
            c[@"accent.dark"] = accentDark;
            p.colors = c;
            return p;
        };
        ThemeBuilderPreset *(^tinted)(NSString *, NSDictionary *) =
        ^(NSString *name, NSDictionary *colors) {
            ThemeBuilderPreset *p = [ThemeBuilderPreset new];
            p.name = name;
            p.colors = colors;
            return p;
        };
        presets = @[
            standard(@"Default (Royal Blue)", @"007AFF", @"2399FF"),
            standard(@"Nefertiti", @"01A200", @"01A200"),
            standard(@"Fiery Stare", @"FF0000", @"FD0000"),
            standard(@"Spooky Pumpkin", @"FF6200", @"F25D00"),
            tinted(@"Solarized", @{
                @"accent.light": @"268BD2",      @"accent.dark": @"268BD2",
                @"primaryBG.light": @"FDF6E3",   @"primaryBG.dark": @"002B36",
                @"secondaryBG.light": @"E6DFCF", @"secondaryBG.dark": @"003745",
                @"tertiaryBG.light": @"F2ECDA",  @"tertiaryBG.dark": @"00181F",
                @"separator.light": @"E0DCCD",   @"separator.dark": @"002836",
                @"bar.light": @"F1ECDC",         @"bar.dark": @"00171F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            tinted(@"Outrun", @{
                @"accent.light": @"C400A6",      @"accent.dark": @"FF00D8",
                @"primaryBG.light": @"CFD7E8",   @"primaryBG.dark": @"061636",
                @"secondaryBG.light": @"BAC1D1", @"secondaryBG.dark": @"081D47",
                @"tertiaryBG.light": @"C1C8D9",  @"tertiaryBG.dark": @"041129",
                @"separator.light": @"B5B9C7",   @"separator.dark": @"06214D",
                @"bar.light": @"C5CAD9",         @"bar.dark": @"031229",
                @"gray.light": @"ABABAB",        @"gray.dark": @"484E5B",
            }),
            tinted(@"Sunset", @{
                @"accent.light": @"FF6600",      @"accent.dark": @"FF7D00",
                @"primaryBG.light": @"FFE3D0",   @"primaryBG.dark": @"000F29",
                @"secondaryBG.light": @"F2D8C7", @"secondaryBG.dark": @"12223D",
                @"tertiaryBG.light": @"F2D8C7",  @"tertiaryBG.dark": @"000F29",
                @"separator.light": @"E0CBBD",   @"separator.dark": @"061B40",
                @"bar.light": @"F1DACB",         @"bar.dark": @"000B1F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            tinted(@"Sepia", @{
                @"accent.light": @"B88023",      @"accent.dark": @"D3AC72",
                @"primaryBG.light": @"F1EAD9",   @"primaryBG.dark": @"211E1A",
                @"secondaryBG.light": @"DBD5CA", @"secondaryBG.dark": @"38332C",
                @"tertiaryBG.light": @"E6DFCF",  @"tertiaryBG.dark": @"141310",
                @"separator.light": @"D4CEC0",   @"separator.dark": @"29271F",
                @"bar.light": @"E6E0D1",         @"bar.dark": @"14130F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            standard(@"Monochromatic", @"000000", @"FFFFFF"),
            standard(@"Navy", @"0058B8", @"0060C9"),
            standard(@"Skies on Skies", @"00B5F2", @"01ADE8"),
            standard(@"Majestic Purple", @"8800FF", @"9C2CFF"),
            standard(@"Magentasplosion", @"FF00B2", @"E800A2"),
            standard(@"Sniffing Walnut", @"A74E00", @"A74E00"),
            standard(@"Fisher King", @"808286", @"76787D"),
            tinted(@"Dracula", @{
                @"accent.light": @"9760FF",      @"accent.dark": @"AD81FF",
                @"primaryBG.light": @"F8F8F3",   @"primaryBG.dark": @"1A1D29",
                @"secondaryBG.light": @"EDEDE8", @"secondaryBG.dark": @"222636",
                @"tertiaryBG.light": @"F8F8F3",  @"tertiaryBG.dark": @"1A1D29",
                @"separator.light": @"D7D3E0",   @"separator.dark": @"242838",
                @"bar.light": @"E6E4EB",         @"bar.dark": @"12141C",
                @"gray.light": @"ABABAB",        @"gray.dark": @"484E5B",
            }),
            standard(@"Mint", @"37BB98", @"37BB98"),
        ];
    });
    return presets;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ThemeBuilderSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SectionEnable: return 1;
        case SectionPreset: return 1;
        case SectionLightColors:
        case SectionDarkColors: return (NSInteger)ApolloThemeBuilderRoleKeys().count;
        case SectionReset: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SectionPreset: return @"Start From";
        case SectionLightColors: return @"Light Mode Colors";
        case SectionDarkColors: return @"Dark Mode Colors";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case SectionEnable:
            return @"Paints Apollo with your own colors. Your theme lives in the Outrun "
                   @"slot of Apollo's theme picker — picking a different theme there switches "
                   @"this off, re-selecting Outrun (or this switch) brings it back.";
        case SectionPreset:
            return @"Seed every color from one of Apollo's built-in themes, then adjust to taste.";
        case SectionLightColors: return [self contrastWarningForMode:@"light"];
        case SectionDarkColors:  return [self contrastWarningForMode:@"dark"];
        case SectionReset: return nil;
        default: return nil;
    }
}

// Text is auto-contrasted by the engine, but the accent can't be — icons, links
// and the selected tab all use it, so warn when it's too close to either
// background to be visible.
- (NSString *)contrastWarningForMode:(NSString *)mode {
    CGFloat accent = ATBLuminance(ApolloThemeBuilderSavedHex(@"accent", mode));
    CGFloat primary = ATBLuminance(ApolloThemeBuilderSavedHex(@"primaryBG", mode));
    CGFloat secondary = ATBLuminance(ApolloThemeBuilderSavedHex(@"secondaryBG", mode));
    CGFloat worst = MIN(ATBContrast(accent, primary), ATBContrast(accent, secondary));
    if (worst < 1.45) {
        return @"⚠︎ Your accent is very close to the background — icons, links and the "
               @"selected tab may be hard to see. Pick a more contrasting accent.";
    }
    if (worst < 2.0) {
        return @"Your accent has low contrast with the background; icons may look faint.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SectionEnable) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Use Custom Theme";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = ApolloThemeBuilderIsEnabled();
        [toggle addTarget:self action:@selector(enableToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    if (indexPath.section == SectionPreset) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Apollo Theme…";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.section == SectionReset) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Reset All Colors";
        cell.textLabel.textColor = [UIColor systemRedColor];
        return cell;
    }

    NSString *mode = (indexPath.section == SectionLightColors) ? @"light" : @"dark";
    NSString *role = ApolloThemeBuilderRoleKeys()[indexPath.row];
    NSString *hex = ApolloThemeBuilderSavedHex(role, mode);

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = ApolloThemeBuilderRoleDisplayName(role);
    cell.detailTextLabel.text = [@"#" stringByAppendingString:hex];
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];

    UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    swatch.backgroundColor = ApolloThemeBuilderColorFromHex(hex);
    swatch.layer.cornerRadius = 7;
    swatch.layer.borderWidth = 1;
    swatch.layer.borderColor = [UIColor separatorColor].CGColor;
    cell.accessoryView = swatch;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == SectionPreset) {
        [self presentPresetPicker];
        return;
    }
    if (indexPath.section == SectionReset) {
        [self confirmReset];
        return;
    }
    if (indexPath.section != SectionLightColors && indexPath.section != SectionDarkColors) return;

    self.editingMode = (indexPath.section == SectionLightColors) ? @"light" : @"dark";
    self.editingRole = ApolloThemeBuilderRoleKeys()[indexPath.row];

    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = NO;
    picker.title = [NSString stringWithFormat:@"%@ (%@)",
                    ApolloThemeBuilderRoleDisplayName(self.editingRole),
                    [self.editingMode capitalizedString]];
    picker.selectedColor = ApolloThemeBuilderColorFromHex(
        ApolloThemeBuilderSavedHex(self.editingRole, self.editingMode)) ?: UIColor.systemBlueColor;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Actions

- (void)enableToggled:(UISwitch *)toggle {
    ApolloThemeBuilderSetEnabled(toggle.on);
    if (toggle.on) {
        ApolloThemeBuilderActivateDonorLive();
    } else {
        ApolloThemeBuilderForceRepaint();
    }
    [self refreshPreview];
}

- (void)presentPresetPicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Start From Theme"
                                                                   message:@"Replaces all custom colors with this theme's palette."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (ThemeBuilderPreset *preset in [[self class] presets]) {
        [sheet addAction:[UIAlertAction actionWithTitle:preset.name style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            for (NSString *key in preset.colors) {
                NSArray *parts = [key componentsSeparatedByString:@"."];
                ApolloThemeBuilderSaveHex(parts[0], parts[1], preset.colors[key]);
            }
            [self.tableView reloadData];
            [self refreshPreview];
            ApolloThemeBuilderForceRepaint();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset All Colors?"
                                                                   message:@"Returns every color to the Outrun defaults."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kApolloCustomThemeColorsKey];
        ApolloThemeBuilderReloadOverrides();
        [self.tableView reloadData];
        [self refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)picker {
    if (!self.editingRole || !self.editingMode) return;
    ApolloThemeBuilderSaveHex(self.editingRole, self.editingMode,
                              ApolloThemeBuilderHexFromColor(picker.selectedColor));
    [self refreshPreview];
    // Live preview behind the sheet, debounced so continuous drags don't
    // thrash the trait-flip repaint.
    [self.repaintDebounce invalidate];
    self.repaintDebounce = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO
                                                             block:^(NSTimer *timer) {
        ApolloThemeBuilderForceRepaint();
    }];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self.repaintDebounce invalidate];
    self.repaintDebounce = nil;
    [self.tableView reloadData];
    [self refreshPreview];
    ApolloThemeBuilderForceRepaint();
}

@end

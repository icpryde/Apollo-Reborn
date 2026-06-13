#import "ApolloThemeBuilderViewController.h"
#import "ApolloThemeBuilder.h"
#import "ApolloCommon.h"

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
@end

@implementation ApolloThemeBuilderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theme Builder";
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
        case SectionReset: return nil;
        default: return nil;
    }
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
    ApolloThemeBuilderForceRepaint();
}

@end

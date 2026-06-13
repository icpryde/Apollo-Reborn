// ApolloThemeBuilder.xm — custom user theme engine ("Theme Builder").
//
// Apollo's per-theme colors are hardcoded Swift switch constants resolved at
// UIColor-creation time (see docs/theme-builder-RE.md for the full
// runtime-derived tables). There is no data-driven theme storage to edit, so
// the builder works by *donor-slot hijack*:
//
//   1. When enabled, the builder selects the "outrun" theme in Apollo's own
//      theme system (group defaults key "AppColorTheme"). Apollo then paints
//      the whole app with outrun's role constants — 7 light + 7 dark RGB
//      values that are unique enough to act as sentinels (no overlap with
//      system colors or other Apollo constants).
//   2. The UIColor constructor hooks below swap each outrun constant for the
//      user's color for that role at creation time, restricted to call sites
//      inside the Apollo binary. Replacement happens by re-invoking the
//      original constructor with substituted components, so object ownership
//      and downstream derivations (alpha variants etc.) behave exactly like
//      the stock path.
//
// If the user later picks a different theme in Apollo's own picker, outrun's
// constants stop being produced and the remap naturally deactivates; the
// NSUserDefaults hook notices and clears the enabled flag so the builder UI
// stays truthful.

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import "ApolloCommon.h"
#import "ApolloThemeBuilder.h"

NSString * const kApolloCustomThemeEnabledKey = @"ApolloRebornCustomThemeEnabled";
NSString * const kApolloCustomThemeColorsKey  = @"ApolloRebornCustomThemeColors";

NSString * const kApolloThemeRoleAccent      = @"accent";
NSString * const kApolloThemeRolePrimaryBG   = @"primaryBG";
NSString * const kApolloThemeRoleSecondaryBG = @"secondaryBG";
NSString * const kApolloThemeRoleTertiaryBG  = @"tertiaryBG";
NSString * const kApolloThemeRoleSeparator   = @"separator";
NSString * const kApolloThemeRoleBar         = @"bar";
NSString * const kApolloThemeRoleGray        = @"gray";

static NSString * const kAppColorThemeKey = @"AppColorTheme";
static NSString * const kDonorThemeName   = @"outrun";
static NSString * const kAppGroupSuite    = @"group.com.christianselig.apollo";

// ---------------------------------------------------------------------------
// Donor constant table (outrun, from the runtime mapping pass)
// ---------------------------------------------------------------------------

typedef struct {
    const char *role;      // role key
    const char *mode;      // "light" / "dark"
    uint8_t r, g, b;       // donor constant bytes Apollo passes to UIColor
} ThemeSlot;

#define KSLOTCOUNT 14
static const ThemeSlot kSlots[KSLOTCOUNT] = {
    {"accent",      "light", 0xC4, 0x00, 0xA6},
    {"primaryBG",   "light", 0xCF, 0xD7, 0xE8},
    {"secondaryBG", "light", 0xBA, 0xC1, 0xD1},
    {"tertiaryBG",  "light", 0xC1, 0xC8, 0xD9},
    {"separator",   "light", 0xB5, 0xB9, 0xC7},
    {"bar",         "light", 0xC5, 0xCA, 0xD9},
    {"gray",        "light", 0xAB, 0xAB, 0xAB},
    {"accent",      "dark",  0xFF, 0x00, 0xD8},
    {"primaryBG",   "dark",  0x06, 0x16, 0x36},
    {"secondaryBG", "dark",  0x08, 0x1D, 0x47},
    {"tertiaryBG",  "dark",  0x04, 0x11, 0x29},
    {"separator",   "dark",  0x06, 0x21, 0x4D},
    {"bar",         "dark",  0x03, 0x12, 0x29},
    {"gray",        "dark",  0x48, 0x4E, 0x5B},
};

// Resolved replacement components per slot (written under sLock, read hot).
static CGFloat sRepl[KSLOTCOUNT][3];
static bool sSlotCustomized[KSLOTCOUNT]; // user color differs from donor
static volatile bool sRemapActive = false;
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
// Fast first-byte filter: bit set if some slot's r-byte equals the value.
static uint8_t sRByteFilter[256];

// ---------------------------------------------------------------------------
// Auto-contrast neutral grays
// ---------------------------------------------------------------------------
//
// Apollo's tinted themes (outrun, sepia…) only retint backgrounds + accent;
// everything else — secondary/tertiary text, icon tints, faint usernames,
// timestamps, quoted text, separators — is drawn with a *family* of
// theme-independent neutral grays (verified via backtrace: e.g. getter
// 0x1002cbad8 emits 919191 light / 84878C dark for every theme; many more
// grays come through other shared getters). Apollo stays legible only because
// its own backgrounds are light/muted. The builder lets the user pick
// saturated or dark backgrounds, against which fixed grays go low-contrast or
// vanish (illegible labels, "missing" icons).
//
// Rather than enumerate every gray constant (brittle, never complete), we
// detect *any* near-neutral gray Apollo creates and re-map it onto a contrast
// ramp against the user's chosen background — preserving the gray's relative
// prominence (a faint gray stays subtle, a strong gray stays strong) while
// guaranteeing it lands on the readable side of the background. Near-black and
// near-white are left alone (structural: primary text, white-on-accent, glyph
// fills), as are saturated colors (real theme/content colors).
//
// Effective primary-background luminance per mode (user color or donor),
// recomputed in ApolloThemeBuilderReloadOverrides.
static CGFloat sPrimaryLum[2] = {0.85, 0.05}; // light, dark donor defaults

static uintptr_t sApolloStart = 0;
static uintptr_t sApolloEnd = 0;

static void FindApolloImage(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= 7 && strcmp(name + len - 7, "/Apollo") == 0) {
            sApolloStart = (uintptr_t)_dyld_get_image_header(i);
            sApolloEnd = sApolloStart + 0x8000000;
            return;
        }
    }
}

NSArray<NSString *> *ApolloThemeBuilderRoleKeys(void) {
    return @[kApolloThemeRoleAccent, kApolloThemeRolePrimaryBG,
             kApolloThemeRoleSecondaryBG, kApolloThemeRoleTertiaryBG,
             kApolloThemeRoleSeparator, kApolloThemeRoleBar,
             kApolloThemeRoleGray];
}

NSString *ApolloThemeBuilderRoleDisplayName(NSString *roleKey) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            kApolloThemeRoleAccent:      @"Accent",
            kApolloThemeRolePrimaryBG:   @"Background",
            kApolloThemeRoleSecondaryBG: @"Secondary Background",
            kApolloThemeRoleTertiaryBG:  @"Tertiary Background",
            kApolloThemeRoleSeparator:   @"Separators",
            kApolloThemeRoleBar:         @"Bars & Chrome",
            kApolloThemeRoleGray:        @"Neutral Gray",
        };
    });
    return names[roleKey] ?: roleKey;
}

NSString *ApolloThemeBuilderDonorHex(NSString *roleKey, NSString *mode) {
    const char *role = roleKey.UTF8String, *m = mode.UTF8String;
    for (int i = 0; i < KSLOTCOUNT; i++) {
        if (strcmp(kSlots[i].role, role) == 0 && strcmp(kSlots[i].mode, m) == 0) {
            return [NSString stringWithFormat:@"%02X%02X%02X", kSlots[i].r, kSlots[i].g, kSlots[i].b];
        }
    }
    return @"000000";
}

UIColor *ApolloThemeBuilderColorFromHex(NSString *hex) {
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:clean] scanHexInt:&v]) return nil;
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

NSString *ApolloThemeBuilderHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)lround(r * 255.0), (int)lround(g * 255.0), (int)lround(b * 255.0)];
}

NSString *ApolloThemeBuilderSavedHex(NSString *roleKey, NSString *mode) {
    NSDictionary *colors = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kApolloCustomThemeColorsKey];
    NSString *saved = colors[[NSString stringWithFormat:@"%@.%@", roleKey, mode]];
    return saved ?: ApolloThemeBuilderDonorHex(roleKey, mode);
}

void ApolloThemeBuilderSaveHex(NSString *roleKey, NSString *mode, NSString *hex) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *colors = [([ud dictionaryForKey:kApolloCustomThemeColorsKey] ?: @{}) mutableCopy];
    colors[[NSString stringWithFormat:@"%@.%@", roleKey, mode]] = hex;
    [ud setObject:colors forKey:kApolloCustomThemeColorsKey];
    ApolloThemeBuilderReloadOverrides();
}

BOOL ApolloThemeBuilderIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloCustomThemeEnabledKey];
}

static NSUserDefaults *GroupDefaults(void) {
    static NSUserDefaults *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        group = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite];
    });
    return group;
}

void ApolloThemeBuilderSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kApolloCustomThemeEnabledKey];
    if (enabled) {
        // Claim the donor slot in Apollo's own theme system. Takes effect on
        // next launch for views Apollo has already painted; the builder UI
        // also force-repaints, so it's live in practice.
        [GroupDefaults() setObject:kDonorThemeName forKey:kAppColorThemeKey];
    }
    ApolloThemeBuilderReloadOverrides();
}

void ApolloThemeBuilderReloadOverrides(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [ud boolForKey:kApolloCustomThemeEnabledKey];
    NSString *activeTheme = [GroupDefaults() stringForKey:kAppColorThemeKey];
    BOOL donorActive = [activeTheme isEqualToString:kDonorThemeName];
    NSDictionary *colors = [ud dictionaryForKey:kApolloCustomThemeColorsKey];

    os_unfair_lock_lock(&sLock);
    memset(sRByteFilter, 0, sizeof(sRByteFilter));
    for (int i = 0; i < KSLOTCOUNT; i++) {
        NSString *key = [NSString stringWithFormat:@"%s.%s", kSlots[i].role, kSlots[i].mode];
        NSString *hex = colors[key];
        unsigned int v = 0;
        BOOL valid = hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&v];
        if (valid) {
            sRepl[i][0] = ((v >> 16) & 0xFF) / 255.0;
            sRepl[i][1] = ((v >> 8) & 0xFF) / 255.0;
            sRepl[i][2] = (v & 0xFF) / 255.0;
            sSlotCustomized[i] = ((v >> 16) & 0xFF) != kSlots[i].r
                              || ((v >> 8) & 0xFF) != kSlots[i].g
                              || (v & 0xFF) != kSlots[i].b;
        } else {
            sSlotCustomized[i] = false;
        }
        if (sSlotCustomized[i]) sRByteFilter[kSlots[i].r] = 1;
    }

    // Effective primary-background luminance per mode (user color, else the
    // donor constant), used to derive legible auto-contrast text grays.
    const char *modeNames[2] = {"light", "dark"};
    const uint8_t donorPrimary[2][3] = {{0xCF, 0xD7, 0xE8}, {0x06, 0x16, 0x36}};
    for (int m = 0; m < 2; m++) {
        NSString *hex = colors[[NSString stringWithFormat:@"primaryBG.%s", modeNames[m]]];
        unsigned int v = 0;
        CGFloat rr, gg, bb;
        if (hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&v]) {
            rr = ((v >> 16) & 0xFF) / 255.0; gg = ((v >> 8) & 0xFF) / 255.0; bb = (v & 0xFF) / 255.0;
        } else {
            rr = donorPrimary[m][0] / 255.0; gg = donorPrimary[m][1] / 255.0; bb = donorPrimary[m][2] / 255.0;
        }
        sPrimaryLum[m] = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;
    }

    sRemapActive = enabled && donorActive;
    os_unfair_lock_unlock(&sLock);
    ApolloLog(@"ThemeBuilder: overrides reloaded (enabled=%d donorActive=%d theme=%@)",
              enabled, donorActive, activeTheme);
}

void ApolloThemeBuilderForceRepaint(void) {
    // Drive Apollo's own trait-change repaint cascade (the same path a system
    // light/dark switch takes) by flipping each window's override style for
    // one runloop turn. Theme role colors are re-created on repaint, which
    // re-runs them through the remap hooks.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        NSMutableArray<NSNumber *> *savedStyles = [NSMutableArray array];
        for (UIWindow *window in windows) {
            [savedStyles addObject:@(window.overrideUserInterfaceStyle)];
            UIUserInterfaceStyle effective = window.traitCollection.userInterfaceStyle;
            window.overrideUserInterfaceStyle = (effective == UIUserInterfaceStyleDark)
                ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [windows enumerateObjectsUsingBlock:^(UIWindow *window, NSUInteger idx, BOOL *stop) {
                window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)savedStyles[idx].integerValue;
            }];
        });
    });
}

// ---------------------------------------------------------------------------
// UIColor remap hooks
// ---------------------------------------------------------------------------

// Returns slot index for exact donor component match, or -1. Hot path: callers
// pre-check sRemapActive. Alpha is matched on RGB only and preserved by the
// caller, so role colors used at reduced opacity remap correctly too.
static inline int SlotForComponents(int ri, int gi, int bi, uintptr_t caller) {
    if (ri < 0 || ri > 255 || !sRByteFilter[ri]) return -1;
    for (int i = 0; i < KSLOTCOUNT; i++) {
        if (!sSlotCustomized[i]) continue;
        if (kSlots[i].r == ri && kSlots[i].g == gi && kSlots[i].b == bi) {
            // Only remap colors built by Apollo's own code (theme getters);
            // leaves system frameworks and tweak UI untouched.
            if (caller >= sApolloStart && caller < sApolloEnd) return i;
            return -1;
        }
    }
    return -1;
}

// If (ri,gi,bi) is a near-neutral gray (low saturation, not near black/white)
// created by Apollo, fills out[3] with an auto-contrast gray derived from the
// active mode's primary-background luminance and returns true. Preserves the
// gray's relative prominence so the text/icon hierarchy is kept.
static inline bool NeutralGrayReplacement(int ri, int gi, int bi, uintptr_t caller, CGFloat out[3]) {
    if (caller < sApolloStart || caller >= sApolloEnd) return false;
    // Neutral = all channels within a tight band (allow a hair of tint).
    int mx = ri > gi ? (ri > bi ? ri : bi) : (gi > bi ? gi : bi);
    int mn = ri < gi ? (ri < bi ? ri : bi) : (gi < bi ? gi : bi);
    if (mx - mn > 8) return false;
    // Gray level 0..1 (channels are ~equal; use the mean).
    CGFloat Lg = (ri + gi + bi) / (3.0 * 255.0);
    // Leave structural near-black / near-white (primary text, white-on-accent,
    // glyph fills) untouched.
    if (Lg < 0.10 || Lg > 0.92) return false;

    // Active appearance picks which background we contrast against. During a
    // theme repaint / cell layout the current trait reflects the render mode;
    // fall back to light if unspecified.
    UIUserInterfaceStyle style = UITraitCollection.currentTraitCollection.userInterfaceStyle;
    int mode = (style == UIUserInterfaceStyleDark) ? 1 : 0;
    CGFloat Lb = sPrimaryLum[mode];
    bool lightBg = Lb >= 0.5;

    // Prominence: how much contrast the gray "wanted" against Apollo's own
    // reference background (white in light, black in dark). Darker-on-white /
    // lighter-on-black = more prominent. Floor it so faint stays visible.
    CGFloat prominence = lightBg ? (1.0 - Lg) : Lg;
    if (prominence < 0.20) prominence = 0.20;
    if (prominence > 0.95) prominence = 0.95;
    // Place the new gray on the readable side of the background by an amount
    // proportional to that prominence.
    CGFloat delta = 0.30 + 0.55 * prominence;
    CGFloat target = lightBg ? (Lb - delta) : (Lb + delta);
    if (target < 0.05) target = 0.05;
    if (target > 0.97) target = 0.97;

    out[0] = out[1] = out[2] = target;
    return true;
}

// ---------------------------------------------------------------------------
// ThemeManager capture + live donor activation
// ---------------------------------------------------------------------------

// AppColorTheme enum raw values are linear in declaration order (verified at
// runtime against the group-defaults name on every switch): default=0 …
// outrun=5 … mint=17.
static const uint8_t kDonorThemeRawValue = 5; // outrun

static __weak NSObject *sThemeManager = nil;

void ApolloThemeBuilderActivateDonorLive(void) {
    NSObject *tm = sThemeManager;
    if (!tm) {
        ApolloLog(@"ThemeBuilder: ThemeManager not captured; donor activates on next launch");
        return;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
    if (!ivar) {
        ApolloLog(@"ThemeBuilder: appColorTheme ivar not found; donor activates on next launch");
        return;
    }
    *((uint8_t *)(__bridge void *)tm + ivar_getOffset(ivar)) = kDonorThemeRawValue;
    ApolloLog(@"ThemeBuilder: switched in-memory theme to donor (outrun)");
    ApolloThemeBuilderForceRepaint();
}

%group ThemeBuilderManagerHook

%hook _TtC6Apollo12ThemeManager

- (id)init {
    id result = %orig;
    sThemeManager = result;
    return result;
}

%end

%end // ThemeBuilderManagerHook

%group ThemeBuilderHooks

%hook UIColor

- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int ri = (int)lround(r * 255.0), gi = (int)lround(g * 255.0), bi = (int)lround(b * 255.0);
        int slot = SlotForComponents(ri, gi, bi, caller);
        if (slot >= 0) return %orig(sRepl[slot][0], sRepl[slot][1], sRepl[slot][2], a);
        CGFloat tg[3];
        if (NeutralGrayReplacement(ri, gi, bi, caller, tg)) return %orig(tg[0], tg[1], tg[2], a);
    }
    return %orig;
}

+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int ri = (int)lround(r * 255.0), gi = (int)lround(g * 255.0), bi = (int)lround(b * 255.0);
        int slot = SlotForComponents(ri, gi, bi, caller);
        if (slot >= 0) return %orig(sRepl[slot][0], sRepl[slot][1], sRepl[slot][2], a);
        CGFloat tg[3];
        if (NeutralGrayReplacement(ri, gi, bi, caller, tg)) return %orig(tg[0], tg[1], tg[2], a);
    }
    return %orig;
}

// Grays Apollo builds via colorWithWhite: are inherently neutral — route them
// through the same auto-contrast path (the white value is the gray level).
+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int wi = (int)lround(w * 255.0);
        CGFloat tg[3];
        if (NeutralGrayReplacement(wi, wi, wi, caller, tg)) return %orig(tg[0], a);
    }
    return %orig;
}

- (UIColor *)initWithWhite:(CGFloat)w alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int wi = (int)lround(w * 255.0);
        CGFloat tg[3];
        if (NeutralGrayReplacement(wi, wi, wi, caller, tg)) return %orig(tg[0], a);
    }
    return %orig;
}

%end

%hook NSUserDefaults

// Keep the enabled flag truthful: if the user picks a different theme in
// Apollo's own picker, the donor slot is gone, so the custom theme is off.
- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if ([key isEqualToString:kAppColorThemeKey] && [value isKindOfClass:[NSString class]]) {
        BOOL donor = [(NSString *)value isEqualToString:kDonorThemeName];
        if (!donor && ApolloThemeBuilderIsEnabled()) {
            ApolloLog(@"ThemeBuilder: theme changed to %@ — disabling custom theme", value);
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kApolloCustomThemeEnabledKey];
        }
        ApolloThemeBuilderReloadOverrides();
    }
}

%end

%end // ThemeBuilderHooks

%ctor {
    @autoreleasepool {
        FindApolloImage();
        %init(ThemeBuilderHooks);
        if (objc_getClass("_TtC6Apollo12ThemeManager")) {
            %init(ThemeBuilderManagerHook);
        }
        ApolloThemeBuilderReloadOverrides();
    }
}

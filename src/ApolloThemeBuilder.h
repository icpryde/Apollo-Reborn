#import <UIKit/UIKit.h>

// Theme Builder — custom user theme on top of Apollo's AppColorTheme system.
//
// Apollo's theme colors are hardcoded Swift switch statements (one constant per
// theme per role), so they can't be edited directly. Instead the builder
// hijacks the "outrun" theme slot: when enabled we select outrun in Apollo's
// own theme system and remap outrun's RGB constants (unique in both light and
// dark mode) to the user's colors at UIColor-creation time, restricted to
// call sites inside the Apollo binary. See docs/theme-builder-RE.md for the
// runtime-derived constant tables.

__BEGIN_DECLS

// Group-defaults keys (live in group.com.christianselig.apollo so they ride
// along with Backup/Restore Settings for free).
extern NSString * const kApolloCustomThemeEnabledKey;   // BOOL
extern NSString * const kApolloCustomThemeColorsKey;    // {roleKey: "RRGGBB"}

// Role keys. Each role has a light and a dark variant ("<role>.light" /
// "<role>.dark" in the colors dict).
extern NSString * const kApolloThemeRoleAccent;        // tint: buttons, links, selection
extern NSString * const kApolloThemeRolePrimaryBG;     // posts/cells background
extern NSString * const kApolloThemeRoleSecondaryBG;   // grouped/secondary background
extern NSString * const kApolloThemeRoleTertiaryBG;    // dimmed/tertiary background
extern NSString * const kApolloThemeRoleSeparator;     // separators / elevated chrome
extern NSString * const kApolloThemeRoleBar;           // nav/tab bar background
extern NSString * const kApolloThemeRoleGray;          // neutral gray (placeholders etc.)

// All role keys in display order.
NSArray<NSString *> *ApolloThemeBuilderRoleKeys(void);
// Human-readable name for a role key.
NSString *ApolloThemeBuilderRoleDisplayName(NSString *roleKey);
// Donor (outrun) default hex for role+mode ("light"/"dark") — also the values
// the remap engine matches against.
NSString *ApolloThemeBuilderDonorHex(NSString *roleKey, NSString *mode);

// Currently saved hex for role+mode (falls back to donor default).
NSString *ApolloThemeBuilderSavedHex(NSString *roleKey, NSString *mode);
void ApolloThemeBuilderSaveHex(NSString *roleKey, NSString *mode, NSString *hex);

BOOL ApolloThemeBuilderIsEnabled(void);
void ApolloThemeBuilderSetEnabled(BOOL enabled);

// Re-resolve the remap table from defaults (call after edits).
void ApolloThemeBuilderReloadOverrides(void);

// Switch Apollo's in-memory theme to the donor slot (outrun) and repaint, so
// enabling the custom theme takes effect without an app relaunch.
void ApolloThemeBuilderActivateDonorLive(void);

// Force Apollo to repaint all theme colors (flips each window's
// overrideUserInterfaceStyle for one runloop turn, which drives Apollo's own
// trait-change repaint cascade).
void ApolloThemeBuilderForceRepaint(void);

UIColor *ApolloThemeBuilderColorFromHex(NSString *hex);
NSString *ApolloThemeBuilderHexFromColor(UIColor *color);

__END_DECLS

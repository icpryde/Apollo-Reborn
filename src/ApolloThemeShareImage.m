#import "ApolloThemeShareImage.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloCommon.h"
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#import <math.h>

// QR payload wrapper. The blob is base64'd (pure ASCII) so it rides the QR's
// byte mode cleanly and both decoders return it reliably as a string, with no
// binary-payloadData ambiguity. The tag lets us reject a non-Apollo QR (a random
// URL, a Wi-Fi code, …) before we even base64-decode. The tag deliberately stays
// "/1/" across blob versions — old builds strip it, then cleanly reject the
// unknown version byte inside.
static NSString *const kThemeQRTag = @"ApolloTheme/1/";

// ---------------------------------------------------------------------------
// Compact binary codec (for QR-in-image sharing). See header for the layout.
// ---------------------------------------------------------------------------

static const uint8_t kThemeBinaryMagic     = 0xA7;
static const uint8_t kThemeBinaryVersionV1 = 0x01; // legacy Theme Builder role.mode layout
static const uint8_t kThemeBinaryVersionV2 = 0x02; // v2 input keys + variant + flags

// v2 blob layout (all multi-byte values big-endian):
//   [0]    magic 0xA7
//   [1]    version 0x02
//   [2..3] uint16 presence bitmask; bit = inputKeyIndex*2 + (dark ? 1 : 0),
//          key order = ApolloThemeInputKeys() (accent, background, card,
//          raised, bars, text, mutedText, separator)
//   [4..]  3 RGB bytes per present slot, ascending slot order
//   [+0]   variant byte (ApolloThemeVariant raw value)
//   [+1]   flags byte (bit0 = advancedEnabled)
//   [+2]   name length (UTF-8 bytes, 0–120)
//   [..]   name UTF-8 bytes
//   [-2..] CRC-16/CCITT-FALSE over all preceding bytes
//
// The v1 blob differs: no variant/flags bytes, and the 8 colour slots are the
// legacy Theme Builder roles in THEIR fixed order (see V1QRRoleKeys below) —
// slot tables between versions are NOT interchangeable.

// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). Guards against a silent QR
// error-correction mis-decode producing a plausible-but-wrong blob.
static uint16_t ATSCRC16(const uint8_t *data, NSUInteger len) {
    uint16_t crc = 0xFFFF;
    for (NSUInteger i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

// Max UTF-8 bytes for the name in a binary blob: comfortably inside the 1-byte
// length field and the QR's capacity. Names long enough to hit this are
// pathological (long combining/Zalgo/ZWJ runs); a normal name is far smaller.
static const NSUInteger kThemeBinaryNameMaxBytes = 120;

// Encode a name to UTF-8, truncated to kThemeBinaryNameMaxBytes on a composed-
// character (grapheme) boundary so it never splits a code point and always fits
// the 1-byte length field. A name already under budget is returned whole.
static NSData *ATSNameBytesForBinary(NSString *name) {
    NSData *full = [name dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if (full.length <= kThemeBinaryNameMaxBytes) return full;
    NSMutableData *out = [NSMutableData data];
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *seq, NSRange r, NSRange er, BOOL *stop) {
        NSData *bytes = [seq dataUsingEncoding:NSUTF8StringEncoding];
        if (out.length + bytes.length > kThemeBinaryNameMaxBytes) { *stop = YES; return; }
        [out appendData:bytes];
    }];
    return out;
}

// Encode the PORTABLE export dict ({name, variant, input, advancedEnabled} as
// produced by -[ApolloThemeStore exportDataForTheme:]) into a v2 blob. Going
// through the Store's exporter first means the blob carries exactly what the
// .json file would — same normalisation, same advanced-override stripping when
// the flag is off (so a recipient never resurrects overrides the sender wasn't
// even seeing).
static NSData *ATSEncodeBinaryV2(NSDictionary *portable) {
    if (![portable isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *input = [portable[@"input"] isKindOfClass:[NSDictionary class]] ? portable[@"input"] : @{};
    NSArray<NSString *> *keys = ApolloThemeInputKeys();

    NSMutableData *out = [NSMutableData data];
    uint8_t header[2] = { kThemeBinaryMagic, kThemeBinaryVersionV2 };
    [out appendBytes:header length:2];

    // Presence bitmask + RGB bytes in fixed slot order: slot = keyIndex*2 + (dark?1:0).
    uint16_t mask = 0;
    NSMutableData *colorBytes = [NSMutableData data];
    for (NSUInteger ki = 0; ki < keys.count && ki < 8; ki++) {
        for (NSUInteger mi = 0; mi < 2; mi++) {
            NSDictionary *modeInput = [input[mi ? @"dark" : @"light"] isKindOfClass:[NSDictionary class]]
                ? input[mi ? @"dark" : @"light"] : @{};
            uint32_t rgb = 0;
            id hex = modeInput[keys[ki]];
            if (![hex isKindOfClass:[NSString class]] || !ApolloThemeParseHex(hex, &rgb)) continue;
            mask |= (uint16_t)(1u << (ki * 2 + mi));
            uint8_t bytes[3] = { (uint8_t)((rgb >> 16) & 0xFF), (uint8_t)((rgb >> 8) & 0xFF), (uint8_t)(rgb & 0xFF) };
            [colorBytes appendBytes:bytes length:3];
        }
    }
    uint8_t maskBytes[2] = { (uint8_t)(mask >> 8), (uint8_t)(mask & 0xFF) };
    [out appendBytes:maskBytes length:2];
    [out appendData:colorBytes];

    uint8_t variant = (uint8_t)ApolloThemeVariantFromKey(portable[@"variant"]);
    uint8_t flags = [portable[kApolloThemeAdvancedOptionsEnabledKey] boolValue] ? 0x01 : 0x00;
    [out appendBytes:&variant length:1];
    [out appendBytes:&flags length:1];

    // Name, truncated to a UTF-8 BYTE budget (the Store clamp is by *character*
    // count, not bytes — a single long combining/ZWJ cluster can blow past the
    // 1-byte length field, so budget by bytes here on a grapheme boundary).
    NSString *name = [portable[@"name"] isKindOfClass:[NSString class]] ? portable[@"name"] : @"Custom";
    NSData *nameUTF8 = ATSNameBytesForBinary(name);
    uint8_t nlen = (uint8_t)nameUTF8.length; // guaranteed ≤ kThemeBinaryNameMaxBytes ≤ 255
    [out appendBytes:&nlen length:1];
    [out appendData:nameUTF8];

    uint16_t crc = ATSCRC16((const uint8_t *)out.bytes, out.length);
    uint8_t crcBytes[2] = { (uint8_t)(crc >> 8), (uint8_t)(crc & 0xFF) };
    [out appendBytes:crcBytes length:2];
    return out;
}

// The legacy (v1 blob) role slot order — the original Theme Builder's
// ApolloThemeBuilderRoleKeys() order, frozen here so old cards keep decoding
// after that code was replaced by Theme Manager v2. Do NOT reorder.
static NSArray<NSString *> *V1QRRoleKeys(void) {
    return @[ @"accent", @"primaryBG", @"secondaryBG", @"tertiaryBG",
              @"separator", @"bar", @"gray", @"text" ];
}

// Decode a blob (either version) into the JSON-shaped dict the Store's import
// parser accepts: v2 → {schemaVersion, name, variant, input, advancedEnabled},
// v1 → {name, colors} (the parser routes "colors" through its own v1→v2
// migration mapping). Returns nil on any structural/CRC failure.
static NSDictionary *ATSDecodeBinary(NSData *blob) {
    if (![blob isKindOfClass:[NSData class]]) return nil;
    const uint8_t *p = (const uint8_t *)blob.bytes;
    NSUInteger n = blob.length;
    // v1 minimum: magic(1) version(1) mask(2) namelen(1) crc(2); v2 adds variant+flags.
    if (n < 7) return nil;
    if (p[0] != kThemeBinaryMagic) return nil;
    uint8_t version = p[1];
    if (version != kThemeBinaryVersionV1 && version != kThemeBinaryVersionV2) return nil;
    if (version == kThemeBinaryVersionV2 && n < 9) return nil;
    uint16_t want = (uint16_t)((uint16_t)p[n - 2] << 8 | p[n - 1]);
    if (ATSCRC16(p, n - 2) != want) return nil;

    NSUInteger dataEnd = n - 2; // payload bytes precede the 2-byte CRC
    uint16_t mask = (uint16_t)((uint16_t)p[2] << 8 | p[3]);
    NSUInteger idx = 4;

    // Colour slots. Both versions pack 16 slots as index*2 + (dark?1:0); only
    // the key tables differ.
    NSMutableDictionary *lightIn = [NSMutableDictionary dictionary]; // v2
    NSMutableDictionary *darkIn = [NSMutableDictionary dictionary];  // v2
    NSMutableDictionary *v1Colors = [NSMutableDictionary dictionary];
    NSArray<NSString *> *keys = (version == kThemeBinaryVersionV2) ? ApolloThemeInputKeys() : V1QRRoleKeys();
    for (NSUInteger slot = 0; slot < 16; slot++) {
        if (!(mask & (uint16_t)(1u << slot))) continue;
        if (idx + 3 > dataEnd) return nil;
        NSString *hex = [NSString stringWithFormat:@"%02X%02X%02X", p[idx], p[idx + 1], p[idx + 2]];
        idx += 3;
        NSUInteger ki = slot / 2;
        BOOL dark = (slot % 2) == 1;
        if (ki >= keys.count) continue; // unknown future slot — consume and ignore
        if (version == kThemeBinaryVersionV2) {
            (dark ? darkIn : lightIn)[keys[ki]] = hex;
        } else {
            v1Colors[[NSString stringWithFormat:@"%@.%@", keys[ki], dark ? @"dark" : @"light"]] = hex;
        }
    }

    uint8_t variant = 0, flags = 0;
    if (version == kThemeBinaryVersionV2) {
        if (idx + 2 > dataEnd) return nil;
        variant = p[idx++];
        flags = p[idx++];
    }

    if (idx + 1 > dataEnd) return nil;
    uint8_t nlen = p[idx++];
    if (idx + nlen > dataEnd) return nil;
    NSString *name = nlen ? [[NSString alloc] initWithBytes:p + idx length:nlen encoding:NSUTF8StringEncoding] : nil;
    if (!name.length) name = @"Imported Theme";

    if (version == kThemeBinaryVersionV1) {
        return @{ @"name": name, @"colors": v1Colors };
    }
    return @{ @"schemaVersion": @(kApolloThemeSchemaVersion),
              @"name": name,
              @"variant": ApolloThemeVariantKey((ApolloThemeVariant)MIN(variant, (uint8_t)ApolloThemeVariantBold)),
              @"input": @{ @"light": lightIn, @"dark": darkIn },
              kApolloThemeAdvancedOptionsEnabledKey: @((flags & 0x01) != 0) };
}

// Run a decoded blob dict through the Store's strict import parser so the QR
// route inherits every guard the JSON file route has (hex whitelisting, starter
// fill, name clamp, advanced inference), then stamp QR provenance.
static NSDictionary *ATSParsedImportFromBlobDict(NSDictionary *blobDict, BOOL legacy) {
    if (!blobDict) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:blobDict options:0 error:NULL];
    if (!json) return nil;
    NSString *err = nil;
    NSDictionary *parsed = [[ApolloThemeStore shared] parseImportData:json error:&err];
    if (!parsed) {
        ApolloLog(@"ThemeShare: store parser rejected QR payload: %@", err);
        return nil;
    }
    NSMutableDictionary *stamped = [parsed mutableCopy];
    stamped[@"generation"] = @{ @"source": legacy ? @"imported-qr-v1" : @"imported-qr" };
    return stamped;
}

#pragma mark - QR generation

// Generate a crisp QR UIImage (black on white) for a payload string, integer-
// upscaled to roughly targetPx so module edges stay razor-sharp before any later
// JPEG recompression touches them.
static UIImage *ATSMakeQRImage(NSString *payload, CGFloat targetPx) {
    // payload is the ASCII tag + base64, so UTF-8 encodes it exactly (1 byte/char).
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    if (!filter) return nil;
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"]; // ~30% recovery — the JPEG-survival margin
    CIImage *ci = filter.outputImage;
    CGFloat span = ci.extent.size.width;
    if (span <= 0) return nil;
    CGFloat scale = floor(targetPx / span);
    if (scale < 1) scale = 1;
    CIImage *scaled = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [ctx createCGImage:scaled fromRect:scaled.extent];
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

#pragma mark - Card rendering

static void ATSDrawText(NSString *s, CGRect rect, UIFont *font, UIColor *color,
                        NSTextAlignment align, NSLineBreakMode lbm) {
    if (!s.length) return;
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
    p.alignment = align;
    p.lineBreakMode = lbm;
    [s drawInRect:rect withAttributes:@{ NSFontAttributeName: font,
                                         NSForegroundColorAttributeName: color,
                                         NSParagraphStyleAttributeName: p }];
}

// A rounded "pill" filled with bg, with vertically-centered text. Fills the
// rounded path directly — never clip here, since clipping only shrinks the
// context's clip region and would hide everything drawn after the pill.
static void ATSDrawPill(CGRect rect, UIColor *bg, NSString *text, UIColor *textColor, UIFont *font) {
    [bg setFill];
    [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:rect.size.height / 2.0] fill];
    CGFloat lh = font.lineHeight;
    CGRect tr = CGRectMake(rect.origin.x, rect.origin.y + (rect.size.height - lh) / 2.0, rect.size.width, lh);
    ATSDrawText(text, tr, font, textColor, NSTextAlignmentCenter, NSLineBreakByClipping);
}

// Render the share card: a mock Apollo post painted in the theme's compiled
// token colours (mirroring the editor's Preview section) with the theme name as
// the post title, a Dark/Light-mode badge, the palette, and the QR. The QR
// payload always carries BOTH modes; only the mock post/palette reflect `mode`.
UIImage *ApolloThemeShareRenderCard(NSDictionary *theme, ApolloThemeMode mode) {
    if (![theme isKindOfClass:[NSDictionary class]]) return nil;
    BOOL dark = (mode == ApolloThemeModeDark);
    NSString *modeKey = ApolloThemeModeKey(dark ? ApolloThemeModeDark : ApolloThemeModeLight);

    const CGFloat W = 1024.0;   // portrait card: more room for the post + a big, scannable QR
    const CGFloat H = 1280.0;

    NSString *name = ([theme[@"name"] isKindOfClass:[NSString class]] && [theme[@"name"] length])
        ? theme[@"name"] : @"Custom Theme";

    // QR payload from the Store's portable export (same normalisation +
    // advanced-stripping as the .json file). If anything fails we still draw
    // the card, just without a QR.
    NSDictionary *portable = nil;
    NSData *exportJSON = [[ApolloThemeStore shared] exportDataForTheme:theme];
    if (exportJSON) {
        id obj = [NSJSONSerialization JSONObjectWithData:exportJSON options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) portable = obj;
    }
    NSData *blob = portable ? ATSEncodeBinaryV2(portable) : nil;
    NSString *payload = blob.length ? [kThemeQRTag stringByAppendingString:[blob base64EncodedStringWithOptions:0]] : nil;
    UIImage *qr = payload ? ATSMakeQRImage(payload, 380.0) : nil;
    if (!qr) ApolloLog(@"ThemeShare: rendering card without QR (encode failed)");

    // Compiled token colours for the previewed mode (same source as the editor
    // preview — never nil, tolerates sparse input).
    ApolloCompiledTheme *compiled =
        [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                            variant:ApolloThemeVariantFromKey(theme[@"variant"])
                                    advancedEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
    ApolloThemeMode m = dark ? ApolloThemeModeDark : ApolloThemeModeLight;
    UIColor *(^tok)(ApolloThemeToken) = ^UIColor *(ApolloThemeToken t) {
        return ApolloThemeUIColorFromRGB([compiled rgbForToken:t mode:m]);
    };
    UIColor *page        = tok(ApolloThemeTokenBackground);
    UIColor *card        = tok(ApolloThemeTokenSecondaryBackground);
    UIColor *accent      = tok(ApolloThemeTokenAccent);
    UIColor *separator   = tok(ApolloThemeTokenSeparator);
    UIColor *raised      = tok(ApolloThemeTokenTertiaryBackground); // the "Raised" input surface
    UIColor *gray        = tok(ApolloThemeTokenSecondaryLabel);
    UIColor *primaryText = tok(ApolloThemeTokenLabel);
    UIColor *accentText  = tok(ApolloThemeTokenAccentText);
    UIColor *muted       = tok(ApolloThemeTokenTertiaryLabel); // label faded toward the page

    // Palette swatches: the user's actual input colours for this mode — the 5
    // required surfaces plus any advanced overrides that are on and set.
    NSDictionary *modeInput = [theme[@"input"][modeKey] isKindOfClass:[NSDictionary class]]
        ? theme[@"input"][modeKey] : @{};
    BOOL advancedEnabled = [theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue];
    NSMutableArray<UIColor *> *swatches = [NSMutableArray array];
    for (NSString *key in ApolloThemeDefaultInputKeys()) {
        uint32_t rgb = 0;
        id hex = modeInput[key];
        BOOL ok = [hex isKindOfClass:[NSString class]] && ApolloThemeParseHex(hex, &rgb);
        [swatches addObject:ok ? ApolloThemeUIColorFromRGB(rgb) : UIColor.grayColor];
    }
    if (advancedEnabled) {
        for (NSString *key in ApolloThemeAdvancedInputKeys()) {
            uint32_t rgb = 0;
            id hex = modeInput[key];
            if ([hex isKindOfClass:[NSString class]] && ApolloThemeParseHex(hex, &rgb)) {
                [swatches addObject:ApolloThemeUIColorFromRGB(rgb)];
            }
        }
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = YES;
    format.scale = 1.0; // 1024 logical == 1024 px, so QR module pixels are predictable
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(W, H) format:format];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef ctx = rc.CGContext;

        // --- page background (the theme's page colour) ---
        [page setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

        // --- header: accent-dot wordmark + Dark/Light-mode badge ---
        [accent setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(52, 46, 26, 26));
        ATSDrawText(@"Apollo theme", CGRectMake(90, 44, 360, 34),
                    [UIFont systemFontOfSize:27 weight:UIFontWeightSemibold], muted,
                    NSTextAlignmentLeft, NSLineBreakByClipping);

        NSString *badge = dark ? @"\U0001F319  Dark mode" : @"☀️  Light mode";
        UIFont *badgeFont = [UIFont systemFontOfSize:23 weight:UIFontWeightSemibold];
        CGFloat badgeW = [badge sizeWithAttributes:@{NSFontAttributeName: badgeFont}].width + 44;
        ATSDrawPill(CGRectMake(W - 52 - badgeW, 36, badgeW, 50), raised, badge, primaryText, badgeFont);

        // --- mock Apollo post card painted in the theme's colours ---
        CGFloat cx = 48, cy = 116, cw = W - 96, ch = 452, in = 36;
        UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(cx, cy, cw, ch) cornerRadius:26];
        [card setFill]; [cardPath fill];
        [separator setStroke]; cardPath.lineWidth = 1.5; [cardPath stroke];

        // subreddit row: accent avatar + r/apolloapp + byline
        [accent setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(cx + in, cy + 34, 72, 72));
        ATSDrawText(@"r/apolloapp", CGRectMake(cx + in + 92, cy + 38, cw - in * 2 - 92, 34),
                    [UIFont systemFontOfSize:29 weight:UIFontWeightBold], accent,
                    NSTextAlignmentLeft, NSLineBreakByTruncatingTail);
        ATSDrawText(@"u/christianselig · 2h", CGRectMake(cx + in + 92, cy + 76, cw - in * 2 - 92, 28),
                    [UIFont systemFontOfSize:22 weight:UIFontWeightRegular], gray,
                    NSTextAlignmentLeft, NSLineBreakByTruncatingTail);

        // title = the theme name (wraps up to 2 lines), then a subtitle
        ATSDrawText(name, CGRectMake(cx + in, cy + 144, cw - in * 2, 112),
                    [UIFont systemFontOfSize:46 weight:UIFontWeightBold], primaryText,
                    NSTextAlignmentLeft, NSLineBreakByWordWrapping);
        ATSDrawText(@"A custom Apollo theme", CGRectMake(cx + in, cy + 262, cw - in * 2, 30),
                    [UIFont systemFontOfSize:24 weight:UIFontWeightRegular], gray,
                    NSTextAlignmentLeft, NSLineBreakByTruncatingTail);

        // separator + vote/comment pills
        [separator setFill];
        CGContextFillRect(ctx, CGRectMake(cx + in, cy + 318, cw - in * 2, 2));
        ATSDrawPill(CGRectMake(cx + in, cy + 348, 162, 58), accent, @"▲ 1.2k",
                    accentText, [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]);
        ATSDrawPill(CGRectMake(cx + in + 182, cy + 348, 146, 58), raised, @"\U0001F4AC 42",
                    primaryText, [UIFont systemFontOfSize:24 weight:UIFontWeightMedium]);

        // --- palette: the user's chosen input colours for this mode ---
        ATSDrawText(@"PALETTE", CGRectMake(52, 612, 300, 24),
                    [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold], muted,
                    NSTextAlignmentLeft, NSLineBreakByClipping);
        NSUInteger count = MAX(swatches.count, (NSUInteger)1);
        CGFloat sgap = 8, sx = 48, sy = 644, sh = 46;
        CGFloat sw = (cw - sgap * (count - 1)) / (CGFloat)count;
        for (NSUInteger i = 0; i < swatches.count; i++) {
            CGRect r = CGRectMake(sx + i * (sw + sgap), sy, sw, sh);
            UIBezierPath *sp = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:9];
            [swatches[i] setFill]; [sp fill];
            [[separator colorWithAlphaComponent:0.7] setStroke]; sp.lineWidth = 1; [sp stroke];
        }

        // --- QR plate (always light, for QR contrast) ---
        CGFloat plateTop = 752;
        [[UIColor colorWithRed:0.965 green:0.969 blue:0.984 alpha:1.0] setFill];
        CGContextFillRect(ctx, CGRectMake(0, plateTop, W, H - plateTop));
        [[UIColor colorWithWhite:0.0 alpha:0.10] setFill]; // hairline divider
        CGContextFillRect(ctx, CGRectMake(0, plateTop, W, 1));

        if (qr) {
            CGFloat qz = qr.size.width;
            CGRect qrRect = CGRectMake(64, plateTop + (H - plateTop - qz) / 2.0, qz, qz);
            // white quiet-zone card behind the QR
            [[UIColor whiteColor] setFill];
            UIRectFill(CGRectInset(qrRect, -18, -18));
            CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
            [qr drawInRect:qrRect];

            CGFloat tx = CGRectGetMaxX(qrRect) + 36, ty = qrRect.origin.y;
            ATSDrawText(@"Get this theme", CGRectMake(tx, ty + 96, W - tx - 48, 36),
                        [UIFont systemFontOfSize:30 weight:UIFontWeightBold],
                        [UIColor colorWithWhite:0.07 alpha:1.0], NSTextAlignmentLeft, NSLineBreakByTruncatingTail);
            ATSDrawText(@"Save this image, then open Apollo → Theme Manager → Import. It carries both light & dark.",
                        CGRectMake(tx, ty + 142, W - tx - 48, 160),
                        [UIFont systemFontOfSize:23 weight:UIFontWeightRegular],
                        [UIColor colorWithWhite:0.36 alpha:1.0], NSTextAlignmentLeft, NSLineBreakByWordWrapping);
        }
    }];
}

#pragma mark - QR decoding

// An image can carry several QRs (a screenshot of a Reddit page with a promo
// QR next to the theme card, two cards side by side, …) and detectors return
// them in no documented order — so always prefer an Apollo-tagged payload over
// whichever code happened to come first, falling back to the first payload
// only so the caller can log/reject something concrete.
static NSString *ATSPreferTagged(NSString *best, NSString *candidate) {
    if (!candidate.length) return best;
    if ([candidate hasPrefix:kThemeQRTag]) return candidate;
    return best.length ? best : candidate;
}

// Vision path — more tolerant of the blur/resample a recompressed image picks up.
static NSString *ATSReadQRVision(CIImage *ci) {
    NSString *best = nil;
    if (@available(iOS 11.0, *)) {
        VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
        request.symbologies = @[VNBarcodeSymbologyQR];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ci options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error] || error) {
            ApolloLog(@"ThemeShare: Vision QR request failed: %@", error);
            return nil;
        }
        for (VNBarcodeObservation *obs in request.results) {
            best = ATSPreferTagged(best, obs.payloadStringValue);
            if ([best hasPrefix:kThemeQRTag]) break;
        }
    }
    return best;
}

// CIDetector fallback — no extra framework, handles clean/axis-aligned codes
// well (and is the load-bearing path in the Simulator, where Vision's QR
// detection fails).
static NSString *ATSReadQRCIDetector(CIImage *ci) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
                                              context:ctx
                                              options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    NSString *best = nil;
    for (CIFeature *feature in [detector featuresInImage:ci]) {
        if ([feature isKindOfClass:[CIQRCodeFeature class]]) {
            best = ATSPreferTagged(best, ((CIQRCodeFeature *)feature).messageString);
            if ([best hasPrefix:kThemeQRTag]) break;
        }
    }
    return best;
}

NSDictionary *ApolloThemeShareDecodePayload(NSString *payload) {
    if (![payload isKindOfClass:[NSString class]] || ![payload hasPrefix:kThemeQRTag]) {
        return nil; // not an Apollo theme QR (a URL, Wi-Fi code, other app's QR, …)
    }
    NSString *b64 = [payload substringFromIndex:kThemeQRTag.length];
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:b64
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    // A real theme blob is well under ~250 bytes; cap defensively so a hostile QR
    // can't hand us an oversized payload before decoding (mirrors the JSON import's
    // size guard — the QR route is otherwise the only one without one).
    static const NSUInteger kThemeQRMaxBlobBytes = 2048;
    if (!blob.length || blob.length > kThemeQRMaxBlobBytes) {
        ApolloLog(@"ThemeShare: QR payload rejected (len=%lu)", (unsigned long)blob.length);
        return nil;
    }
    BOOL legacy = blob.length >= 2 && ((const uint8_t *)blob.bytes)[1] == kThemeBinaryVersionV1;
    NSDictionary *blobDict = ATSDecodeBinary(blob);
    if (!blobDict) {
        ApolloLog(@"ThemeShare: binary decode/validation rejected the payload");
        return nil;
    }
    return ATSParsedImportFromBlobDict(blobDict, legacy);
}

NSDictionary *ApolloThemeShareDecodeImage(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) return nil;

    CIImage *ci = image.CIImage;
    if (!ci && image.CGImage) ci = [CIImage imageWithCGImage:image.CGImage];
    if (!ci) {
        ApolloLog(@"ThemeShare: could not obtain CIImage from picked image");
        return nil;
    }

    // Vision first for recompressed-image robustness; but if the best it found
    // is a non-Apollo QR, still give CIDetector a chance to surface the tagged
    // one before giving up (an untagged result is a guaranteed reject anyway).
    NSString *payload = ATSReadQRVision(ci);
    if (![payload hasPrefix:kThemeQRTag]) {
        NSString *alt = ATSReadQRCIDetector(ci);
        if ([alt hasPrefix:kThemeQRTag] || !payload.length) payload = alt;
    }
    if (!payload.length) {
        ApolloLog(@"ThemeShare: no QR found in image");
        return nil;
    }
    return ApolloThemeShareDecodePayload(payload);
}

//
// RebornDateStyle.swift
//
// This file was automatically generated and should not be edited.
//

#if canImport(Intents)

import Intents

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc public enum RebornDateStyle: Int {
    case `rounded` = 1
    case `serif` = 2
    case `mono` = 3
    case `condensed` = 4
    case `stamp` = 5
}

@available(iOS 13.0, macOS 11.0, watchOS 6.0, *) @available(tvOS, unavailable)
@objc(RebornDateStyleResolutionResult)
public class RebornDateStyleResolutionResult: INEnumResolutionResult {

    // This resolution result is for when the app extension wants to tell Siri to proceed, with a given RebornDateStyle. The resolvedValue can be different than the original RebornDateStyle. This allows app extensions to apply business logic constraints.
    // Use notRequired() to continue with a 'nil' value.
    @objc(successWithResolvedRebornDateStyle:)
    public class func success(with resolvedValue: RebornDateStyle) -> Self {
        return __success(withResolvedValue: resolvedValue.rawValue)
    }

    // This resolution result is to ask Siri to confirm if this is the value with which the user wants to continue.
    @objc(confirmationRequiredWithRebornDateStyleToConfirm:)
    public class func confirmationRequired(with valueToConfirm: RebornDateStyle) -> Self {
        return __confirmationRequiredWithValue(toConfirm: valueToConfirm.rawValue)
    }
}

#endif

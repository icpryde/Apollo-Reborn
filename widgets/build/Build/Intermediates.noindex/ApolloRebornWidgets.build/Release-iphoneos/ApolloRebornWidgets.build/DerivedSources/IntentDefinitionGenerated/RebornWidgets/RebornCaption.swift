//
// RebornCaption.swift
//
// This file was automatically generated and should not be edited.
//

#if canImport(Intents)

import Intents

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc public enum RebornCaption: Int {
    case `hidden` = 1
    case `title` = 2
    case `standard` = 3
    case `detailed` = 4
}

@available(iOS 13.0, macOS 11.0, watchOS 6.0, *) @available(tvOS, unavailable)
@objc(RebornCaptionResolutionResult)
public class RebornCaptionResolutionResult: INEnumResolutionResult {

    // This resolution result is for when the app extension wants to tell Siri to proceed, with a given RebornCaption. The resolvedValue can be different than the original RebornCaption. This allows app extensions to apply business logic constraints.
    // Use notRequired() to continue with a 'nil' value.
    @objc(successWithResolvedRebornCaption:)
    public class func success(with resolvedValue: RebornCaption) -> Self {
        return __success(withResolvedValue: resolvedValue.rawValue)
    }

    // This resolution result is to ask Siri to confirm if this is the value with which the user wants to continue.
    @objc(confirmationRequiredWithRebornCaptionToConfirm:)
    public class func confirmationRequired(with valueToConfirm: RebornCaption) -> Self {
        return __confirmationRequiredWithValue(toConfirm: valueToConfirm.rawValue)
    }
}

#endif

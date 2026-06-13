#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "ApolloAvatar" asset catalog image resource.
static NSString * const ACImageNameApolloAvatar AC_SWIFT_PRIVATE = @"ApolloAvatar";

#undef AC_SWIFT_PRIVATE

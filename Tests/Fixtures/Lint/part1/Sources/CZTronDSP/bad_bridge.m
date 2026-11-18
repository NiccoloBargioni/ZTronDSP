#import <UIKit/UIKit.h>                        // !! UB-1
#include "UIKit/UIView.h"                      // !! UB-1
@import AppKit;                                // !! UB-1
#import <AVFAudio/AVFAudio.h>
static UIView *shared;                         // !! UB-2
UIKIT_EXTERN NSString *const shared_name;      // !! UB-2
static const uint32_t none = UINT32_MAX;       // a limit of <stdint.h>, not a UIKit name

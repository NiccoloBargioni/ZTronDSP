#import <Metal/Metal.h>

// [device newLibraryWithSource:source options:nil error:NULL] in a comment is not a call.
id<MTLLibrary> ztd_runtime_library(id<MTLDevice> device, NSString *source) {
    return [device newLibraryWithSource:source options:nil error:NULL];       // !! DEP-4
}

id<MTLLibrary> ztd_bundled_library(id<MTLDevice> device, NSBundle *bundle) {
    return [device newDefaultLibraryWithBundle:bundle error:NULL];
}

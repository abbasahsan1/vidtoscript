//
//  VidToScript-Bridging-Header.h
//  VidToScript
//
//  Use this file to import the target's public headers that you would like to expose to Swift.
//
//  Exposes the on-device whisper.cpp C API (compiled as a static xcframework) to Swift.
//  whisper.h is C-compatible (WHISPER_API resolves to plain linkage in non-C++ mode),
//  so it can be imported directly by the Objective-C bridging header.
//

#ifndef VidToScript_Bridging_Header_h
#define VidToScript_Bridging_Header_h

#import "whisper.h"

#endif /* VidToScript_Bridging_Header_h */

//  SpektraProbe-Bridging-Header.h — the engine's C ABI, visible to Swift.
//
//  The same header the Mac app bridges (`modern_UI/.../Spektrafilm-Bridging-Header.h`):
//  the probe links `engine/build/ios/libspektrafilm_engine.a`, built by
//  `engine/build-ios.sh`, and reaches it through this surface and nothing else.
#import "spektrafilm/spk_engine.h"

// metal-cpp is header-only, but the implementation of its wrapper functions must
// be emitted in exactly ONE translation unit by defining these macros before the
// includes. This is that translation unit. Do not define these anywhere else.
#define NS_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <QuartzCore/QuartzCore.hpp>

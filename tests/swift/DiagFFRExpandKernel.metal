// macOS compute kernel for tests/swift/DiagFFRExpandFixtureTests.swift: runs the client's foveation expansion,
// decompressAxisAlignedCoord from ALVRClient/Shaders.metal (included, not copied), on the Mac GPU. The FFR function
// constants are set by the test as FFR.makeFunctionConstants sets them (FFR.swift:122-140).
#include "../../ALVRClient/Shaders.metal"

kernel void ffrExpandFixtureKernel(device const float2 *uvIn [[buffer(0)]],
                                   device float2 *uvOut [[buffer(1)]],
                                   uint gid [[thread_position_in_grid]]) {
    uvOut[gid] = decompressAxisAlignedCoord(uvIn[gid]);
}

/// e-nable Zig Core — root module
///
/// Re-exports all public modules for the static library.
/// Each module has a single responsibility:
///   - pipeline: greyscale conversion, contrast LUT, sharpening
///   - dither: Atkinson error diffusion (16-level quantization)
///   - delta: XOR differencing, dirty regions, compression
///   - color: octree quantization for Kaleido 3 (4096 colors)
///   - ffi: C ABI exports for Swift and JNI consumers

pub const pipeline = @import("pipeline.zig");
pub const dither = @import("dither.zig");
pub const delta = @import("delta.zig");
pub const color = @import("color.zig");
pub const ffi = @import("ffi.zig");

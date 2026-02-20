#include <metal_stdlib>
using namespace metal;

/// Soft glow effect for the active line in the gutter.
///
/// Applied as a SwiftUI .colorEffect shader. Adds a subtle luminance
/// boost centered on the active line, fading out vertically.
///
/// Parameters:
///   - position: pixel coordinate in the view
///   - activeLineY: Y position of the active line center (normalized 0-1)
///   - glowRadius: radius of the glow in normalized coordinates
///   - glowColor: the glow tint color (r, g, b, a)
///   - glowIntensity: overall glow strength (0.0 to 1.0)
[[ stitchable ]] half4 gutterGlow(
    float2 position,
    half4 currentColor,
    float activeLineY,
    float glowRadius,
    half4 glowColor,
    float glowIntensity
) {
    // Vertical distance from the active line
    float dist = abs(position.y - activeLineY);

    // Smooth falloff using Gaussian-like curve
    float falloff = exp(-dist * dist / (2.0 * glowRadius * glowRadius));

    // Blend glow color with current color
    half4 glow = glowColor * half(falloff * glowIntensity);

    return currentColor + glow * (1.0h - currentColor.a * 0.5h);
}

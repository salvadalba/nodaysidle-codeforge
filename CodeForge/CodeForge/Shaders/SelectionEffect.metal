#include <metal_stdlib>
using namespace metal;

/// Soft-edge highlight effect for text selection.
///
/// Applied as a SwiftUI .colorEffect shader. Draws a semi-transparent
/// colored overlay within a rectangular selection region, with
/// feathered edges for a polished appearance.
///
/// Parameters:
///   - position: pixel coordinate in the view
///   - selectionRect: (x, y, width, height) of the selection
///   - highlightColor: the selection tint (r, g, b, a)
///   - edgeSoftness: feather radius in pixels
[[ stitchable ]] half4 selectionEffect(
    float2 position,
    half4 currentColor,
    float4 selectionRect,
    half4 highlightColor,
    float edgeSoftness
) {
    // Compute distance from selection rectangle edges
    float2 rectMin = selectionRect.xy;
    float2 rectMax = selectionRect.xy + selectionRect.zw;

    // Signed distance to each edge (negative = inside)
    float dLeft   = rectMin.x - position.x;
    float dRight  = position.x - rectMax.x;
    float dTop    = rectMin.y - position.y;
    float dBottom = position.y - rectMax.y;

    // Max of all edges gives distance to nearest edge (positive = outside)
    float dist = max(max(dLeft, dRight), max(dTop, dBottom));

    // Smooth step for soft edges
    float alpha = 1.0 - smoothstep(-edgeSoftness, edgeSoftness, dist);

    // Blend highlight onto current color
    half4 highlight = highlightColor * half(alpha);

    return currentColor + highlight * (1.0h - currentColor.a * 0.3h);
}

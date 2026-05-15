#!/usr/bin/env python3
"""
Post-Processing Script for Product Photography
Adjusts brightness, contrast, shadows, removes green screen color spill,
and strips all metadata from transparent PNG images after background removal.

Author: John O'Neill Sr.
Company: Azure Innovators

Usage:
    python postprocess_image.py <input.png> <output.png> [options]

Options:
    --brightness FLOAT      Brightness adjustment factor (default: 1.03)
    --contrast FLOAT        Contrast adjustment factor (default: 1.05)
    --shadows INT           Shadow lightening amount 0-100 (default: 15)
    --spill-color COLOR     Color to remove: green, blue, red (default: green)
    --spill-strength FLOAT  Spill removal strength 0.0-1.0 (default: 0.85)
    --no-spill              Skip spill removal
    --no-adjust             Skip brightness/contrast/shadow adjustments
    --no-strip-metadata     Keep image metadata (EXIF, ICC, PNG text chunks)
"""

import sys
import argparse
import numpy as np

try:
    from PIL import Image, ImageEnhance
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install Pillow", file=sys.stderr)
    sys.exit(1)


def adjust_shadows(img_array, shadow_amount):
    """
    Lighten shadow areas of the image.
    shadow_amount: 0-100, where 15 matches Canva's Shadows +15 slider.
    Only affects pixels with alpha > 0 (non-transparent).
    """
    if shadow_amount == 0:
        return img_array

    result = img_array.copy().astype(np.float64)
    alpha = result[:, :, 3]
    mask = alpha > 0

    # Shadow threshold - pixels below this luminance are considered shadows
    rgb = result[:, :, :3]
    luminance = 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]

    # Scale factor: shadow_amount of 15 gives a subtle lift
    lift = shadow_amount / 100.0 * 60.0  # Max lift of 60 levels at shadow_amount=100

    # Apply graduated lift - stronger on darker pixels, tapering off on brighter ones
    shadow_threshold = 128.0
    for c in range(3):
        channel = result[:, :, c]
        # Blend factor: 1.0 for pure black, 0.0 at threshold, 0.0 above
        blend = np.clip((shadow_threshold - luminance) / shadow_threshold, 0, 1)
        adjustment = lift * blend
        channel[mask] = np.clip(channel[mask] + adjustment[mask], 0, 255)
        result[:, :, c] = channel

    return result.astype(np.uint8)


def _detect_edge_proximity(alpha, rgb=None):
    """
    Create a weight map where pixels near the product boundary get higher
    weights. Spill is always worst at edges where the product meets the
    removed background.

    Handles two scenarios:
    1. Transparent background (alpha varies): edges are alpha boundaries
    2. Solid black background (alpha=255 everywhere): edges are the
       transition from near-black to non-black pixels

    Returns a float64 array (0.0 to 1.0) where 1.0 = on the edge,
    tapering to 0.3 deep inside the product.
    """
    from scipy import ndimage

    # Determine if we have real alpha variation or solid alpha
    alpha_range = alpha.max() - alpha.min()

    if alpha_range > 10:
        # Scenario 1: Real transparency — use alpha boundary
        binary_mask = alpha > 128
    else:
        # Scenario 2: Solid background (no transparency)
        # Build mask from pixel luminance: "product" = non-black pixels
        if rgb is not None:
            luminance = 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]
            binary_mask = luminance > 8  # product pixels
        else:
            # Can't detect edges without RGB data, use uniform weight
            return np.where(alpha > 0, 0.8, 0.0)

    # Erode by different amounts to create distance bands from edge
    eroded_4 = ndimage.binary_erosion(binary_mask, iterations=4)
    eroded_8 = ndimage.binary_erosion(binary_mask, iterations=8)
    eroded_16 = ndimage.binary_erosion(binary_mask, iterations=16)

    weight = np.ones_like(alpha, dtype=np.float64) * 0.3  # base interior weight
    weight[~eroded_16] = 0.5   # within 16px of edge
    weight[~eroded_8] = 0.75   # within 8px of edge
    weight[~eroded_4] = 1.0    # within 4px of edge (strongest)
    weight[~binary_mask] = 0.0 # background = skip

    return weight


def _apply_spill_correction(result, spill_ch, other_ch1, other_ch2,
                            visible, edge_weight, strength):
    """
    Generic spill correction for any single-channel spill color.
    Uses three detection passes:
      Pass 1: Absolute excess (spill channel > max of others by threshold)
      Pass 2: Ratio-based (spill channel is proportionally dominant, even
              if absolute difference is tiny — catches dark product edges)
      Pass 3: Edge desaturation (any remaining color cast near alpha edges
              gets desaturated toward neutral gray)
    """
    s = result[:, :, spill_ch].copy()
    o1 = result[:, :, other_ch1].copy()
    o2 = result[:, :, other_ch2].copy()
    max_other = np.maximum(o1, o2)

    # ── Pass 1: Absolute excess detection (original approach, lower threshold) ──
    spill_excess = s - max_other
    # Threshold of 2 catches subtle spill on dark products that the old
    # threshold of 10 missed entirely
    pass1_mask = (spill_excess > 2) & visible

    if np.any(pass1_mask):
        max_rgb = np.maximum(np.maximum(s, o1), o2)
        max_rgb = np.where(max_rgb == 0, 1, max_rgb)
        spill_ratio = spill_excess / max_rgb
        spill_ratio = np.clip(spill_ratio, 0, 1)

        # Combine ratio with edge proximity for correction strength
        correction = spill_ratio * strength * edge_weight
        result[:, :, spill_ch][pass1_mask] = np.clip(
            s[pass1_mask] - (spill_excess[pass1_mask] * correction[pass1_mask]),
            0, 255
        )
        # Warm compensation on the weaker of the two other channels
        weaker_ch = other_ch1 if np.mean(o1[pass1_mask]) < np.mean(o2[pass1_mask]) else other_ch2
        result[:, :, weaker_ch][pass1_mask] = np.clip(
            result[:, :, weaker_ch][pass1_mask] + (spill_excess[pass1_mask] * correction[pass1_mask] * 0.08),
            0, 255
        )

    # Refresh channels after pass 1
    s = result[:, :, spill_ch].copy()
    o1 = result[:, :, other_ch1].copy()
    o2 = result[:, :, other_ch2].copy()
    max_other = np.maximum(o1, o2)

    # ── Pass 2: Ratio-based detection for dark pixels ──
    # On dark products (max channel < 80), even 1-2 levels of green excess
    # is visually obvious. Use proportional detection instead of absolute.
    max_rgb = np.maximum(np.maximum(s, o1), o2)
    is_dark = max_rgb < 80
    # Spill channel is at least 5% higher than the max of the other two
    ratio_excess = np.where(max_other > 0, (s - max_other) / np.maximum(max_other, 1), 0)
    pass2_mask = (ratio_excess > 0.05) & is_dark & visible & (s > max_other)

    if np.any(pass2_mask):
        # For dark pixels, just equalize the spill channel down to max_other
        correction_factor = strength * edge_weight
        target = max_other[pass2_mask]
        current = s[pass2_mask]
        result[:, :, spill_ch][pass2_mask] = np.clip(
            current - ((current - target) * correction_factor[pass2_mask]),
            0, 255
        )

    # Refresh channels after pass 2
    s = result[:, :, spill_ch].copy()
    o1 = result[:, :, other_ch1].copy()
    o2 = result[:, :, other_ch2].copy()

    # ── Pass 3: Edge desaturation ──
    # Near product edges, desaturate any remaining color cast toward neutral.
    # This catches the faintest residual tint that passes 1 and 2 miss.
    # Use a broader zone and stronger correction than interior.
    edge_zone = edge_weight > 0.45  # within ~16px of product boundary
    still_tinted = (s > np.maximum(o1, o2)) & edge_zone & visible

    if np.any(still_tinted):
        # Calculate per-pixel gray value
        gray = (s + o1 + o2) / 3.0
        # Stronger desaturation at edges — scale with edge_weight
        desat_strength = strength * 0.7 * edge_weight
        for ch in [spill_ch, other_ch1, other_ch2]:
            current = result[:, :, ch].copy()
            result[:, :, ch][still_tinted] = np.clip(
                current[still_tinted] + (gray[still_tinted] - current[still_tinted]) * desat_strength[still_tinted],
                0, 255
            )

    # ── Pass 4: Hard edge clamp ──
    # For pixels right at the product boundary (weight=1.0), if the spill
    # channel STILL exceeds the average of the other two channels, force
    # it down. This is the nuclear option for stubborn fringe on dark products.
    s_final = result[:, :, spill_ch].copy()
    o1_final = result[:, :, other_ch1].copy()
    o2_final = result[:, :, other_ch2].copy()
    avg_other = (o1_final + o2_final) / 2.0

    hard_edge = edge_weight >= 0.95
    still_spilling = (s_final > avg_other + 1) & hard_edge & visible

    if np.any(still_spilling):
        clamp_strength = strength * 0.9
        result[:, :, spill_ch][still_spilling] = np.clip(
            s_final[still_spilling] - ((s_final[still_spilling] - avg_other[still_spilling]) * clamp_strength),
            0, 255
        )

    return result


def remove_color_spill(img_array, spill_color="green", strength=0.85):
    """
    Remove color spill (fringing) from green/blue/red screen edges.
    This replicates the Canva technique of selecting the spill color and
    setting Hue, Saturation, and Brightness all to -100.

    Uses a three-pass approach:
    1. Absolute excess: catches obvious spill (threshold lowered to 2 from 10
       for dark products like rubber, black plastic, dark metal)
    2. Ratio-based: catches subtle spill on dark pixels where absolute
       differences are tiny but proportionally significant
    3. Edge desaturation: kills any remaining color cast within ~8px of the
       alpha boundary where spill is always concentrated

    Edge proximity weighting ensures corrections are strongest at the
    product outline (where spill lives) and gentler in the interior
    (avoiding over-correction on legitimately colored surfaces).
    """
    if strength <= 0:
        return img_array

    result = img_array.copy().astype(np.float64)
    alpha = result[:, :, 3]
    rgb = result[:, :, :3]

    # Determine visibility mask: handles both transparent and solid backgrounds
    alpha_range = alpha.max() - alpha.min()
    if alpha_range > 10:
        # Real transparency — only process visible pixels
        visible = alpha > 0
    else:
        # Solid background — "visible" means non-black product pixels
        luminance = 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]
        visible = luminance > 8

    # Build edge proximity weight map
    try:
        edge_weight = _detect_edge_proximity(alpha, rgb)
    except ImportError:
        # scipy not available — fall back to uniform weighting
        edge_weight = np.where(visible, 0.8, 0.0)

    # Channel indices: R=0, G=1, B=2
    channel_map = {
        "green": (1, 0, 2),  # spill=G, others=R,B
        "blue":  (2, 0, 1),  # spill=B, others=R,G
        "red":   (0, 1, 2),  # spill=R, others=G,B
    }

    if spill_color not in channel_map:
        return result.astype(np.uint8)

    spill_ch, other1, other2 = channel_map[spill_color]
    result = _apply_spill_correction(result, spill_ch, other1, other2,
                                     visible, edge_weight, strength)

    return result.astype(np.uint8)


def strip_metadata(img):
    """
    Strip ALL metadata from a PIL Image, returning a clean copy.

    Removes EXIF data (camera model, GPS coordinates, timestamps, software
    tags), ICC color profiles, PNG text chunks (tEXt, iTXt, zTXt), XMP data,
    and any other ancillary metadata. The result is a pixel-identical image
    with zero embedded metadata — safe for public product listings on
    WooCommerce, eBay, Amazon, Etsy, and similar platforms.

    Why this matters for e-commerce:
    - EXIF GPS tags can expose your studio/warehouse location
    - Camera and software metadata reveals your production workflow
    - Some platforms inject their own metadata on upload; starting clean
      avoids conflicts and keeps file sizes minimal
    - Stripping ICC profiles is safe for web-destined PNGs rendered in sRGB
    """
    # Create a brand-new image with only pixel data — no metadata carries over
    clean = Image.new(img.mode, img.size)
    try:
        clean.putdata(list(img.get_flattened_data()))
    except AttributeError:
        # Pillow < 14 fallback
        clean.putdata(list(img.getdata()))
    return clean


def postprocess_image(input_path, output_path,
                      brightness=1.03, contrast=1.05,
                      shadow_amount=15, spill_color="green",
                      spill_strength=0.85, do_spill=True,
                      do_adjust=True, do_strip_metadata=True):
    """
    Main post-processing pipeline.
    Order: Spill removal -> Shadow lift -> Brightness -> Contrast -> Metadata strip
    """
    try:
        img = Image.open(input_path).convert("RGBA")
    except Exception as e:
        print(f"ERROR: Cannot open image: {e}", file=sys.stderr)
        return False

    img_array = np.array(img)

    # Step 1: Remove color spill (do this first on raw data)
    if do_spill:
        img_array = remove_color_spill(img_array, spill_color, spill_strength)

    # Step 2: Adjust shadows
    if do_adjust and shadow_amount > 0:
        img_array = adjust_shadows(img_array, shadow_amount)

    # Convert back to PIL for enhancement filters
    img = Image.fromarray(img_array, "RGBA")

    if do_adjust:
        # Step 3: Brightness
        if brightness != 1.0:
            # Split alpha to preserve it through enhancement
            r, g, b, a = img.split()
            rgb_img = Image.merge("RGB", (r, g, b))
            enhancer = ImageEnhance.Brightness(rgb_img)
            rgb_img = enhancer.enhance(brightness)
            r2, g2, b2 = rgb_img.split()
            img = Image.merge("RGBA", (r2, g2, b2, a))

        # Step 4: Contrast
        if contrast != 1.0:
            r, g, b, a = img.split()
            rgb_img = Image.merge("RGB", (r, g, b))
            enhancer = ImageEnhance.Contrast(rgb_img)
            rgb_img = enhancer.enhance(contrast)
            r2, g2, b2 = rgb_img.split()
            img = Image.merge("RGBA", (r2, g2, b2, a))

    # Step 5: Strip metadata
    if do_strip_metadata:
        img = strip_metadata(img)

    try:
        img.save(output_path, "PNG", optimize=True)
        return True
    except Exception as e:
        print(f"ERROR: Cannot save image: {e}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Post-process transparent PNGs: adjust brightness, contrast, shadows, and remove color spill."
    )
    parser.add_argument("input", help="Input PNG file path")
    parser.add_argument("output", help="Output PNG file path")
    parser.add_argument("--brightness", type=float, default=1.03,
                        help="Brightness factor (default: 1.03, Canva +5 equivalent)")
    parser.add_argument("--contrast", type=float, default=1.05,
                        help="Contrast factor (default: 1.05, Canva +5 equivalent)")
    parser.add_argument("--shadows", type=int, default=15,
                        help="Shadow lightening 0-100 (default: 15)")
    parser.add_argument("--spill-color", choices=["green", "blue", "red"],
                        default="green", help="Spill color to remove (default: green)")
    parser.add_argument("--spill-strength", type=float, default=0.85,
                        help="Spill removal strength 0.0-1.0 (default: 0.85)")
    parser.add_argument("--no-spill", action="store_true",
                        help="Skip spill removal")
    parser.add_argument("--no-adjust", action="store_true",
                        help="Skip brightness/contrast/shadow adjustments")
    parser.add_argument("--no-strip-metadata", action="store_true",
                        help="Keep image metadata (EXIF, ICC profiles, PNG text chunks)")

    args = parser.parse_args()

    success = postprocess_image(
        args.input, args.output,
        brightness=args.brightness,
        contrast=args.contrast,
        shadow_amount=args.shadows,
        spill_color=args.spill_color,
        spill_strength=args.spill_strength,
        do_spill=not args.no_spill,
        do_adjust=not args.no_adjust,
        do_strip_metadata=not args.no_strip_metadata
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()

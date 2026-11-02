#!/usr/bin/env python3
"""Create deterministic, illustrated Wayfarer demo movies.

The app has a native AVAssetWriter generator for small development previews. This
offline generator provides a durable bundle source for the same import path. It
ports the six Core Graphics scenes from Sources/Demo/DemoMediaService.swift to
Pillow, then sends one RGB frame at a time to ffmpeg/libx264.
"""

from __future__ import annotations

import argparse
import math
import subprocess
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageChops, ImageDraw, ImageFilter


FPS = 12
DURATION_SECONDS = 6
FRAME_COUNT = FPS * DURATION_SECONDS
DEFAULT_COUNT = 85

# The palette changes by group. Each palette keeps enough contrast for small
# portrait frames while making adjacent clips visibly different.
PALETTES = (
    {
        "sky": (25, 61, 105), "horizon": (49, 105, 100), "ground": (23, 65, 49),
        "sun": (247, 182, 69), "accent": (238, 95, 63), "water": (25, 123, 160),
        "light": (232, 238, 208), "dark": (19, 35, 48), "cream": (246, 229, 183),
    },
    {
        "sky": (104, 50, 83), "horizon": (176, 85, 69), "ground": (99, 40, 48),
        "sun": (255, 207, 103), "accent": (44, 150, 137), "water": (40, 103, 145),
        "light": (250, 239, 214), "dark": (49, 35, 58), "cream": (255, 224, 166),
    },
    {
        "sky": (24, 105, 125), "horizon": (50, 157, 139), "ground": (33, 96, 67),
        "sun": (253, 221, 118), "accent": (237, 109, 82), "water": (20, 142, 178),
        "light": (228, 247, 228), "dark": (16, 57, 66), "cream": (245, 240, 181),
    },
    {
        "sky": (42, 48, 102), "horizon": (89, 77, 140), "ground": (47, 44, 82),
        "sun": (255, 159, 83), "accent": (217, 78, 128), "water": (33, 91, 157),
        "light": (241, 229, 210), "dark": (25, 31, 68), "cream": (255, 219, 166),
    },
    {
        "sky": (68, 83, 65), "horizon": (118, 128, 80), "ground": (47, 88, 57),
        "sun": (246, 196, 91), "accent": (217, 121, 56), "water": (35, 112, 134),
        "light": (240, 238, 201), "dark": (35, 52, 39), "cream": (245, 219, 148),
    },
)


def mix(a: tuple[int, int, int], b: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    return tuple(round(x + (y - x) * amount) for x, y in zip(a, b))


def polygon(draw: ImageDraw.ImageDraw, points: Iterable[tuple[float, float]], fill: tuple[int, int, int], width: int, height: int) -> None:
    draw.polygon([(round(x * width), round(y * height)) for x, y in points], fill=fill)


def ellipse(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], fill: tuple[int, int, int], width: int, height: int) -> None:
    draw.ellipse(tuple(round(value) for value in box), fill=fill)


def rect(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], fill: tuple[int, int, int]) -> None:
    draw.rectangle(tuple(round(value) for value in box), fill=fill)


def line(draw: ImageDraw.ImageDraw, points: Iterable[tuple[float, float]], fill: tuple[int, int, int], width: int) -> None:
    draw.line([(round(x), round(y)) for x, y in points], fill=fill, width=max(1, width), joint="curve")


def draw_scenery(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    horizon = h * (0.38 + 0.04 * (variant % 3))
    rect(draw, (0, 0, w, horizon), palette["horizon"])
    ellipse(draw, (w * (0.68 - 0.20 * progress), h * 0.13, w * (0.82 - 0.20 * progress), h * 0.13 + w * 0.14), palette["sun"], w, h)
    mountain = (palette["dark"] if variant % 2 else mix(palette["ground"], palette["dark"], 0.35))
    if variant % 2:
        points = [(0, 0.53), (0.18, 0.24), (0.33, 0.49), (0.56, 0.18), (0.77, 0.48), (1, 0.26), (1, 1), (0, 1)]
    else:
        points = [(0, 0.50), (0.28, 0.20), (0.46, 0.45), (0.70, 0.27), (1, 0.52), (1, 1), (0, 1)]
    polygon(draw, points, mountain, w, h)
    polygon(draw, [(0, 0.67), (0.24, 0.53), (0.48, 0.65), (0.72, 0.48), (1, 0.62), (1, 1), (0, 1)], palette["ground"], w, h)
    for row in range(3):
        y = h * (0.16 + row * 0.11) + math.sin(progress * math.tau + row) * h * 0.006
        line(draw, [(0, y), (w, y + h * 0.025)], mix(palette["light"], palette["horizon"], 0.25), max(1, w // 180))


def draw_food(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    rect(draw, (0, 0, w, h * 0.24), mix(palette["dark"], palette["accent"], 0.35))
    rect(draw, (0, h * 0.24, w, h), mix(palette["ground"], palette["accent"], 0.42))
    ellipse(draw, (w * 0.08, h * 0.27, w * 0.92, h * 0.76), palette["light"], w, h)
    ellipse(draw, (w * 0.16, h * 0.34, w * 0.84, h * 0.69), mix(palette["light"], palette["water"], 0.14), w, h)
    foods = [
        (0.25, 0.46, palette["accent"]), (0.53, 0.42, palette["sun"]),
        (0.67, 0.57, palette["water"]), (0.39, 0.59, palette["ground"]),
    ]
    for item, (x, y, color) in enumerate(foods):
        drift = math.sin(progress * math.tau + item * 1.5) * w * (0.018 + 0.005 * (variant % 3))
        size = w * (0.12 + 0.015 * ((variant + item) % 3))
        ellipse(draw, (x * w + drift - size / 2, y * h - size / 2, x * w + drift + size / 2, y * h + size / 2), color, w, h)
    for steam in range(3):
        x = w * (0.31 + steam * 0.16)
        line(draw, [(x, h * 0.27), (x + math.sin(progress * math.tau + steam) * w * 0.015, h * 0.20), (x - w * 0.012, h * 0.13)], palette["light"], max(1, w // 160))


def draw_architecture(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    rect(draw, (0, 0, w, h), mix(palette["sky"], palette["horizon"], 0.32))
    rect(draw, (w * 0.08, h * 0.15, w * 0.92, h * 0.93), mix(palette["accent"], palette["cream"], 0.42))
    polygon(draw, [(0.04, 0.17), (0.50, 0.02), (0.96, 0.17)], palette["dark"], w, h)
    columns = 3 + variant % 2
    rows = 3 + (variant // 2) % 2
    for row in range(rows):
        for column in range(columns):
            x = w * (0.17 + column * (0.66 / max(columns - 1, 1)))
            y = h * (0.25 + row * (0.48 / max(rows - 1, 1)))
            light = (row + column + variant) % 3 == 0
            rect(draw, (x - w * 0.065, y - h * 0.042, x + w * 0.065, y + h * 0.042), palette["sun"] if light else palette["dark"])
    door_x = w * (0.44 + 0.03 * math.sin(progress * math.tau))
    rect(draw, (door_x - w * 0.09, h * 0.69, door_x + w * 0.09, h), palette["water"])
    rect(draw, (door_x - w * 0.03, h * 0.79, door_x + w * 0.01, h * 0.83), palette["cream"])


def draw_person(draw: ImageDraw.ImageDraw, center: tuple[float, float], scale: float, shirt: tuple[int, int, int], skin: tuple[int, int, int], ground: tuple[int, int, int], variant: int) -> None:
    x, y = center
    ellipse(draw, (x - scale * 0.22, y - scale * 0.86, x + scale * 0.22, y - scale * 0.42), skin, round(scale * 2), round(scale * 2))
    ellipse(draw, (x - scale * 0.47, y - scale * 0.45, x + scale * 0.47, y + scale * 0.34), shirt, round(scale * 2), round(scale * 2))
    stroke = max(1, round(scale * 0.07))
    leg_spread = 0.17 + 0.04 * (variant % 3)
    line(draw, [(x - scale * 0.12, y + scale * 0.30), (x - scale * leg_spread, y + scale * 0.92)], ground, stroke)
    line(draw, [(x + scale * 0.12, y + scale * 0.30), (x + scale * leg_spread, y + scale * 0.92)], ground, stroke)


def draw_people(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    rect(draw, (0, 0, w, h * 0.67), mix(palette["sky"], palette["horizon"], 0.55))
    rect(draw, (0, h * 0.67, w, h), palette["ground"])
    for column in range(6):
        x = w * (0.08 + column * 0.18)
        line(draw, [(x, h * 0.67), (x + w * 0.08, h * 0.43)], mix(palette["light"], palette["ground"], 0.30), max(1, w // 170))
    walk = math.sin(progress * math.tau) * w * 0.045
    draw_person(draw, (w * 0.36 + walk, h * 0.67), min(w, h) * (0.23 + 0.02 * (variant % 2)), palette["accent"], palette["sun"], palette["dark"], variant)
    draw_person(draw, (w * 0.68 - walk * 0.7, h * 0.67), min(w, h) * (0.19 + 0.02 * ((variant + 1) % 2)), palette["water"], mix(palette["sun"], palette["accent"], 0.25), palette["dark"], variant + 1)


def draw_road(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    rect(draw, (0, 0, w, h * 0.52), palette["horizon"])
    polygon(draw, [(0.32, 0.42), (0.68, 0.42), (1, 1), (0, 1)], palette["dark"], w, h)
    line(draw, [(w * 0.5, h * 0.45), (w * (0.50 + 0.10 * math.sin(progress * math.tau)), h)], palette["sun"], max(2, w // 28))
    for side in (0.10, 0.82):
        for tree in range(3):
            x = w * (side + tree * 0.05)
            y = h * (0.38 + tree * 0.08)
            ellipse(draw, (x - w * 0.08, y - w * 0.12, x + w * 0.08, y + w * 0.04), palette["ground"], w, h)
            line(draw, [(x, y), (x, h * 0.65)], palette["dark"], max(1, w // 90))
    if variant % 2:
        rect(draw, (w * 0.42, h * 0.32, w * 0.58, h * 0.42), palette["accent"])


def draw_water(draw: ImageDraw.ImageDraw, width: int, height: int, progress: float, palette: dict[str, tuple[int, int, int]], variant: int) -> None:
    w, h = width, height
    rect(draw, (0, 0, w, h * 0.46), palette["horizon"])
    rect(draw, (0, h * 0.46, w, h), palette["water"])
    ellipse(draw, (w * (0.10 + 0.50 * progress), h * 0.13, w * (0.21 + 0.50 * progress), h * 0.13 + w * 0.11), palette["sun"], w, h)
    for row in range(8):
        y = h * (0.53 + row * 0.058)
        sway = math.sin(progress * math.tau * (1.0 + row * 0.04) + row) * w * 0.018
        line(draw, [(0, y), (w * 0.24 + sway, y - h * 0.015), (w * 0.52 - sway, y + h * 0.012), (w, y)], mix(palette["light"], palette["water"], 0.15), max(1, w // 130))
    boat_x = w * (0.22 + 0.50 * progress)
    polygon(draw, [(boat_x - w * 0.10, h * 0.60), (boat_x + w * 0.12, h * 0.60), (boat_x + w * 0.06, h * 0.67), (boat_x - w * 0.05, h * 0.67)], palette["dark"], w, h)
    if variant % 2 == 0:
        line(draw, [(boat_x, h * 0.60), (boat_x, h * 0.48)], palette["cream"], max(1, w // 100))
        polygon(draw, [(boat_x, h * 0.49), (boat_x, h * 0.59), (boat_x + w * 0.08, h * 0.57)], palette["accent"], w, h)


def draw_frame(clip_index: int, frame_index: int, width: int, height: int) -> Image.Image:
    progress = frame_index / max(FRAME_COUNT - 1, 1)
    group = clip_index // 6
    palette = PALETTES[(group + clip_index) % len(PALETTES)]
    scene = (clip_index * 5 + group) % 6
    variant = (clip_index * 3 + frame_index // 18 + group) % 11

    image = Image.new("RGB", (width, height), palette["sky"])
    draw = ImageDraw.Draw(image)
    if scene == 0:
        draw_scenery(draw, width, height, progress, palette, variant)
    elif scene == 1:
        draw_food(draw, width, height, progress, palette, variant)
    elif scene == 2:
        draw_architecture(draw, width, height, progress, palette, variant)
    elif scene == 3:
        draw_people(draw, width, height, progress, palette, variant)
    elif scene == 4:
        draw_road(draw, width, height, progress, palette, variant)
    else:
        draw_water(draw, width, height, progress, palette, variant)

    # A small geometric travel-mark makes every source asset distinct even
    # when two clips share the same scene and palette combination. It carries
    # no semantic result; it is only part of the illustrated source art.
    mark_x = width * (0.06 + (clip_index % 11) * 0.018)
    mark_y = height * (0.055 + ((clip_index // 11) % 7) * 0.014)
    mark_size = min(width, height) * (0.018 + ((clip_index // 7) % 5) * 0.004)
    ellipse(draw, (mark_x - mark_size, mark_y - mark_size, mark_x + mark_size, mark_y + mark_size), palette["cream"], width, height)
    line(draw, [(mark_x - mark_size * 0.65, mark_y), (mark_x + mark_size * 0.65, mark_y)], palette["accent"], max(1, width // 180))

    # The native helper includes a noticeable handheld shake in selected clips.
    if clip_index % 5 == 3:
        shake = round(math.sin(progress * math.pi * 8 + clip_index) * width * 0.025)
        image = ImageChops.offset(image, shake, round(-shake * 0.4))

    # Keep the two capture artifacts visible in a few clips for import and
    # montage coverage: a mild soft focus and a lifted exposure.
    if clip_index % 6 == 1:
        blurred = image.filter(ImageFilter.GaussianBlur(radius=max(0.6, min(width, height) / 300)))
        image = Image.blend(image, blurred, 0.34)
        image = Image.blend(image, Image.new("RGB", image.size, (255, 255, 255)), 0.06)
    if clip_index % 7 == 4:
        image = Image.blend(image, Image.new("RGB", image.size, (255, 255, 255)), 0.20)
    return image


def write_clip(ffmpeg: str, clip_index: int, output: Path) -> None:
    landscape = (clip_index + 1) % 3 == 0
    width, height = (640, 360) if landscape else (360, 640)
    command = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
        "-framerate", str(FPS), "-i", "-", "-an", "-c:v", "libx264",
        "-preset", "veryfast", "-crf", "27", "-pix_fmt", "yuv420p",
        "-g", str(FRAME_COUNT), "-keyint_min", str(FRAME_COUNT), "-sc_threshold", "0",
        "-movflags", "+faststart", str(output),
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    assert process.stdin is not None
    try:
        for frame_index in range(FRAME_COUNT):
            frame = draw_frame(clip_index, frame_index, width, height)
            process.stdin.write(frame.tobytes())
        process.stdin.close()
        result = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if result != 0:
        raise RuntimeError(f"ffmpeg failed for {output.name} with exit status {result}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("Resources/SampleTrip"), help="Fixture directory")
    parser.add_argument("--count", type=int, default=DEFAULT_COUNT, help="Number of clips to write")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.count < 1 or args.count > DEFAULT_COUNT:
        raise SystemExit(f"--count must be between 1 and {DEFAULT_COUNT}")
    args.output.mkdir(parents=True, exist_ok=True)
    for clip_index in range(args.count):
        output = args.output / f"wayfarer-demo-{clip_index + 1:03d}.mp4"
        if output.exists():
            output.unlink()
        write_clip(args.ffmpeg, clip_index, output)
        print(f"{clip_index + 1:03d}/{args.count}: {output} ({output.stat().st_size} bytes)", flush=True)


if __name__ == "__main__":
    main()

# Wayfarer sample media

`generate_sample_media.py` creates the bundled development fixtures used by the
Wayfarer demo. It draws six original scene families and writes frames one at a time to the
software `libx264` encoder. It does not use network media, AVAssetWriter, or a
simulator.

Requirements: Python 3, Pillow, and ffmpeg with the `libx264` encoder.

Run from the repository root:

```sh
python3 scripts/generate_sample_media.py --output Resources/SampleTrip
```

The default output is 85 six-second H.264 MP4 files at 12 fps. Files numbered
003, 006, and so on are 640x360 landscape. The other files are 360x640
portrait. The generator changes scene, palette, geometry, motion, shake,
exposure, and focus so adjacent clips remain differentiated.

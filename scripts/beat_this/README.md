# Beat This! model

`Core/Models/BeatThisSmall.mlmodelc` is the `small0` model from
[Beat This!](https://github.com/CPJKU/beat_this) by the Institute of
Computational Perception, JKU Linz. The code and model weights are MIT
licensed. The license ships with the app in `Core/Models/BeatThis-LICENSE.txt`.
The authors note that some of their training audio has its own copyright terms.

`convert.py` made the file. It needs Python 3.12 and versions that coremltools
supports: torch 2.7.0, torchaudio 2.7.0, numpy below 2.3, and coremltools 9.0,
plus the `beat_this` package from GitHub. Python 3.14 cannot save Core ML files.

```sh
python convert.py BeatThisSmall.mlpackage
xcrun coremlcompiler compile BeatThisSmall.mlpackage .
```

Then replace `Core/Models/BeatThisSmall.mlmodelc` with the compiled folder.
The model takes a 1 x 1500 x 128 log mel spectrogram, which is 30 seconds at
50 frames a second, and returns beat and bar-start scores for every frame.
`Core/BarTracker.swift` builds that spectrogram exactly as the Python package
does, so any change to the model's input must change both.

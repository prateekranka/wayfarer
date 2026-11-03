"""Converts the Beat This! small model to the Core ML file the app ships.

Usage: python convert.py BeatThisSmall.mlpackage
"""
import sys

import coremltools as ct
import numpy as np
import rotary_embedding_torch.rotary_embedding_torch as rope
import torch
from beat_this.inference import load_model

# Core ML cannot convert this einsum. It is only an outer product.
_einsum = rope.einsum
rope.einsum = lambda eq, a, b: a.unsqueeze(-1) * b if eq.replace(" ", "") == "...,f->...f" else _einsum(eq, a, b)


class Scores(torch.nn.Module):
    """Returns beat and bar-start scores as two outputs."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        result = self.model(spect)
        return result["beat"], result["downbeat"]


scores = Scores(load_model("small0", "cpu")).eval()
example = torch.randn(1, 1500, 128)
with torch.no_grad():
    traced = torch.jit.trace(scores, example, check_trace=False)
    expected = scores(example)

# Full precision: half precision gives wrong results on the GPU.
model = ct.convert(traced, inputs=[ct.TensorType(name="spect", shape=(1, 1500, 128))],
                   outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
                   minimum_deployment_target=ct.target.iOS17, convert_to="mlprogram",
                   compute_precision=ct.precision.FLOAT32)
model.save(sys.argv[1])
result = model.predict({"spect": example.numpy()})
for name, reference in zip(["beat", "downbeat"], expected):
    same = np.mean((result[name].reshape(-1) > 0) == (reference.numpy().reshape(-1) > 0))
    print(f"{name}: {same:.3f} of frames agree with PyTorch")

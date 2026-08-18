"""Convert 2_HP-UVR.pth to a Core ML mlpackage for on-device inference (v2).

Runs on a macOS GitHub Actions runner (coremltools prediction needs macOS).
The graph is exported with the pipeline's fixed 512-frame window; the
aggressiveness pow-mask is applied outside the model at runtime.
"""
import hashlib
import importlib
import math
import os
import sys
import types

import numpy as np
import torch

# spec_utils imports librosa at module load; the net itself never uses it,
# and librosa cannot run everywhere we need this to (numba/JIT).
sys.modules.setdefault("librosa", types.ModuleType("librosa"))
sys.modules.setdefault("soundfile", types.ModuleType("soundfile"))

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UVR = os.path.join(REPO, "uvr")
sys.path.insert(0, UVR)
os.chdir(UVR)  # modelparams/*.json resolve relative to CWD

from uvr5_pack.utils import _get_name_params  # noqa: E402
from uvr5_pack.lib_v5.model_param_init import ModelParameters  # noqa: E402

MODEL_PATH = "uvr5_weights/2_HP-UVR.pth"

nn_arch_sizes = [31191, 33966, 61968, 123821, 123812, 537238]
model_size = math.ceil(os.stat(MODEL_PATH).st_size / 1024)
arch = min(nn_arch_sizes, key=lambda x: abs(x - model_size))
nets = importlib.import_module(
    "uvr5_pack.lib_v5.nets" + f"_{arch}KB".replace("_31191KB", ""))
model_hash = hashlib.md5(open(MODEL_PATH, "rb").read()).hexdigest()
param_name, params_json = _get_name_params(MODEL_PATH, model_hash)
print(f"arch={arch} params={param_name}")

mp = ModelParameters(params_json)
bins = mp.param["bins"]
model = nets.CascadedASPPNet(bins * 2)
model.load_state_dict(torch.load(MODEL_PATH, map_location="cpu"))
model.eval()

dummy = torch.rand(1, 2, bins + 1, 512)
with torch.no_grad():
    ref = model(dummy)
traced = torch.jit.trace(model, dummy)

import coremltools as ct  # noqa: E402

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="mag", shape=tuple(dummy.shape))],
    outputs=[ct.TensorType(name="masked_mag")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS17,
)
out = os.path.join(REPO, "UVR2HP.mlpackage")
mlmodel.save(out)
print("saved", out)

pred = mlmodel.predict({"mag": dummy.numpy()})["masked_mag"]
diff = np.abs(pred - ref.numpy()).max()
print(f"fp16 Core ML vs fp32 torch max abs diff: {diff:.5f}")
assert diff < 0.02, "Core ML output diverges from torch beyond fp16 tolerance"

"""Validate tools/uvr_dsp.py (numpy-only) against the original librosa
pipeline in uvr/. Run inside desktop-server/.venv with cwd=uvr/:

    ..\\desktop-server\\.venv\\Scripts\\python ..\\tools\\test_dsp_parity.py <audio-file>

Compares (on a real track):
  1. input side:  combined spectrogram fed to the model
  2. output side: reconstructed wave using an identity mask (isolates DSP
     from the network)
Reports SNR in dB; > 40 dB means differences are far below audibility.
"""
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.getcwd())                      # uvr/
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

import librosa  # noqa: E402  (reference implementation)
from uvr5_pack.lib_v5 import spec_utils  # noqa: E402
from uvr5_pack.lib_v5.model_param_init import ModelParameters  # noqa: E402
import uvr_dsp  # noqa: E402


def snr_db(ref, test):
    ref = np.asarray(ref, dtype=np.float64)
    test = np.asarray(test, dtype=np.float64)
    n = min(ref.shape[-1], test.shape[-1])
    ref, test = ref[..., :n], test[..., :n]
    noise = ref - test
    p_ref = np.sum(np.abs(ref) ** 2)
    p_noise = np.sum(np.abs(noise) ** 2)
    if p_noise == 0:
        return float("inf")
    return 10 * np.log10(p_ref / p_noise)


def load_wave_ffmpeg(path, sr=44100, seconds=30):
    """Decode with ffmpeg so both pipelines get the same PCM."""
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-t", str(seconds),
           "-f", "f32le", "-acodec", "pcm_f32le", "-ac", "2", "-ar", str(sr), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T
    return np.ascontiguousarray(x)


def reference_input(wave44, mp):
    """separate.py's input side, verbatim (librosa)."""
    bands_n = len(mp.param["band"])
    X_wave, X_spec_s = {}, {}
    input_high_end = None
    input_high_end_h = 0
    for d in range(bands_n, 0, -1):
        bp = mp.param["band"][d]
        if d == bands_n:
            X_wave[d] = wave44
        else:
            X_wave[d] = librosa.core.resample(
                X_wave[d + 1], mp.param["band"][d + 1]["sr"], bp["sr"],
                res_type=bp["res_type"])
        X_spec_s[d] = spec_utils.wave_to_spectrogram_mt(
            X_wave[d], bp["hl"], bp["n_fft"], mp.param["mid_side"],
            mp.param["mid_side_b2"], mp.param["reverse"])
        if d == bands_n:
            input_high_end_h = (bp["n_fft"] // 2 - bp["crop_stop"]) + (
                mp.param["pre_filter_stop"] - mp.param["pre_filter_start"])
            input_high_end = X_spec_s[d][
                :, bp["n_fft"] // 2 - input_high_end_h: bp["n_fft"] // 2, :]
    return (spec_utils.combine_spectrograms(X_spec_s, mp),
            input_high_end_h, input_high_end)


def main():
    audio = sys.argv[1]
    mp = ModelParameters("uvr5_pack/lib_v5/modelparams/4band_v2.json")
    wave44 = load_wave_ffmpeg(audio)
    print(f"audio: {audio} | {wave44.shape[1]/44100:.1f}s")

    # --- input side
    ref_spec, ref_heh, ref_he = reference_input(wave44, mp)
    my_spec, my_heh, my_he = uvr_dsp.input_pipeline(wave44, mp.param)
    assert ref_heh == my_heh, (ref_heh, my_heh)
    t = min(ref_spec.shape[2], my_spec.shape[2])
    in_snr = snr_db(ref_spec[:, :, :t], my_spec[:, :, :t])
    mag_snr = snr_db(np.abs(ref_spec[:, :, :t]), np.abs(my_spec[:, :, :t]))
    print(f"input combined spec SNR: {in_snr:.1f} dB (magnitude {mag_snr:.1f} dB)")

    # --- output side, identity mask, each pipeline consuming ITS OWN spec
    ref_wave = spec_utils.cmb_spectrogram_to_wave(ref_spec, mp, ref_heh, ref_he)
    my_wave = uvr_dsp.output_pipeline(my_spec, mp.param, my_heh, my_he)
    out_snr = snr_db(ref_wave.T, my_wave.T)
    print(f"output wave SNR (identity mask): {out_snr:.1f} dB")

    # --- round trip sanity: output should approximate the input audio
    rt_snr = snr_db(wave44[:, : my_wave.shape[0]], my_wave.T)
    print(f"numpy round-trip vs source: {rt_snr:.1f} dB")

    ok = in_snr > 40 and out_snr > 40
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

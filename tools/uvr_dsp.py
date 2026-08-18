"""numpy-only reimplementation of the UVR v5 inference DSP pipeline.

No librosa, no scipy, no numba - just numpy. This is the executable spec for
the v2 on-device port (embedded Python with numpy iOS wheels, or a further
port to Swift/Accelerate), validated against the original librosa pipeline
by tools/test_dsp_parity.py.

Covers the inference path of uvr/separate.py + uvr5_pack/lib_v5/spec_utils.py
for multi-band model params (e.g. 4band_v2 used by 2_HP-UVR):
  input:  44.1k stereo -> per-band waves -> per-band STFT -> combined spec
  output: masked spec -> high-end mirroring -> per-band iSTFT + filters ->
          resampled sum -> 44.1k stereo instrumental
"""
import math

import numpy as np


# ---------------------------------------------------------------------------
# librosa-0.9-compatible STFT / iSTFT (hann, center=True, pad_mode='constant')


def _hann(n):
    # periodic hann, matching scipy.signal.get_window('hann', n, fftbins=True)
    return 0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(n) / n)


def stft(y, n_fft, hop):
    y = np.pad(y.astype(np.float32), n_fft // 2, mode="constant")
    n_frames = 1 + (len(y) - n_fft) // hop
    idx = np.arange(n_fft)[None, :] + hop * np.arange(n_frames)[:, None]
    frames = y[idx] * _hann(n_fft)[None, :]
    return np.fft.rfft(frames, axis=1).T.astype(np.complex64)  # (n_fft//2+1, T)


def istft(spec, hop):
    n_fft = 2 * (spec.shape[0] - 1)
    frames = np.fft.irfft(spec.T, n=n_fft, axis=1)
    w = _hann(n_fft)
    frames = frames * w[None, :]
    n_frames = spec.shape[1]
    out_len = n_fft + hop * (n_frames - 1)
    out = np.zeros(out_len)
    wsum = np.zeros(out_len)
    wsq = w * w
    for t in range(n_frames):
        s = t * hop
        out[s:s + n_fft] += frames[t]
        wsum[s:s + n_fft] += wsq
    nz = wsum > 1e-10
    out[nz] /= wsum[nz]
    return out[n_fft // 2: out_len - n_fft // 2].astype(np.float32)


# ---------------------------------------------------------------------------
# Resampling


def resample_fft(x, num):
    """scipy.signal.resample semantics (FFT method) for real x, last axis."""
    n = x.shape[-1]
    big_x = np.fft.fft(x, axis=-1)
    y = np.zeros(x.shape[:-1] + (num,), dtype=complex)
    n_min = min(num, n)
    nyq = n_min // 2 + 1
    y[..., :nyq] = big_x[..., :nyq]
    if n_min > 2:
        y[..., -(n_min - nyq):] = big_x[..., -(n_min - nyq):]
    if n_min % 2 == 0:
        if num < n:
            y[..., n_min // 2] += big_x[..., -(n_min // 2)]
        elif num > n:
            y[..., n_min // 2] *= 0.5
            y[..., -(n_min // 2)] = y[..., n_min // 2]
    return (np.fft.ifft(y, axis=-1) * (num / n)).real.astype(np.float32)


def resample_poly_down(x, q):
    """Integer-factor decimation, matching scipy resample_poly(x, 1, q)
    with its default ('kaiser', 5.0) window design."""
    half = 10 * q
    m = np.arange(2 * half + 1) - half
    fc = 1.0 / q
    h = fc * np.sinc(fc * m) * np.kaiser(2 * half + 1, 5.0)
    h /= h.sum()
    y = np.convolve(x.astype(np.float64), h)[half::q]
    n_out = int(np.ceil(len(x) / q))
    return y[:n_out].astype(np.float32)


# ---------------------------------------------------------------------------
# Spectrogram assembly (ports of spec_utils, already numpy-only)


def fft_lp_filter(spec, bin_start, bin_stop):
    g = 1.0
    for b in range(bin_start, bin_stop):
        g -= 1 / (bin_stop - bin_start)
        spec[:, b, :] = g * spec[:, b, :]
    spec[:, bin_stop:, :] *= 0
    return spec


def fft_hp_filter(spec, bin_start, bin_stop):
    g = 1.0
    for b in range(bin_start, bin_stop, -1):
        g -= 1 / (bin_start - bin_stop)
        spec[:, b, :] = g * spec[:, b, :]
    spec[:, 0:bin_stop + 1, :] *= 0
    return spec


def mirroring(spec_m, input_high_end, param):
    mirror = np.flip(np.abs(
        spec_m[:, param["pre_filter_start"] - 10 - input_high_end.shape[1]:
               param["pre_filter_start"] - 10, :]), 1)
    mirror = mirror * np.exp(1.0j * np.angle(input_high_end))
    return np.where(np.abs(input_high_end) <= np.abs(mirror),
                    input_high_end, mirror)


def combine_spectrograms(specs, param):
    l = min(specs[i].shape[2] for i in specs)
    spec_c = np.zeros(shape=(2, param["bins"] + 1, l), dtype=np.complex64)
    offset = 0
    bands_n = len(param["band"])
    for d in range(1, bands_n + 1):
        bp = param["band"][d]
        h = bp["crop_stop"] - bp["crop_start"]
        spec_c[:, offset:offset + h, :l] = \
            specs[d][:, bp["crop_start"]:bp["crop_stop"], :l]
        offset += h
    if offset > param["bins"]:
        raise ValueError("Too much bins")
    if param["pre_filter_start"] > 0:
        if bands_n == 1:
            spec_c = fft_lp_filter(
                spec_c, param["pre_filter_start"], param["pre_filter_stop"])
        else:
            gp = 1
            for b in range(param["pre_filter_start"] + 1,
                           param["pre_filter_stop"]):
                g = math.pow(10, -(b - param["pre_filter_start"])
                             * (3.5 - gp) / 20.0)
                gp = g
                spec_c[:, b, :] *= g
    return spec_c


# ---------------------------------------------------------------------------
# Full input / output pipelines


def wave_to_spectrogram(wave, hl, n_fft):
    return np.array([stft(wave[0], n_fft, hl), stft(wave[1], n_fft, hl)])


def spectrogram_to_wave(spec, hl):
    return np.array([istft(np.asarray(spec[0]), hl),
                     istft(np.asarray(spec[1]), hl)])


def input_pipeline(wave44, param, high_end_process=True):
    """44.1k stereo float32 (2, N) -> (combined_spec, input_high_end_h,
    input_high_end). Mirrors separate.py's _path_audio_ input side."""
    bands_n = len(param["band"])
    x_wave = {bands_n: wave44}
    x_spec = {}
    input_high_end = None
    input_high_end_h = 0

    for d in range(bands_n, 0, -1):
        bp = param["band"][d]
        if d < bands_n:
            sr_above = param["band"][d + 1]["sr"]
            if bp["sr"] == sr_above:
                x_wave[d] = x_wave[d + 1]
            else:
                q = sr_above // bp["sr"]
                assert q * bp["sr"] == sr_above, "non-integer band ratio"
                x_wave[d] = np.stack([
                    resample_poly_down(x_wave[d + 1][c], q) for c in range(2)])
        x_spec[d] = wave_to_spectrogram(x_wave[d], bp["hl"], bp["n_fft"])
        if d == bands_n and high_end_process:
            input_high_end_h = (bp["n_fft"] // 2 - bp["crop_stop"]) + (
                param["pre_filter_stop"] - param["pre_filter_start"])
            input_high_end = x_spec[d][
                :, bp["n_fft"] // 2 - input_high_end_h: bp["n_fft"] // 2, :]

    return combine_spectrograms(x_spec, param), input_high_end_h, input_high_end


def output_pipeline(spec_m, param, input_high_end_h=None, input_high_end=None):
    """Masked combined spec -> 44.1k stereo wave (N, 2), mirroring
    spec_utils.cmb_spectrogram_to_wave for the inference path."""
    bands_n = len(param["band"])
    offset = 0
    wave = None
    for d in range(1, bands_n + 1):
        bp = param["band"][d]
        spec_s = np.zeros(
            shape=(2, bp["n_fft"] // 2 + 1, spec_m.shape[2]), dtype=complex)
        h = bp["crop_stop"] - bp["crop_start"]
        spec_s[:, bp["crop_start"]:bp["crop_stop"], :] = \
            spec_m[:, offset:offset + h, :]
        offset += h

        if d == bands_n:
            if input_high_end_h:
                max_bin = bp["n_fft"] // 2
                spec_s[:, max_bin - input_high_end_h:max_bin, :] = \
                    input_high_end[:, :input_high_end_h, :]
            if bp["hpf_start"] > 0:
                spec_s = fft_hp_filter(spec_s, bp["hpf_start"], bp["hpf_stop"] - 1)
            if bands_n == 1:
                wave = spectrogram_to_wave(spec_s, bp["hl"])
            else:
                wave = np.add(wave, spectrogram_to_wave(spec_s, bp["hl"]))
        else:
            sr_next = param["band"][d + 1]["sr"]
            if d == 1:
                spec_s = fft_lp_filter(spec_s, bp["lpf_start"], bp["lpf_stop"])
                wave = spectrogram_to_wave(spec_s, bp["hl"])
                if bp["sr"] != sr_next:
                    # original uses librosa sinc_fastest here; bands with
                    # equal rates (4band_v2) never hit this branch
                    factor = sr_next / bp["sr"]
                    wave = resample_fft(wave, int(wave.shape[-1] * factor))
            else:
                spec_s = fft_hp_filter(spec_s, bp["hpf_start"], bp["hpf_stop"] - 1)
                spec_s = fft_lp_filter(spec_s, bp["lpf_start"], bp["lpf_stop"])
                wave2 = np.add(wave, spectrogram_to_wave(spec_s, bp["hl"]))
                # original: librosa.resample(..., res_type='scipy') == FFT
                wave = resample_fft(
                    wave2, int(round(wave2.shape[-1] * sr_next / bp["sr"])))
    return wave.T

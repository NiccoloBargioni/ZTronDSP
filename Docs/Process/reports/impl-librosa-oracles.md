# Implementation report — brief 75: the librosa oracles

| Field | Value |
|---|---|
| Implementer | `librosa` (agent) |
| Brief | `ZTronDSP-handoff/briefs/75-librosa-oracles.md`, with `60-common-rules-main-tree.md` |
| Date | 2026-11-22, 16:10 to 17:53 (Europe/Rome) |
| Tree | the main tree, branch `handover-chain`. The work of this brief is `git diff 64ffc6f` plus the untracked files (brief 60, note of 17:10). Commit `f829550` holds seven of its files (section 4) |
| Oracles | librosa 0.11.0, NumPy 2.2.6, SciPy 1.15.3 (with the SciPy stand-ins of `_oracle.py`), Python 3.10.12 |

**What the brief got done.**

- Every vector of the seven spectral generators is librosa 0.11.0's output now, every argument explicit, with these exceptions (table of 2.2):
  - the constant-Q transform and the pseudo constant-Q. For those two the definition's vector stays the tested one, and librosa's chroma is written beside it and held by the cosine of §6.8;
  - the constant-Q kernel, which no librosa function returns;
  - the cepstra and the FFT, which keep the oracles STG-2 names for them: NumPy from the definitions (the cepstra computed on librosa's spectrum), and `numpy.fft`.
- Before anything is written, each generator holds its NumPy definition to librosa's output. Every stand-in agreed with librosa within 9.6·10⁻¹⁵ of the largest value. No float64 vector moved by more than that; the two float32 tempograms moved by one float32 step in values under 4.2·10⁻⁷. No package defect was found, no tolerance changed, and no known failure was added.
- Two statements of the brief are wrong (section 2.3):
  - the cosine bound is §6.8's, not §6.10's;
  - §6.9's autocorrelation tempogram is not `librosa.feature.tempogram`.
- One change request: CR-035, the reference chroma of the pseudo constant-Q.

## 1. Files

The paths are relative to the package. "Committed in f829550" marks a file whose change was taken into that commit (section 4). Some of those files were changed again afterwards.

**Added**

- `Docs/Process/changes/CR-035.md`
- `Docs/Process/reports/impl-librosa-oracles.md` (this report)
- `Tests/Fixtures/Golden/generators/needs_librosa.py`, `Tests/Fixtures/Golden/generators/cross_check_fails.py` (committed in f829550)
- `Tests/ZTronDSPAnalysisTests/Golden/`: eight vectors of librosa's chroma:
  - `constant_q_music-defaults_librosa_chroma.f64`
  - `constant_q_music-top-octave_librosa_chroma.f64`
  - `constant_q_music-variable-q_librosa_chroma.f64`
  - `constant_q_speech-semitones_librosa_chroma.f64`
  - `constant_q_pseudo_music-semitones_librosa_chroma.f64`
  - `constant_q_pseudo_music-semitones_librosa_chroma_as_is.f64`
  - `constant_q_pseudo_speech-thirds-of-semitones_librosa_chroma.f64`
  - `constant_q_pseudo_speech-thirds-of-semitones_librosa_chroma_as_is.f64`

**Changed**

- The runner:
  - `Scripts/lib/golden_runner.py` (committed in f829550, changed after)
  - `Scripts/tests/test-golden.sh` (committed in f829550, changed after)
  - `Scripts/golden.sh` (header comment)
  - `Tests/Fixtures/Golden/README.md` (committed in f829550)
- The helpers of the generators:
  - `Tests/Golden/generators/_oracle.py` (committed in f829550)
  - `Tests/Golden/generators/_golden.py` (committed in f829550, changed after)
  - `_spectral.py`, `_rhythm.py`, `_separation.py` (docstrings)
- The generators: `spectral_transforms.py`, `mel.py`, `cepstrum.py`, `onset_strength.py`, `hpss.py`, `tempogram.py`, `constant_q.py`, and `requirements.txt`, all in `Tests/Golden/generators/`.
- `Tests/Golden/manifest.json`.
- The vectors in `Tests/ZTronDSPAnalysisTests/Golden/`:
  - STFT and FFT: `stft.json`, `stft_real.f64`, `stft_imaginary.f64`, `fft.json`.
  - Mel: `mel.json`, `mel_bank_default-22050-2048-128.f64`, `mel_bank_slaney-16000-512-26-range.f64`, `mel_bank_slaney-48000-240-12-peak.f64`, `mel_spectrogram_music.f64`, `mel_spectrogram_speech.f64`.
  - Cepstrum and MFCC: `cepstrum.json`; `mfcc_music_*.f64` and `mfcc_speech_*.f64` for `40_13`, `64_20`, `128_128` and `26_26` (eight files).
  - Rhythm and separation: `onset_strength.json`, `hpss.json`, `tempogram.json`, `tempogram_music-autocorrelation-64-hann-30-300-causal.f32`, `tempogram_music-autocorrelation-64-hann-30-300-centred.f32`.
  - Constant-Q: `constant_q.json`.
- The Swift tests: `Tests/ZTronDSPAnalysisTests/ChromaTests.swift` and `Tests/ZTronDSPAnalysisTests/ConstantQScaleTests.swift` (one test each).
- The records:
  - `.github/workflows/ci.yml` (a comment in gate-7-golden)
  - `Docs/Release/0.1.0-checklist.md` (the row `golden-reproduce`)
  - `Docs/Numerics/onset-strength.md`, `Docs/Numerics/separation-masks.md`, `Docs/Numerics/tempogram.md` (each one's *References* sentence)

**Deleted:** none.

**Production code:** no file under `Sources/` changed. `git diff --quiet 64ffc6f -- Sources/` holds. The public API is unchanged.

**Outside the tree:** `ZTronDSP-handoff/agent-states/librosa-notes.md`.

## 2. The items of the brief

### 2.1 Loading (Design 1)

**What the code does now.**

- `_oracle.load_librosa()` puts the SciPy stand-ins in place (`load()`), then imports librosa and returns the module. Where librosa is missing it raises `ModuleNotFoundError: No module named 'librosa'`, which is the runner's existing pending path.
- `_oracle.versions()` names librosa only when the process loaded it. So only the vector files of the librosa generators record it.
- `_oracle.installed()` is what the runner reads. It gives NumPy, SciPy and librosa as a generator loads them, and `None` for librosa when its own import is missing. Any other import error is raised, which refuses the run.
- `_golden.librosa()` is a generator's only way to librosa. No generator writes `import librosa`.
- `_golden.cross_check(what, oracle, definition, bound)` takes the largest absolute difference relative to the oracle's largest absolute value.
  - Above `bound` it stops the generator, before anything is written. It prints both numbers and both values at the worst element.
  - Otherwise it prints a `cross-check …` line, which the runner shows under the generator's name.
- The runner (`ORACLES = numpy, scipy, librosa`) requires all three to be pinned and reads them through `_oracle.installed()`. The result:
  - a librosa of another version refuses the run (exit 2);
  - so does a librosa that is installed but cannot be loaded;
  - where librosa is not installed, the oracles line says `librosa not installed`, and its generators are recorded as pending, or skipped with their committed vectors kept.

**Tests.** `Scripts/tests/test-golden.sh` gained 30 checks. They:

- give a fake librosa 0.0.1 and a broken librosa, first on `PYTHONPATH`, and expect a refusal of `--only`, of the whole run and of `--reproduce`;
- expect a missing librosa to leave `needs_librosa` pending, with the strict check failing on it;
- expect the run to refuse when the librosa pin is removed;
- run `needs_librosa` with the real librosa: it runs, cross-checks, records `"librosa":"0.11.0"` (a generator that does not load librosa does not record it), reproduces bit for bit, and is skipped loudly without librosa;
- run `cross_check_fails`, which must stop the generator with `At (2,): oracle 3.0, definition 3.0000000030000002` and write no vector.

Final run: `159 checks, 0 failed` (17:16–17:18). It runs again inside `Scripts/tests/run-all.sh` (section 3).

**What failed without the change.** The runner of `64ffc6f` read a pin other than NumPy's and SciPy's from the installed distribution's metadata (0.11.0), not from the module a generator loads. With the fake librosa 0.0.1 first on `PYTHONPATH` it therefore ran, and exited 1 with an `AttributeError` inside `needs_librosa`. The new runner refuses with exit 2: `librosa 0.0.1 is installed and 0.11.0 is pinned`.

### 2.2 The quantities and their forms (Design 2)

Every librosa call was checked against the installed 0.11.0 signatures (`ast` over the generators, then `inspect.signature`, 17:20). Every parameter is passed, and no keyword goes into `**kwargs`. Some arguments librosa does not read, because it is given a spectrum or a curve: `sr`, `mel_norm`, `hop_length`. They are passed anyway, and the docstrings say so.

The check found one call that left two flags at their defaults: `librosa.util.frame` in `tempogram.py`, with `writeable` and `subok`. Neither changes a value; both are now passed. All inputs are float64, and every librosa call computes in double precision, with `dtype` given wherever librosa has one. So every cross-check bound is 10⁻¹². The measured value is the largest over the cases.

The fixtures' rate is 22 050 Hz. Every vector below is read by `ZTronDSPAnalysisTests`.

| Quantity, vector | librosa 0.11.0, every argument | Form | Cross-check: bound; measured | Read by (package): tolerance |
|---|---|---|---|---|
| STFT frames, `stft.json` (`stft_real/imaginary.f64`) | `librosa.stft(y=x, n_fft=M, hop_length=hop, win_length=M, window=w, center=centred, dtype=numpy.complex128, pad_mode="reflect", out=None)`, transposed. `w` is the window's name (periodic) when M = N. A zero-padded frame takes the array `[get_window(name, N, fftbins=True), M − N zeros]`, with x extended by M − N zeros. The normalisation, 2/Σw or √(2/(M·Σw²)), is applied to librosa's output. Of the centred frames, the stream's: k ≤ (len − N/2)/hop | oracle | 10⁻¹²; 2.9·10⁻¹⁶ (15 framings) | `STFTTests.theFramesEqualTheGoldenVectors` (WP-504): 10⁻⁵ of the frame maximum |
| Hertz to mel, `mel.json` `formulas` | `librosa.hz_to_mel(frequencies=f, htk=False)`, `librosa.hz_to_mel(frequencies=f, htk=True)` | oracle | 10⁻¹²; 2.9·10⁻¹⁷ | `MelTests.theConversionsRoundTripAndEqualTheReference` (WP-508): 10⁻¹² relative |
| Mel filter bank, `mel.json` `bank-*` (`mel_bank_*.f64`) | `librosa.filters.mel(sr=rate, n_fft=length, n_mels=bands, fmin=…, fmax=…, htk=…, norm="slaney" or None, dtype=numpy.float64)`; its edges from `librosa.mel_frequencies(n_mels=bands + 2, fmin=…, fmax=…, htk=…)`. Five banks | oracle | 10⁻¹²; weights 9.6·10⁻¹⁵, edges 7.2·10⁻¹⁶ | `MelTests.theWeightsEqualTheReferenceFilterBank` (WP-508): 10⁻⁶ |
| Mel power spectrogram, `mel.json` `spectrogram-*` (`mel_spectrogram_*.f64`) | `librosa.feature.melspectrogram(y=x, sr=22050.0, S=None, n_fft=2048, hop_length=512, win_length=2048, window="hann", center=True, pad_mode="reflect", power=2.0, n_mels=128, fmin=0.0, fmax=11025.0, htk=False, norm="slaney", dtype=numpy.float64)`, the stream's frames | oracle | 10⁻¹²; 1.8·10⁻¹⁵ | `MelTests.theMelPowerSpectrogramOfTheFixturesEqualsTheReference` (WP-535): 10⁻⁴ of the frame maximum |
| MFCC, `cepstrum.json` `mfcc-*` (`mfcc_*.f64`) | `librosa.feature.mfcc(y=None, sr=22050.0, S=librosa.power_to_db(S=M, ref=1.0, amin=1e-16, top_db=None), n_mfcc=count, dct_type=2, norm="ortho", lifter=0, mel_norm="slaney")`. M is the spectrogram of the row above with `n_mels=bands`. (bands, count) = (40, 13), (64, 20), (128, 128), (26, 26) | oracle (`power_to_db` with these arguments is the package's 10·log10(max(p, 10⁻¹⁶))) | 10⁻¹²; 9.2·10⁻¹⁶ | `CepstralCoefficientTests.theCoefficientsEqualTheGoldenVectors` (WP-512): 10⁻³ |
| Real and power cepstrum, `cepstrum.json` `cepstrum-*` | STG-2 names "NumPy from the definitions": irfft(ln max(\|X\|, 10⁻¹⁰)) and irfft(ln max(\|X\|², 10⁻¹⁰))². X is `librosa.stft(y=x, n_fft=1024, hop_length=512, win_length=1024, window="hann", center=False, dtype=numpy.complex128, pad_mode="reflect", out=None)` | definition, on librosa's spectrum (oracle form for X) | 10⁻¹² for X; 0 | `CepstrumTests.theRealAndThePowerCepstrumEqualTheGoldenVectors` (WP-509): 10⁻⁴ of the frame maximum |
| Onset strength, `onset_strength.json` | M from `melspectrogram` as above, with (frame, hop, bands, center) = (2048, 512, 128, True) for music and (1024, 256, 64, False) for speech. Then `librosa.onset.onset_strength(y=None, sr=22050.0, S=numpy.maximum(librosa.power_to_db(S=M, ref=1.0, amin=1e-16, top_db=None), floor), lag=lag, max_size=max_size, ref=None, detrend=False, center=False, feature=None, aggregate=numpy.mean)`. Eight cases | oracle, the conversion written out: STG-2's "same floor" is the specification's floor applied to librosa's decibels; "no clipping" is `top_db=None` | 10⁻¹²; 7.6·10⁻¹⁶ | `OnsetStrengthTests.theOnsetStrengthOfTheFixturesEqualsTheReference` (WP-525): 10⁻³ of the largest value. `theFixturesReachUnderTheFloor` reads the cases' `flooredShare` |
| HPSS masks, `hpss.json` | S = \|`librosa.stft(y=x, n_fft=1024, hop_length=hop, win_length=1024, window="hann", center=True, dtype=numpy.complex128, pad_mode="reflect", out=None)`\|, the stream's frames. Then `librosa.decompose.hpss(S, kernel_size=(time, frequency), power=p or numpy.inf, mask=True, margin=(h, p))`. Four cases | oracle. The specification's floor rule is asserted not to apply: the smallest larger median is about 0.006, against a floor of 10⁻¹⁰ | 10⁻¹²; 0 | `SeparationMaskTests.theMasksOfTheFixturesEqualTheReference` (WP-530): soft within 10⁻³, hard on 99.9 % |
| Autocorrelation tempogram, `tempogram.json` (and the two `.f32`) | Per window, s = the window minus its mean (from `librosa.util.frame(c, frame_length=W, hop_length=1, axis=-1, writeable=False, subok=False)`; centred: c padded with librosa's linear ramp). Then `librosa.util.normalize(librosa.feature.tempogram(y=None, sr=22050.0, onset_envelope=s, hop_length=hop, win_length=W, center=False, window=taper, norm=None), norm=numpy.inf, axis=0, threshold=1e-10, fill=False)` | oracle, the mean removal of §6.9 being the conversion | 10⁻¹²; 7.2·10⁻¹⁶ (11 cases of both kinds, and their tempi; the Fourier cases 0) | `TempogramTests.theTempogramOfACurveEqualsTheReference`, `theTempogramOfTheMusicFixtureEqualsTheReference` (WP-526, WP-527): cosine ≥ 0.99 |
| Fourier tempogram, the same files | `numpy.abs(librosa.feature.fourier_tempogram(y=None, sr=22050.0, onset_envelope=[s, L − W zeros], hop_length=hop, win_length=L, center=False, window=[librosa.filters.get_window(taper, W, fftbins=True), L − W zeros]))` | oracle, the same conversion | as above | as above |
| The music chain's novelty curve, `tempogram.json` `music` | `melspectrogram` (1024, 256, 64 bands, centred), then `onset_strength` as above with lag 1, max_size 1, floor −80 dB | oracle | 10⁻¹²; 4.3·10⁻¹⁶ | `TempogramTests.theTempogramOfTheMusicFixtureEqualsTheReference` |
| Constant-Q geometry, `constant_q.json` `geometry-*` | `librosa.cqt_frequencies(n_bins=octaves·B, fmin=fmin, bins_per_octave=B, tuning=tuning)`, and the ceiling of `librosa.filters.wavelet_lengths(freqs=f, sr=fs, window="hann", filter_scale=…, gamma=γ, alpha=numpy.full(n, 2^(1/B) − 1))[0]`. `alpha` is given because librosa's default is its relative bandwidth | oracle | 10⁻¹²; 6.7·10⁻¹⁶ and 2.6·10⁻¹⁶; lengths equal | `ConstantQGeometryTests.frequenciesAndAtomLengthsMatchTheDefinitions` (WP-517): 10⁻¹² relative, lengths equal |
| Constant-Q kernel, `constant_q.json` `kernel-*` | none: no librosa function returns the spectral kernel of §6.8's atoms (`librosa.filters.constant_q` builds librosa's own) | definition (Brown & Puckette). The transform it serves has librosa's chroma beside it | — | `ConstantQKernelTests` (WP-518, WP-520): 10⁻⁶ of the row's largest entry |
| Constant-Q transform, `constant_q.json` `transform-*` | The definition's X is the tested vector. Beside it, `librosaChroma` = `librosa.feature.chroma_cqt(y=None, sr=22050.0, C=numpy.abs(V), hop_length=hop, fmin=fmin·2^(tuning/B), norm=numpy.inf, threshold=0.0, tuning=tuning, n_chroma=12, n_octaves=octaves, window=None, bins_per_octave=B, cqt_mode="full")`, with V = `librosa.cqt(y=x, sr=22050.0, hop_length=hop, fmin=fmin, n_bins=octaves·B, bins_per_octave=B, tuning=tuning, filter_scale=…, norm=1, sparsity=0.01, window="hann", scale=True, pad_mode="constant", res_type="soxr_hq", dtype=numpy.complex128)`. For γ > 0, `librosa.vqt` with `intervals="equal", gamma=γ` and the rest the same | derived | the definition's chroma against librosa's, ≥ 0.98 on music, asserted in the generator: 0.9898, 0.9974, 0.9887. Speech 0.9691, recorded | `ConstantQTests.theTransformOfTheFixturesIsThatOfTheDefinition` (WP-521, WP-522a): the definition. New: `ChromaTests.theChromaOfTheMusicFixturesIsThatOfLibrosa` (WP-524): cosine ≥ 0.98 |
| Chroma fold, `constant_q.json` `chroma`, `chromaSums` | `librosa.feature.chroma_cqt` with the arguments above, of the definition's \|X\|; `norm=numpy.inf`, and `norm=None` for the sums | oracle | 10⁻¹²; 0 | `ChromaTests.theChromaOfTheFixturesIsThatOfTheReference` (WP-524): cosine ≥ 0.98, sums 0.01 |
| Pseudo constant-Q, `constant_q.json` `pseudo-*` | The definition's C is the tested vector. Its S is `librosa.stft(…, center=False, …)`, held to the definition with measured deviation 0. Beside it, `chroma_cqt` as above of \|`librosa.pseudo_cqt(y=x, sr=22050.0, hop_length=512, fmin=fmin, n_bins=octaves·B, bins_per_octave=B, tuning=tuning, filter_scale=…, norm=1, sparsity=0.01, window="hann", scale=True, pad_mode="constant", dtype=numpy.complex128)`\|, on the frames centred on the definition's centres (four frames later). It is written twice: as is (`librosaChromaAsIs`), and with librosa's band scale ℓ_k/n_fft^1.5 removed (`librosaChroma`) | derived; CR-035 | the definition's chroma: music 0.9998 removed, 0.9630 as is; speech 1.0000 and 0.9473, recorded | `ConstantQScaleTests.thePseudoConstantQOfTheFixturesEqualsTheDenseProjection` (WP-523): 10⁻⁵, the definition. New: `theChromaOfThePseudoConstantQIsThatOfLibrosa`: cosine ≥ 0.98 on CR-035's reading |
| FFT, `fft.json` | not librosa: `numpy.fft.rfft` / `irfft`, as STG-2's WP-502 row says | NumPy oracle | — | `TransformTests.theTransformEqualsTheGoldenVectors` (WP-502). Rewritten only in its `oracle` block: `spectral_transforms.py` loads librosa, so the file records it |

**Why the two exceptions are derived.** No factor per bin turns librosa's constant-Q into §6.8's. librosa differs in several ways:

- its relative bandwidth, (2^(2/B) − 1)/(2^(2/B) + 1) against 2^(1/B) − 1, makes its atoms 0.2 to 3 % longer (35 022.7 samples against 34 683 at the bottom of music-defaults; 3 % at 12 bins per octave; 0.2 % at the bottom of music-variable-q, where γ dominates);
- it builds them of 2⌊ℓ/2⌋ + 1 samples, L1-normalises them and multiplies them by ℓ/n_fft, then divides by √ℓ (`scale=True`);
- it resamples between octaves (soxr) and sparsifies.

The median ratio per bin is about √N_k / 2: 91.9 against 93.6, and 8.30 against 8.35, at the two ends of music-defaults. Even with each bin divided by its own median ratio, the least frame-wise cosine of the magnitudes stays at 0.9995 (music-defaults), 0.9989 (speech-semitones), 0.9976 (music-variable-q) and 0.9942 (music-top-octave), against 0.940, 0.938, 0.951 and 0.987 without the division (the exploration script `e3_cqt.py`, outside the tree, run again at 17:28). So there is a close relation, not an exact one. The pseudo constant-Q's chroma cannot meet 0.98 as librosa scales it, for a reason that is the specification's own amplitude convention: CR-035.

### 2.3 Every discrepancy between a stand-in and librosa, and what became of it

1. **The oracle-form quantities: none.** The cross-checks above measure 0 to 9.6·10⁻¹⁵ of the largest value. The committed float64 vectors moved by at most that, relative to their own largest value (stand-in vectors of `64ffc6f` against librosa's):

   | Vector | Largest deviation |
   |---|---|
   | `mel_bank_default-22050-2048-128.f64` | 9.6·10⁻¹⁵ |
   | the other mel banks | 2.8·10⁻¹⁵ and 8.8·10⁻¹⁶ |
   | mel spectrograms | 1.8·10⁻¹⁵ and 1.6·10⁻¹⁵ |
   | MFCC | ≤ 9.2·10⁻¹⁶ |
   | STFT | 1.5·10⁻¹⁷ |
   | onset curves | ≤ 7.6·10⁻¹⁶ |
   | the music chain's novelty curve (`tempogram.json`) | 4.3·10⁻¹⁶ |
   | mel band edges | ≤ 7.2·10⁻¹⁶ |
   | Hertz to mel (Slaney's scale; HTK's unchanged) | 2.9·10⁻¹⁷ |
   | constant-Q frequencies (the three tuned cases) | ≤ 6.7·10⁻¹⁶ |
   | the music fixture's two tempograms (`tempogram_music-*.f32`, float32) | 85 of 4 968 and 112 of 6 440 values differ, each by one float32 step: all are below 4.2·10⁻⁷, so at most 2.8·10⁻¹⁴ absolute, 8.1·10⁻¹⁴ of the largest value |

   Unchanged in their values: the cepstra, the HPSS masks, the chroma folds, the kernels, the FFT. So no Swift parity test failed against librosa's vectors, and no defect of a package was found.
2. **The conventions that only an explicit argument removes**, all handled in the calls:
   - librosa 0.11's `stft` pads centred frames with zeros by default (`pad_mode="constant"`); the specification reflects.
   - `filters.mel` computes in float32 by default.
   - `win_length < n_fft` centres the window in the frame, while the package's zero-padding puts it at the start: hence the window array.
   - librosa's centred `stft` has 1 + len/hop frames, where a stream has only the first (len − N/2)/hop + 1.
   - `onset_strength(center=True)` shifts the curve by half a frame.
   - `power_to_db`'s `amin` would shift every value by a floor above 0 dB, so the floor is applied with `numpy.maximum`.
   - HPSS: librosa's tiny-number rule replaces the specification's floor of 10⁻¹⁰ where both medians vanish. It is asserted not to occur.
3. **The tempogram.** The brief lists "the autocorrelation tempogram" among the quantities that are the same function as librosa's. That is wrong.
   - §6.9 removes each window's mean before it is tapered; `librosa.feature.tempogram` does not. Between the two readings the least frame-wise cosine is 0.31 and 0.41 (384, Hann, centred and causal) and −0.93 (101, Hamming, centred) on the curve fixture.
   - The package's own step shows the same: under mutation m10, which removes the mean removal, the Swift tests printed 0.3077, 0.4095 and −0.9295, and −0.9534 on the music fixture.
   - `librosa.feature.fourier_tempogram(center=True)` would lead in with zeros, its STFT padding, where the package's step leads in with the linear ramp. In the first W/2 frames the cosine is 0.556.
   - What became of it: the oracle form, with the conversion written out. librosa's own tempogram is called on each mean-removed window; the centred lead-in is `librosa.feature.tempogram`'s ramp for both kinds. No change request: the specification names no librosa tempogram.
4. **The constant-Q transform:** derived form, see the end of 2.2. On the music fixtures librosa's chroma meets 0.98 against the definition's and against the package's (2.5). Speech measures 0.9691; §6.8 asks for the bound on the music fixtures only.

   On music-defaults librosa warns `n_fft=1024 is too large for input signal of length=690`. The fixtures last two seconds, and its lowest octave, decimated six times, is shorter than librosa's frame, so it pads with zeros. Those values are librosa's as it computes them; the chroma still meets the bound.
5. **The pseudo constant-Q:** librosa's band scale ℓ_k/n_fft^1.5 against bands of unit response. Its chroma as librosa scales it measures 0.9630 (music) and 0.9473 (speech); with the scale removed, 0.9998 and 1.0000. A rejected alternative, `chroma_cqt` of the full `librosa.cqt`, measures 0.8746 and 0.8560. What became of it: CR-035 (Proposed), and the test on its reading.
6. **The brief's "§6.10"** for the cosine bound of the constant-Q chroma is §6.8. §6.10 is the separation.

### 2.4 Regeneration (Design 3)

- **The whole run (16:53–16:54):** `golden: manifest written: 207 files of 29 generators, 0 pending`, exit 0.
- **Fix of 17:20.** My own docstrings in `mel.py`, `cepstrum.py`, `onset_strength.py`, `tempogram.py` and `constant_q.py` wrote `sr=48000` (and `fmax=24000.0`). The calls pass the fixtures' rate, 22 050 Hz, and its Nyquist frequency. The docstrings are corrected, and `librosa.util.frame` now passes `writeable` and `subok`. The five generators were run again (`--only`, 17:21:33: `manifest written: 207 files of 29 generators, 0 pending`). Every vector's SHA-256 is identical to the one before.
- **The checks:**
  - `Scripts/golden.sh --check` (17:23:02): `golden: 207 files of 29 generators match the manifest`, exit 0.
  - `--check --strict` (17:24:35): the same, exit 0.
  - `--reproduce` twice in a row (17:23:03 and 17:23:30): all 29 generators `reproduces its committed files bit for bit` both times, exit 0. So numba's compilation on first use changes nothing.
- **`requirements.txt`** pins numpy 2.2.6, scipy 1.15.3 and librosa 0.11.0. It no longer says the librosa pin "has not been exercised here": it says which generators load librosa and when the vectors were made. A comment block lists, as "installed with librosa 0.11.0 on 2026-11-21, not pinned by the runner", what can move numbers:
  - numba 0.68.1 and llvmlite 0.50.0;
  - soxr 1.1.0, the only one that reaches a vector: `librosaChroma` of the transforms;
  - scikit-learn 1.7.2, soundfile 0.14.0 and audioread 3.1.0.

### 2.5 The Swift tests against the real oracle (Design 4)

**No parity test failed against librosa's vectors.** The first run of `ZTronDSPAnalysisTests` on the new vectors, Debug, 16:56–17:00: `✔ Test run with 433 tests in 41 suites passed after 144.071 seconds.` That is 431 before, plus the two new tests. The parity tests measured, against librosa's vectors:

- onset strength: within 1.6·10⁻⁷ of the largest value;
- soft masks: within 5.5·10⁻⁵; hard masks agree on 100 %;
- tempograms: least cosine 0.99999999998;
- pseudo constant-Q: within 3.1·10⁻⁷ of the frame maximum.

**Two new tests**, for the derived forms. Neither loosens anything; both use §6.8's bound.

- `ChromaTests.theChromaOfTheMusicFixturesIsThatOfLibrosa(name:)`, on music-defaults, music-variable-q and music-top-octave. The package's chroma (`ConstantQ`, `Magnitude`, `ChromaFold`) against `librosaChroma`: least frame-wise cosine ≥ 0.98. Measured 0.98985, 0.99739 and 0.99194.
- `ConstantQScaleTests.theChromaOfThePseudoConstantQIsThatOfLibrosa()`. `STFT(4096, 512)`, `Magnitude`, `ConstantQScale` and `ChromaFold` against `librosaChroma`, on CR-035's reading: ≥ 0.98, measured 0.99983. Against `librosaChromaAsIs` it measures 0.96326, printed and not held.

**Each parity test that reads a regenerated vector was seen failing under a mutation of the Swift line it guards.** One mutation per run; each `Scripts/xc.sh test ZTronDSPAnalysisTests/<Suite>` ran a nonzero count of tests (Debug, 17:12–17:16). The original bytes were always written back, and each file was checked unchanged against HEAD. Afterwards `Sources/` is identical to `64ffc6f`. The logs are `.build/logs/librosa/mutation-*.log`.

| | Swift line | Mutation | Guarded test(s), failing | What it printed |
|---|---|---|---|---|
| m01 | `Nodes/TransformPlans.swift:63` | `real[half] = imaginary[0]` → `= 0` | `TransformTests.theTransformEqualsTheGoldenVectors` (6 of 6 cases) | `deviation < 1e-5` failed |
| m02 | `Nodes/Framer.swift:119` | reflection `head[lead − position]` → `[lead − position − 1]` | `STFTTests.theFramesEqualTheGoldenVectors` (the centred cases) | `worst < 1e-5` failed, `16-centered` … |
| m03 | `ZTronDSPCore/Units/MelFormula.swift:27` | Slaney `log(6.4) / 27.0` → `/ 27.5` | `MelTests.theConversionsRoundTripAndEqualTheReference` | the comparison with `slaney` failed |
| m04 | `Mel/MelFilterBank.swift:121` | rising slope over `center − lower` → over `upper − lower` | `MelTests.theWeightsEqualTheReferenceFilterBank` (5 of 5) | 5 023 issues |
| m05 | `Nodes/SpectralValueNode.swift:30` | `vDSP_zvmags` → `vDSP_zvabs` (power as magnitude) | `MelTests.theMelPowerSpectrogramOfTheFixturesEqualsTheReference` (alone in its suite) | 127 issues |
| m06 | `Nodes/CepstrumNodes.swift:55` | `half = 0.5` → `1.0` | `CepstrumTests.theRealAndThePowerCepstrumEqualTheGoldenVectors` | 127 issues |
| m07 | `Nodes/CepstralCoefficientNodes.swift:47` | `result[0] *= √½` → `*= 1` | `CepstralCoefficientTests.theCoefficientsEqualTheGoldenVectors` | 254 issues |
| m08 | `Nodes/OnsetStrengthNode.swift:48` | `low = floor` → `-Float.infinity` | `OnsetStrengthTests.theOnsetStrengthOfTheFixturesEqualsTheReference` (5 of 8: those with frames under the floor) | e.g. `music-lag3-max5-floor10: off by 28.84 of the largest value` |
| m09 | `Separation/MaskStrategy.swift:88` | `vDSP_vsq` → `vDSP_vabs` (soft power 2 read as 1) | `SeparationMaskTests.theMasksOfTheFixturesEqualTheReference` (both power-2 cases) | `soft masks within 0.1501` (tolerance 1e-3) |
| m10 | `Nodes/TempogramNodes.swift:69` | `offset = -mean` → `0 * mean` (librosa's convention) | `TempogramTests.theTempogramOfACurveEqualsTheReference`, `theTempogramOfTheMusicFixtureEqualsTheReference` | cosines 0.3077, 0.4095, −0.9295; music −0.9534 |
| m11 | `ConstantQ/ConstantQGeometry.swift:122` | tuning dropped from fₖ | `ConstantQGeometryTests.frequenciesAndAtomLengthsMatchTheDefinitions` (the tuned cases) | 18 issues |
| m12 | `ConstantQ/ConstantQKernel.swift:124` | atom phase from its start, not its centre | `ConstantQKernelTests.theSparseKernelIsTheDenseKernelWhereItKeepsIt`, `withoutSparsityTheKernelIsTheDenseKernelOverTheBandItReads` | `worstEntry <= 1e-6`, `worst <= 1e-6` failed |
| m13 | `Nodes/ConstantQNodes.swift:84` | `sumImaginary += a·y + b·x` → `a·y − b·x` | `ConstantQTests.theTransformOfTheFixturesIsThatOfTheDefinition` | `thinned <= 0.01` failed |
| m14 | `Steps/ChromaFold.swift:179` | first pitch class + 1 | `ChromaTests.theChromaOfTheFixturesIsThatOfTheReference`, `theChromaOfTheMusicFixturesIsThatOfLibrosa` | librosa cosines 0.2215, 0.6480, 0.2669 |
| m15 | `ConstantQ/ConstantQProjection.swift:56` | band gain 1 → ℓ_k / n_fft (librosa's scale) | `ConstantQScaleTests.thePseudoConstantQOfTheFixturesEqualsTheDenseProjection`, `theChromaOfThePseudoConstantQIsThatOfLibrosa` | 0.96887 against CR-035's reading; 0.99978 against librosa as is |

The paths are under `Sources/ZTronDSPAnalysis/` unless they name their target. Every run also failed other tests of the suite; the logs list them. `OnsetStrengthTests.theFixturesReachUnderTheFloor` reads only the golden file's `flooredShare`, so no Swift line is under it. It guards the vectors: a grid in which nothing lies under the floor would make it fail.

**Known failures:** none added; `withKnownIssue` is not used by this work, and nothing was added to `open-defects.md`, because no defect was found. The three known issues of `ZTronDSPTestingTests` are older than this brief and unchanged. They are the `withKnownIssue` blocks at `AllocationAuditTests.swift:124`, `ClosenessTests.swift:78` and `PipelineAuditTests.swift:92`, which test that a failure is reported; the log records them one line further down.

**Coverage (COV-3).** No production file changed. The two Swift files changed are tests, which the coverage gate leaves outside its denominator (COV-4), and the Python and shell files are not measured.

### 2.6 Records (Design 5)

- **Docstrings.** Every generator and helper says which form it uses and the exact call. `grep` finds no "librosa is not installed" left; the remaining mentions describe the pending path.
- **Ledger.** `grep -i librosa Docs/Process/ledger.md` finds nothing, so there was no backlog note to remove; no status changed. Five reports mention the NumPy references of their time: `WP-504-A`, `WP-512-A`, `WP-525-A`, `WP-525-B` and `audit-m5a-A`. They do so in their acceptance tables and CR lists, not in an open-item list. They are records of past verifications and were not edited.
- **`.github/workflows/ci.yml`.** The step `python3 -m pip install --quiet -r Tests/Golden/generators/requirements.txt` already installs the pinned librosa before `Scripts/golden.sh --reproduce`. A comment in gate-7-golden now says so, and says what pip brings with librosa, unpinned. I cannot run the workflow here.
- **`Docs/Release/0.1.0-checklist.md`.** The row `golden-reproduce` names librosa 0.11.0 as the oracle of the seven generators. Without it those seven are `SKIPPED`.
- **`Docs/Numerics/`.** The *References* sentences of `onset-strength.md`, `separation-masks.md` and `tempogram.md` name librosa's calls.

## 3. Gates and test totals

**The gates of brief 60**, run one after the other by a script outside the tree, on the final tree. The disk was read before each (33 to 29 GiB free). Logs: `.build/logs/librosa/gate-*.log`; summary: `gates-summary.txt`.

| Gate | Time | Exit | Final line(s), exact |
|---|---|---|---|
| `Scripts/lint-bans.sh` | 17:24:48–17:24:53 | 0 | `lint-bans: clean (parts 1, 2, 3, 4; 609 files)` |
| `Scripts/check-dependency-graph.sh` | 17:24:53–17:24:55 | 0 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | 17:24:55–17:25:48 | 0 | `api-digest: 10 digests equal the built modules`, …, `api-digest: ZTronDSPUI references public symbols only`. No `--update`: no public symbol was added, changed or removed |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 17:25:48–17:26:03 | 0 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 17:26:03–17:26:08 | 0 | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | 17:26:08–17:26:09 | 0 | `golden: 207 files of 29 generators match the manifest`, then `golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)` |
| `Scripts/golden.sh --check --strict` | 17:26:09 | 0 | the same two lines |
| `Scripts/check-function-effects.sh` | 17:26:09–17:28:05 | 0 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | 17:28:05 | 0 | `ledger: 293 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | 17:28:05–17:39:45 | 0 | `run-all: every self-test passed (1267 checks in 17 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | 17:39:45–17:41:46 | 0 | `external-parity: passed` |

- **run-all**, per suite: spec-crosscheck 29, process-files 67, check-registers 45, lint-bans 44, check-dependency-graph 32, coverage-gate 44, matlab-check 94, golden 159, compile-fixtures 22, order-matrix 36, api-digest 68, docs 56, benchmarks 37, ci 189, workflow 24, external-parity 152, release-check 169; each `0 failed`.
  - The two skips are the suites' own, without `--slow`: `gate 1 with a real build and a seeded warning` (ci), and `the parity tests on the simulator with a seeded violation` (external-parity).
- **external-parity**, per step: rules, guide, build, test, fixtures, release, audits and speed `passed`.
  - The test step: `116 tests passed; 1 expectations are known to fail and did` (`AllocationAuditTests.swift:42`, the probe that must count an allocating stage). The audits step: 19 tests and 1 such expectation, then 1 test alone in its process.
  - The speed step: 3 tests passed. Its known issue is `theGainAgainstTheStockGain()`, the gain written as a `SampleProcessor`, as CR-025 item 1 records. This launch printed `ExternalGain against stock Gain: ×1.059 round by round`.
- **The generators' own checks**, besides the gates (section 2.4):
  - `Scripts/golden.sh --reproduce`, twice (17:23:03 and 17:23:30): `golden: <generator> reproduces its committed files bit for bit` for each of the 29 generators, exit 0.
  - `Scripts/tests/test-golden.sh` (17:16–17:18): `159 checks, 0 failed`. It also ran inside `run-all`.

**Totals.** Every test target, `Scripts/xc.sh test` and `ZTD_CONFIG=Release Scripts/xc.sh test`, on `ztdsp-27` (iOS 27.0). The disk was read before each run: 35 GiB free before the first, 30 GiB before each of the last two. "Before" is the tree of `64ffc6f`, before any vector changed; "after" is the final tree, after the gates.

| Target | Before: Debug (16:31–16:37) and Release (16:38–16:42) | After: Debug (17:42–17:47) | After: Release (17:47–17:51) |
|---|---|---|---|
| `ZTronDSPUITests` | 278 | 278 | 278 |
| `ZTronDSPTests` | 20 | 20 | 20 |
| `ZTronDSPTestingTests` | 55, with 3 known issues | 55, with 3 known issues | 55, with 3 known issues |
| `ZTronDSPMetalTests` | 118 | 118 | 118 |
| `ZTronDSPIOTests` | 134 | 134 | 134 |
| `ZTronDSPDesignTests` | 339 | 339 | 339 |
| `ZTronDSPCoreTests` | 511 | 511 | 511 |
| `ZTronDSPAnalysisTests` | 431 | 433 | 433 |
| `CZTronDSPTests` | 232 | 232 | 232 |
| **All, passed** | **2 118** | **2 120** | **2 120** |

- The two tests added are `ChromaTests.theChromaOfTheMusicFixturesIsThatOfLibrosa(name:)` and `ConstantQScaleTests.theChromaOfThePseudoConstantQIsThatOfLibrosa()`. A parameterised test counts once.
- Each run's target was read from the suites its run started, against the `@Suite` names of each test directory (script outside the tree). The baseline's logs keep only the summary lines. Their nine runs come in the same order with the same counts, Analysis's excepted, so they are attributed by position.
- The exact final lines of the runs after:
  - Debug: `✔ Test run with 433 tests in 41 suites passed after 170.754 seconds.` (Analysis) and `━ Test run with 55 tests in 8 suites passed after 0.198 seconds with 3 known issues.` (Testing). The seven other runs end `passed`. Then `** TEST EXECUTE SUCCEEDED **`, exit 0.
  - Release: `✔ Test run with 433 tests in 41 suites passed after 11.918 seconds.` and `━ Test run with 55 tests in 8 suites passed after 0.045 seconds with 3 known issues.` The seven other runs end `passed`. Then `** TEST EXECUTE SUCCEEDED **`, exit 0.
  - The logs: `.build/logs/librosa/final-debug.log` and `final-release.log`, and xcodebuild's full logs beside them (`-full.log`).
- **Known failures:** none. No test failed in any run, and none needed a second run. The three known issues are the ones of section 2.5, unchanged since before the brief, in Debug and in Release alike. Within the gates, external-parity's known issues are the ones its script names (section 3, above).

## 4. Open items

- **Commit `f829550`.** "Added more test fixtures", 16:39:03, under the repository's git user, with no body. It holds seven files of this brief's unfinished work: `Scripts/lib/golden_runner.py`, `Scripts/tests/test-golden.sh`, `Tests/Fixtures/Golden/README.md`, `Tests/Fixtures/Golden/generators/cross_check_fails.py`, `Tests/Fixtures/Golden/generators/needs_librosa.py`, `Tests/Golden/generators/_golden.py` and `Tests/Golden/generators/_oracle.py`. I did not commit. It is recorded in the notes and here, and not judged (brief 60). The work of this brief is `git diff 64ffc6f` plus the untracked files.
- **CI.** I cannot run the workflow.
  - pip on the runner resolves librosa's dependencies itself. A soxr other than 1.1.0 could move `librosaChroma` of the four transform cases, the only vectors resampled by soxr. Then `--reproduce` would fail for `constant_q` alone. Whether to pin soxr, numba and llvmlite there is the owner's call (section 5).
  - The SciPy stand-ins of `_oracle.load()` are what this host needs. On a runner whose SciPy imports normally they are not exercised here.
- **CR-035 is Proposed.** `ConstantQScaleTests.theChromaOfThePseudoConstantQIsThatOfLibrosa` runs on its reading. If the owner decides otherwise, the test and `constant_q.py` are reworked.
- **CR-007, CR-019, CR-022 and CR-023** describe the NumPy references that stood in for librosa (item 2, item 2, item 9 and item 3). Brief 75 replaced them. They are not edited: their status is the owner's. CR-035's "Related" says so.
- **One observation, not a defect.** `AutocorrelationTempogramTransform` gives zeros when the value at lag 0 does not exceed the floor (`energy > floor`). §6.9 says "below the floor", and librosa's `normalize(threshold=…)` agrees with §6.9. The two differ only at exact equality. Under a floor of 0 the package's reading is the one that keeps 0/0 out (NUM-1). No fixture comes near it.
- **The simulators.** `ztdsp-27` was shut down when my first test run began (listing of 16:31:41). `Scripts/xc.sh` booted it for my runs (its current boot began at 16:38:44, with the Release baseline). It stays booted: brief 60 asks that any *other* `ztdsp-*` simulator be shut down, and I booted no other. Two "iPhone 16 Pro" simulators were booted beside it, by another project: one of iOS 18.0 from 16:55:27, and one of iOS 18.2 from 17:36:33, which that project's `xcodebuild test` used from 17:42. Neither is a `ztdsp-*` simulator and I booted neither, so both were left alone; `ztdsp-27` was the only simulator my runs booted.

## 5. Change requests and decisions asked of the owner

- **CR-035 (Proposed).** The reference chroma of §6.8 for `ConstantQScale`: `librosa.feature.chroma_cqt` of `librosa.pseudo_cqt` with librosa's band scale ℓ_k/n_fft^(3/2) removed. Measured 0.9998 (generator) and 0.99983 (package), against 0.9630 and 0.96326 as librosa scales it. The full transform meets §6.8 against `librosa.cqt` as written. No tolerance changes. Decision asked: accept the proposed reading, or name another.
- **Decision asked.** Should the CI's generator environment pin librosa's dependencies too: soxr 1.1.0, numba 0.68.1 and llvmlite 0.50.0? Brief 75 asked only that they be recorded, which `requirements.txt` does. Without a pin, a new soxr can make gate 7's reproduce step fail on `constant_q`.

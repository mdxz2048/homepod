# External acoustic probe sources

These files are downloaded measurement signals. HomePod Flow does not synthesize
the probe waveform at runtime. Playback and analysis load the same bundled WAV.

## Logarithmic and linear sweeps

- Source: https://github.com/willfehlmusic/Useful-Audio-Signals
- Files: `LogSineSweepNew.wav`, `LinSineSweepNew.wav`,
  `LogSineSweepNewInverse.wav`
- License: MIT, Copyright (c) 2018 William Fehlhaber
- Original format: mono, 44.1 kHz, 1.0 s. The logarithmic sweep covers about
  20 Hz to 18.05 kHz; the inverse WAV is the matching precomputed filter.
- Local names: `log-sweep-44100.wav`, `linear-sweep-44100.wav`,
  `log-sweep-inverse-44100.wav`.
- The 48 kHz variants were produced from the originals with Apple `afconvert`.
  They are separate shipped files so playback and analysis never depend on a
  platform-specific runtime resampler.

## Pink noise

- Source: https://commons.wikimedia.org/wiki/File:Pink.Noise.ogg
- Author: Bautsch (original uploader on German Wikipedia)
- License: public domain
- Original format: mono, 44 kHz, 10.0 s.
- HomePod Flow takes six one-second excerpts at 1.0, 2.5, 4.0, 5.5, 7.0
  and 8.5 s, concatenates them, and ships 44.1/48 kHz WAV conversions. This is
  the only modification; no noise is synthesized.

## Runtime formatting

All probes are peak-normalized to -6 dBFS by the player/analyzer and receive a
10 ms cosine taper at each one-second segment boundary. The same taper and
normalization are applied in Swift and Python. Segment repetition and insertion
of silent gaps happen after loading the external file.

SHA-256:

```
4a7d79855613155d053b0a2ce6d30a834f3b61cad2ce60350667fcf6e8eb0804  linear-sweep-44100.wav
1323fb32a0472919bada616832c53c0c1c512924ad9382a9ac0f0b631851cb6b  linear-sweep-48000.wav
0c8f8e9508b98c8ebea59812a801363d67ea34464a084088a5512a4b6e26086e  log-sweep-44100.wav
83d0e2d9a2dba5879c37b937504b1646911771d9ccb1dfe08904872ae8fad736  log-sweep-48000.wav
835bf4304feeafd09ea12cd7ca37f5e3db936ae29707aa96c20533e6d32138fe  log-sweep-inverse-44100.wav
84983cf4b5a72f093f0c09b145bb8d4c7421031a4dc0f79937aa73811ec938c4  log-sweep-inverse-48000.wav
c53984c74fb6afc4fb99e14d5a6f9a5a104b2524f7a94bd4ceae206029aabafc  pink-noise-44100.wav
400d677f608fde77a1a0bd307bfb1aafb15a7dc50e5293bd47f17bbdcffdd7a1  pink-noise-48000.wav
```

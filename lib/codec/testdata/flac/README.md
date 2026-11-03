# FLAC test vectors

These files are cut and patched copies of files from the IETF CELLAR FLAC decoder testbench.

- Source: https://github.com/ietf-wg-cellar/flac-test-files
- Commit: `aa7b0c6cf32994c106ae517a08134c28a96ff5b2`
- License: CC0 1.0 (the testbench README states it, copyright and related rights are waived). The author of the testbench is Martijn van Beurden.

## What was changed

The originals are up to 87 MB. Every file here keeps the metadata blocks and a few whole frames of its source file, so each file shows its feature in 1 to 50 KB. A one-off tool, which is not part of this repository, found the frame boundaries with the sync code, the CRC-8 of the header and the CRC-16 of the whole frame, and copied whole frames only. The column "Source" gives the original file and the range of frames kept, as `first:count`.

- PADDING blocks longer than 64 bytes were cut to 64 zero bytes.
- In the `s`, `u` files the STREAMINFO total sample count was set to 0 (unknown) and the MD5 to 16 zero bytes (unset). The sizes in STREAMINFO are not changed. The seek tables are not changed, so their offsets can point past the end of the cut file.
- The `f` files (faulty) are not patched. Their STREAMINFO is as in the source, so the MD5 in them does not match the cut data. `f11` is the first 330 bytes of the source file.

## How the expected results were made

The expected samples come from the flac 1.5.0 command line decoder run on each cut file:

    flac -d --force-raw-format --endian=little --sign=signed -o out.raw cut.flac

The MD5 of `out.raw` is the hash in the table. This is the layout that the FLAC MD5 is defined on: signed, little endian, interleaved, ceil(bits/8) bytes per sample. The reference decoder writes raw output only for 8, 16, 24 and 32 bit. For the 12, 15 and 20 bit files the decoder wrote a WAVE file, in which it shifts the samples left to fill the container. The shift was undone before the hash (the same procedure on the uncut source files gives the MD5 stored in their STREAMINFO). The reference decoder was used to make this table only. The tests do not run it.

For the `u01` to `u04` files the expected values are the ones of the frames before the property change, taken from the reference decoder on a copy with only those frames. The reference decoder stops with an error at the change, as the decoder in this repository does (error.BadData).

The tests check that the decoder returns exactly these frame counts and hashes with different read sizes, that f32 output equals the integer scaled by 2^(bits-1), and that seeking gives the same samples as a full decode.

## Files

| File | Source | Bytes | Stream | Covers | Expected |
|---|---|---|---|---|---|
| `s01-blocksize-4096.flac` | subset/01 - blocksize 4096, frames 0:6 | 30362 | 44100 Hz, 2 ch, 16 bit | Block size 4096, fixed blocking. All four stereo modes appear later in the source, here INDEPENDENT and MID_SIDE. Seek table with one point, vorbis comment, padding. LPC orders 1 to 12 in the first frames. Used for the seek table test. | 24576 frames, MD5 `cbb1785e7dfb70808257ef014969f118` |
| `s02-blocksize-4608.flac` | subset/02 - blocksize 4608, frames 0:2 | 16322 | 44100 Hz, 2 ch, 16 bit | Block size 4608 (code 5). Used for the CRC-16 tests and for seeking to the end. | 9216 frames, MD5 `5015a8af1742cd1daa2e2b1b8fdd865b` |
| `s03-blocksize-16.flac` | subset/03 - blocksize 16, frames 0:20 | 1163 | 44100 Hz, 2 ch, 16 bit | Block size 16, the smallest legal size. All four stereo modes, fixed orders 1 to 4, LPC orders 1 and 2, partition orders 0 to 2. | 320 frames, MD5 `5f643261e46abae848e313658b6dd03c` |
| `s03b-short-last-frame.flac` | subset/03 - blocksize 16, frames 19290:4 | 351 | 44100 Hz, 2 ch, 16 bit | The last three full frames and the short last frame (12 samples) of the block size 16 stream. A short block is legal as the last block. | 60 frames, MD5 `42bb68e38ac87e3241150664a299c852` |
| `s04-blocksize-192.flac` | subset/04 - blocksize 192, frames 0:4 | 1414 | 44100 Hz, 2 ch, 16 bit | Block size 192 (code 1), MID_SIDE. | 768 frames, MD5 `20963a2d332605ce8f2a167f53b515c7` |
| `s05-blocksize-254.flac` | subset/05 - blocksize 254, frames 0:4 | 2165 | 44100 Hz, 2 ch, 16 bit | Block size 254 (8 bit field). | 1016 frames, MD5 `6bdde9b7338a8600dbdbaab6cefc4262` |
| `s06-blocksize-512.flac` | subset/06 - blocksize 512, frames 0:3 | 2824 | 44100 Hz, 2 ch, 16 bit | Block size 512 (code 9). | 1536 frames, MD5 `e75f6f8cd55b23156898143301808241` |
| `s07-blocksize-725.flac` | subset/07 - blocksize 725, frames 0:3 | 4300 | 44100 Hz, 2 ch, 16 bit | Block size 725 (16 bit field). | 2175 frames, MD5 `f993fd73c7e63c25a7b30709896742f2` |
| `s09-blocksize-1937.flac` | subset/09 - blocksize 1937, frames 0:2 | 6884 | 44100 Hz, 2 ch, 16 bit | Block size 1937 (16 bit field). | 3874 frames, MD5 `558f7196bdd973c48146b4ed4cc6205f` |
| `s10-blocksize-2304.flac` | subset/10 - blocksize 2304, frames 0:2 | 7712 | 44100 Hz, 2 ch, 16 bit | Block size 2304 (code 4). | 4608 frames, MD5 `c96e987ba37b5de7d4d0833c2ef3a436` |
| `s11-partition-order-8.flac` | subset/11 - partition order 8, frames 0:1 | 2583 | 44100 Hz, 2 ch, 16 bit | Rice partition order 8, fixed orders 0 and 1. | 4096 frames, MD5 `66ba7833ca483f715c036a6f5f567eae` |
| `s12-qlp-precision-15.flac` | subset/12 - qlp precision 15 bit, frames 0:1 | 11418 | 44100 Hz, 2 ch, 16 bit | LPC coefficient precision 15 bit. | 4608 frames, MD5 `e547be51ba889d9b44357972ce11af08` |
| `s13-qlp-precision-2.flac` | subset/13 - qlp precision 2 bit, frames 0:1 | 13303 | 44100 Hz, 2 ch, 16 bit | LPC coefficient precision 2 bit, partition order 7 and 8. | 4608 frames, MD5 `0cd23f6d6ca90cd68f136c30d786cafb` |
| `s14-wasted-bits.flac` | subset/14 - wasted bits, frames 0:4 | 2259 | 44100 Hz, 2 ch, 16 bit | Subframes with wasted bits, RIGHT_SIDE and LEFT_SIDE. | 2048 frames, MD5 `6bbfc071ac1d29e47eeadfd68278178d` |
| `s15-verbatim.flac` | subset/15 - only verbatim subframes, frames 0:1 | 16570 | 44100 Hz, 2 ch, 16 bit | Only VERBATIM subframes. | 4096 frames, MD5 `15aae50d8e1b00a612c344ee6c76fdf7` |
| `s16-rice-escape.flac` | subset/16 - partition order 8 containing escaped partitions, frames 0:1 | 10348 | 44100 Hz, 2 ch, 16 bit | Rice escape codes inside partition order 8. | 4096 frames, MD5 `70ac1516e43bd605faa0bce143b13f71` |
| `s17-fixed-orders.flac` | subset/17 - all fixed orders, frames 0:5 | 17736 | 44100 Hz, 2 ch, 16 bit | Fixed predictor orders 0 to 4, block size 1152 (code 3), LEFT_SIDE, RIGHT_SIDE, MID_SIDE. | 5760 frames, MD5 `40ddf015d217aa51f114060b8f4de5da` |
| `s18-precision-search.flac` | subset/18 - precision search, frames 0:3 | 28174 | 44100 Hz, 2 ch, 16 bit | Several LPC coefficient precisions, LPC orders up to 12, MID_SIDE and RIGHT_SIDE. | 12288 frames, MD5 `dc20f888cc074de02722907f004c0dee` |
| `s19-rate-35467.flac` | subset/19 - samplerate 35467Hz, frames 0:1 | 10541 | 35467 Hz, 2 ch, 16 bit | Sample rate 35467 Hz (16 bit Hz field). | 4096 frames, MD5 `0a7da27e545560d0020ec8c124d83b31` |
| `s20-rate-39000.flac` | subset/20 - samplerate 39kHz, frames 0:1 | 10480 | 39000 Hz, 2 ch, 16 bit | Sample rate 39000 Hz (8 bit kHz field). | 4096 frames, MD5 `17a78dfb14ffee1a479aeb8781954ef7` |
| `s21-rate-22050.flac` | subset/21 - samplerate 22050Hz, frames 0:1 | 10970 | 22050 Hz, 2 ch, 16 bit | Sample rate 22050 Hz. | 4096 frames, MD5 `382e2a34fe7d51a59904058b8b3f32b3` |
| `s22-bps-12.flac` | subset/22 - 12 bit per sample, frames 0:2 | 11942 | 44100 Hz, 2 ch, 12 bit | 12 bit samples, MID_SIDE (13 bit side channel). | 8192 frames, MD5 `3639e05b4831e5a545e5cf6afb51d07b` |
| `s23-bps-8.flac` | subset/23 - 8 bit per sample, frames 0:3 | 8279 | 44100 Hz, 2 ch, 8 bit | 8 bit samples. | 12288 frames, MD5 `ff602f3785673f0625d639598f691eaa` |
| `s24-variable-flake.flac` | subset/24 - variable blocksize file created with flake revision 264, frames 0:8 | 15646 | 44100 Hz, 2 ch, 16 bit | Variable block size (flag set, block sizes 2048 and 4096 among others), sample numbers in the frame headers. Contains a CONSTANT subframe. | 18432 frames, MD5 `5286f53ba5de05c52f73808576ff3d31` |
| `s25-variable-small-blocks.flac` | subset/25 - variable blocksize file created with flake revision 264, modified to create smaller blocks, frames 0:60 | 36018 | 44100 Hz, 2 ch, 16 bit | Variable block size with many different small sizes in 60 frames. No seek table, used for the bisection seek test. | 16960 frames, MD5 `e80f85c24fec828716386119aa553fa9` |
| `s26-variable-cuetools.flac` | subset/26 - variable blocksize file created with CUETools.Flake 2.1.6, frames 0:3 | 26340 | 44100 Hz, 2 ch, 16 bit | Variable block size (flag set) from a second encoder. | 12288 frames, MD5 `4bb25e6682dab713099a38cfbdab6aaf` |
| `s27-variable-old-format.flac` | subset/27 - old format variable blocksize file created with Flake 0.11, frames 0:6 | 38593 | 44100 Hz, 2 ch, 16 bit | Old style variable blocking: the fixed flag is set but STREAMINFO has min != max, so the frame numbers are sample numbers. Used for the bisection seek test. | 18432 frames, MD5 `1e9b376e4dcda16a2f223d8e48e81dbe` |
| `s28-hires-96k-24bit.flac` | subset/28 - high resolution audio, default settings, frames 0:1 | 16826 | 96000 Hz, 2 ch, 24 bit | 96 kHz, 24 bit, Rice method 2 (5 bit parameters). | 4096 frames, MD5 `d09b71ade4d31c8e77b5acb0588cb466` |
| `s31-lpc-order-32.flac` | subset/31 - high resolution audio, using only 32nd order predictors, frames 0:1 | 34731 | 96000 Hz, 2 ch, 24 bit | LPC order 32 (the only file with an order above 12), 24 bit. | 8192 frames, MD5 `11c34a92c4339e38d47b68132b03bf6e` |
| `s33-rate-192000.flac` | subset/33 - samplerate 192kHz, frames 0:1 | 17595 | 192000 Hz, 2 ch, 24 bit | 192 kHz (code 3), 24 bit. | 4096 frames, MD5 `de6617c81dcf365215e8bbe6c07cad16` |
| `s35-rate-134560.flac` | subset/35 - samplerate 134560Hz, frames 0:1 | 17342 | 134560 Hz, 2 ch, 24 bit | 134560 Hz (code 14, tens of Hz). | 4096 frames, MD5 `bd78cceb906ade8d5eb8518a5b910068` |
| `s38-channels-3.flac` | subset/38 - 3 channels (3.0), frames 0:14 | 27944 | 44100 Hz, 3 ch, 16 bit | 3 channels, CONSTANT subframes, partition orders 0 to 6. No seek table, used for the bisection seek test. | 57344 frames, MD5 `f998c43afab3207a495fce831b498278` |
| `s39-channels-4.flac` | subset/39 - 4 channels (4.0), frames 0:4 | 166 | 44100 Hz, 4 ch, 16 bit | 4 channels (constant subframes). | 16384 frames, MD5 `0dfbe8aa4c20b52e1b8bf3cb6cbdf193` |
| `s40-channels-5.flac` | subset/40 - 5 channels (5.0), frames 0:4 | 10834 | 44100 Hz, 5 ch, 16 bit | 5 channels. | 16384 frames, MD5 `95a7a1b2218167ba6fa90f181f132eb5` |
| `s41-channels-6.flac` | subset/41 - 6 channels (5.1), frames 0:4 | 10846 | 44100 Hz, 6 ch, 16 bit | 6 channels. | 16384 frames, MD5 `c3e766ef56b26016233a0a43246474df` |
| `s42-channels-7.flac` | subset/42 - 7 channels (6.1), frames 0:4 | 10858 | 44100 Hz, 7 ch, 16 bit | 7 channels. | 16384 frames, MD5 `d44591d49d6e0f6dd283f3f33af31749` |
| `s43-channels-8.flac` | subset/43 - 8 channels (7.1), frames 0:4 | 10870 | 44100 Hz, 8 ch, 16 bit | 8 channels. | 16384 frames, MD5 `fc24a70351aadd94be628d23b1fc8afd` |
| `s46-no-frame-sizes.flac` | subset/46 - no min-max framesize set, frames 0:2 | 12746 | 48000 Hz, 2 ch, 16 bit | STREAMINFO min and max frame size are 0 (unknown). | 8192 frames, MD5 `748f30a27f6565fa0e9bf36e5f80b946` |
| `s47-only-streaminfo.flac` | subset/47 - only STREAMINFO, frames 0:2 | 11866 | 48000 Hz, 2 ch, 16 bit | A stream with no other metadata block. | 8192 frames, MD5 `ac1a33282ced78b119f83dca35c5f5d7` |
| `s60-mono.flac` | subset/60 - mono audio, frames 0:3 | 212 | 44100 Hz, 1 ch, 16 bit | 1 channel, CONSTANT subframes, seek table, padding. | 12288 frames, MD5 `91ff0dac5df86e798bfef5e573536b08` |
| `s61-overflow-16bit.flac` | subset/61 - predictor overflow check, 16-bit, frames 0:10 | 7626 | 44100 Hz, 1 ch, 16 bit | Signal that overflows a 32 bit predictor sum, 16 bit. | 40960 frames, MD5 `3e8dcf896edb9d009a38cc1708ed2081` |
| `s62-overflow-20bit.flac` | subset/62 - predictor overflow check, 20-bit, frames 0:10 | 13429 | 44100 Hz, 1 ch, 20 bit | Same, 20 bit, Rice method 2. | 40960 frames, MD5 `933e258e9341c037250f136e798bb4b9` |
| `s63-overflow-24bit.flac` | subset/63 - predictor overflow check, 24-bit, frames 0:10 | 11408 | 44100 Hz, 1 ch, 24 bit | Same, 24 bit, Rice method 2. | 40960 frames, MD5 `322d261fd8c3de8b4725c1f88be0f8b5` |
| `s64-rice-escape-zero.flac` | subset/64 - rice partitions with escape code zero, frames 0:2 | 2751 | 44100 Hz, 1 ch, 16 bit | Rice escape code with 0 raw bits. | 8192 frames, MD5 `e4e64afaffcc6bea290104d8cbe186b6` |
| `u01-changing-rate.flac` | uncommon/01 - changing samplerate, frames 39:2 | 17289 | 32000 Hz, 2 ch, 16 bit | One frame at 32 kHz, then a frame at 24 kHz. The property change is an error. | 4096 frames, then BadData. MD5 of those frames `0628754d321376cacce412f7a4e77a62` |
| `u02-increasing-channels.flac` | uncommon/02 - increasing number of channels, frames 35:2 | 182 | 44100 Hz, 1 ch, 16 bit | Mono frames, then a stereo frame. The channel change is an error. | 4096 frames, then BadData. MD5 of those frames `0829f71740aab1ab98b33eae21dee122` |
| `u03-decreasing-channels.flac` | uncommon/03 - decreasing number of channels, frames 43:3 | 1789 | 44100 Hz, 4 ch, 16 bit | One 4 channel frame, then 2 channel frames. The channel change is an error. | 4096 frames, then BadData. MD5 of those frames `3e51b62abbfba4632b958a6cb47fcb78` |
| `u04-changing-bitdepth.flac` | uncommon/04 - changing bitdepth, frames 33:2 | 1223 | 44100 Hz, 1 ch, 16 bit | A 16 bit frame, then an 8 bit frame. The bit depth change is an error. | 4096 frames, then BadData. MD5 of those frames `bb4ee677048b6d88a84b736c34a29079` |
| `u05a-bps-32-mid-side.flac` | uncommon/05 - 32bps audio, frames 4:1 | 20341 | 44100 Hz, 2 ch, 32 bit | 32 bit samples, MID_SIDE (33 bit side channel). | 4096 frames, MD5 `1f388a81db9209e4d61e05dfffbe993f` |
| `u05b-bps-32-left-side.flac` | uncommon/05 - 32bps audio, frames 11:1 | 21843 | 44100 Hz, 2 ch, 32 bit | 32 bit samples, LEFT_SIDE (33 bit side channel). | 4096 frames, MD5 `d77a9c8a83f78aefd58d976fb34fd6a8` |
| `u05c-bps-32-right-side.flac` | uncommon/05 - 32bps audio, frames 107:1 | 24591 | 44100 Hz, 2 ch, 32 bit | 32 bit samples, RIGHT_SIDE (33 bit side channel). | 4096 frames, MD5 `6d18355a9c111b3dcfbbd0e9d4e9052a` |
| `u06-rate-768000.flac` | uncommon/06 - samplerate 768kHz, frames 0:1 | 3312 | 768000 Hz, 2 ch, 24 bit | 768 kHz, which no frame header code can express (rate from STREAMINFO). | 4096 frames, MD5 `70233711551a87f334e201fe5d4893db` |
| `u07a-bps-15.flac` | uncommon/07 - 15 bit per sample, frames 0:1 | 3405 | 44100 Hz, 2 ch, 15 bit | 15 bit samples (sample size code 0, depth from STREAMINFO). Seek table whose second point is past the end of the data. | 4096 frames, MD5 `b7ce959b0fc08311fd99ca847dafffc9` |
| `u07b-bps-15-mid-side.flac` | uncommon/07 - 15 bit per sample, frames 8:1 | 6134 | 44100 Hz, 2 ch, 15 bit | 15 bit samples, MID_SIDE. | 4096 frames, MD5 `7f06edf69f6b3f3d05b5c455269ee285` |
| `u09-rice-order-15.flac` | uncommon/09 - Rice partition order 15, frames 2:1 | 49531 | 24000 Hz, 1 ch, 16 bit | Rice partition order 15 with block size 32768 (code 15). | 32768 frames, MD5 `6f23572b500f4c5b5cc1d3294ad8e207` |

## Files without a hash

The faulty files, and the two files that do not start with the `fLaC` marker. The reference decoder output is the one of flac 1.5.0 on the cut file. For `f01`, `f02`, `f05` and `f09` the reference decoder finds no error in the frames. It reports only the MD5 mismatch, which is caused by the cutting. By default the decoder here also decodes them and counts the problem in `Decoder.stats()`. With `Options.strict_metadata` it gives an error.

| File | Source | Fault and where it is | Reference decoder | Expected result here |
|---|---|---|---|---|
| `f01-wrong-max-blocksize.flac` | faulty/01, frames 0:1 | STREAMINFO max block size is 4096, the first frame has 16384 samples | MD5 mismatch only | read gives BadData, no frames |
| `f02-wrong-max-framesize.flac` | faulty/02, frames 0:8 | STREAMINFO max frame size is 654 bytes, frame 3 is larger | MD5 mismatch only | 36864 frames with oversized frames counted, then Truncated (the cut file keeps the total of the source). With `strict_metadata`: 13824 frames, then BadData |
| `f03-wrong-bit-depth.flac` | faulty/03, frames 0:3 | STREAMINFO says 24 bit, the frames say 16 | "bits-per-sample is 16 in frame starting at sample 0 but 24 in STREAMINFO" | read gives BadData, no frames |
| `f04-wrong-channels.flac` | faulty/04, frames 0:3 | STREAMINFO says 5 channels, the frames have 1 | "channels is 1 in frame starting at sample 0 but 5 in STREAMINFO" | read gives BadData, no frames |
| `f05-wrong-total-samples.flac` | faulty/05, frames 0:10 | STREAMINFO says 39842 samples, the data has more | MD5 mismatch only | 40960 frames, 1118 samples past the total counted, md5Matches false. With `strict_metadata`: 36864 frames, then BadData |
| `f06-missing-streaminfo.flac` | faulty/06, frames 0:1 | The first metadata block is a vorbis comment, STREAMINFO is missing | metadata error BAD_METADATA, then decodes the frames | init gives BadHeader |
| `f07-streaminfo-not-first.flac` | faulty/07, frames 0:1 | STREAMINFO is the third metadata block | metadata error BAD_METADATA | init gives BadHeader |
| `f09-blocksize-1.flac` | faulty/09, frames 0:4 | All blocks have 1 sample, STREAMINFO min block size is 1 | MD5 mismatch only | init gives BadHeader |
| `f10-invalid-vorbis-comment.flac` | faulty/10, frames 0:1 | The vorbis comment states 10 comments and has 1 | metadata error BAD_METADATA | init gives BadHeader |
| `f11-bad-metadata-length.flac` | faulty/11, first 330 bytes | The block after the vorbis comment has type 127 (forbidden) because the length of the block before it is wrong | "ERROR_STATUS_BAD_METADATA after processing 0 samples" | init gives BadHeader |
| `u10-no-marker.flac` | uncommon/10, frames 0:3 | The file starts at a frame header, there is no `fLaC` marker and no metadata | "does not appear to be a FLAC file", then decodes the frames without STREAMINFO | init gives Unsupported |
| `u11-garbage-prefix.flac` | uncommon/11, 895 bytes of garbage and frames 0:3 | Unparsable data before the first frame header | "does not appear to be a FLAC file", then lost sync | init gives Unsupported |

`faulty/08` (block size 65536) is not included because its frames are 43 KB each. The tests build a frame header with that block size instead. `uncommon/08` (block size 65535) is not included for the same reason (104 KB per frame), and the tests build a frame with that size.

## Coverage

| Feature | File |
|---|---|
| Fixed blocking | s01, s02, s03, s04 to s10 |
| Variable blocking (flag set) | s24, s25, s26 |
| Variable blocking (old format, frame header flag clear and STREAMINFO min != max) | s27 |
| Block sizes 16, 192, 254, 512, 725, 1152, 1937, 2304, 4096, 4608, 32768 | s03, s04, s05, s06, s07, s17, s09, s10, s01, s02, u09 |
| Short last block | s03b |
| Sample rates 22050, 32000, 35467, 39000, 44100, 48000, 96000, 134560, 192000, 768000 | s21, u01, s19, s20, s01, s46, s28, s35, s33, u06 |
| Sample rate 24000 | u09 |
| Bit depths 8, 12, 15, 16, 20, 24, 32 | s23, s22, u07a, s01, s62, s63, u05a |
| 1 to 8 channels | s60, s01, s38, s39, s40, s41, s42, s43 |
| Stereo modes | INDEPENDENT s01, LEFT_SIDE s03, RIGHT_SIDE s03, MID_SIDE s01 |
| Stereo modes at 32 bit (33 bit side channel) | u05a, u05b, u05c |
| Wasted bits | s14 |
| CONSTANT, VERBATIM | s38, s15 |
| Fixed orders 0 to 4 | s17 |
| LPC orders 1 to 12 | s01, s02, s05, s09 and others |
| LPC order 32 | s31 |
| Rice escape codes, escape with 0 bits | s16, s64 |
| Partition orders 0 to 8, 15 | s01 to s38, s11, u09 |
| Rice method with 5 bit parameters | s28, s62, s63 |
| LPC precisions 2, 6 to 13 and 15 | s13, s18, s12 |
| Seek table, padding, vorbis comment | s01 (one point), u07a (second point past the end), s60 |
| Streams without a seek table | s25, s27, s38, s47 |
| STREAMINFO without frame sizes, with only STREAMINFO | s46, s47 |
| Predictor overflow signals | s61, s62, s63 |
| Property changes in the stream | u01 (rate), u02 and u03 (channels), u04 (bit depth) |

Not found in any vendored file, and tested with frames built inside the test code instead: LPC orders 13 to 31 (the testbench only has orders up to 12 and 32), Rice partition orders 9 to 14, block size 65535 and the rejected size 65536, the block size codes 1024 and 16384 and the sample rate codes for 8000, 16000, 88200 and 176400, the 32 bit left, right and mid side frames with extreme values, a short block that is not the last one, and metadata blocks of type APPLICATION, CUESHEET, PICTURE and reserved types (the smallest PICTURE file in the testbench has 73 KB of metadata, and it is skipped by length like the other types).

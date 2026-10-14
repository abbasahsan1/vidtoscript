# ECAPA-TDNN speaker embedder

`ECAPA_TDNN.mlmodelc` is the Core ML conversion published by
[`enzolabs/ecapa-tdnn-coreml`](https://huggingface.co/enzolabs/ecapa-tdnn-coreml).

The model is a conversion of SpeechBrain's `spkrec-ecapa-voxceleb` speaker
embedding model.  The upstream conversion and the underlying speaker model are
licensed under Apache-2.0.  The runtime contract used by this app is:

`Float16[1, 80, frames] log-mel filterbanks -> Float16[1, 192] embedding`.
The app generates the standard Hann window and HTK triangular mel filterbank
at runtime, so the model has no sidecar frontend-resource dependency.

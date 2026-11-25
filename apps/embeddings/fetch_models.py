"""Run once while the image is built: puts the models' files into the folder named by HF_HOME.

The access key for DINOv3 is read here from the environment and never written on a command line, so it is not
printed in the build log. It is used in a build stage of its own whose layers are not part of the final image.
"""
import os

from huggingface_hub import snapshot_download

snapshot_download(os.environ["SIGLIP_MODEL"], allow_patterns=["*.json", "*.safetensors", "*.model", "*.txt"])
print("SigLIP 2 files are in the image")
key = os.environ.get("HF_TOKEN", "").strip()
if key:
    # a refusal by the model's page stops the build, so a missing access is seen at once
    snapshot_download(os.environ["DINO_MODEL"], token=key, allow_patterns=["*.json", "*.safetensors"])
    print("DINOv3 files are in the image")
else:
    print("DINOv3 is not installed: no access key at build")

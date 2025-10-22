#!/usr/bin/env python3
"""
DeepSeek R1 Distill Llama 8B to Core ML Converter

This script converts the DeepSeek-R1-Distill-Llama-8B model to Core ML format
for use on iOS devices.

Requirements:
    pip install coremltools torch transformers huggingface_hub accelerate

Usage:
    python convert_deepseek_to_coreml.py [--quantize] [--output-dir ./models]
"""

import argparse
import os
import sys
from pathlib import Path

try:
    import torch
    import coremltools as ct
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from huggingface_hub import snapshot_download
except ImportError as e:
    print(f"Error: Missing required package: {e}")
    print("\nPlease install required packages:")
    print("pip install coremltools torch transformers huggingface_hub accelerate")
    sys.exit(1)

# Model configuration
MODEL_ID = "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
MAX_LENGTH = 2048  # Maximum sequence length
BATCH_SIZE = 1


class DeepSeekCoreMLConverter:
    """Converter for DeepSeek models to Core ML format."""

    def __init__(self, model_id: str, output_dir: str, quantize: bool = True):
        self.model_id = model_id
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.quantize = quantize

    def download_model(self):
        """Download the model from Hugging Face."""
        print(f"📥 Downloading {self.model_id}...")
        print("This may take a while (model is ~15GB)...")

        try:
            model_path = snapshot_download(
                repo_id=self.model_id,
                allow_patterns=["*.json", "*.bin", "*.model", "*.safetensors"],
                cache_dir=self.output_dir / "cache"
            )
            print(f"✅ Model downloaded to: {model_path}")
            return model_path
        except Exception as e:
            print(f"❌ Error downloading model: {e}")
            raise

    def load_pytorch_model(self, model_path: str):
        """Load the PyTorch model."""
        print("\n🔧 Loading PyTorch model...")

        try:
            # Load tokenizer
            tokenizer = AutoTokenizer.from_pretrained(
                model_path,
                trust_remote_code=True
            )

            # Load model with 4-bit quantization for memory efficiency
            model = AutoModelForCausalLM.from_pretrained(
                model_path,
                torch_dtype=torch.float16,
                device_map="auto",
                low_cpu_mem_usage=True,
                trust_remote_code=True
            )

            model.eval()
            print("✅ Model loaded successfully")
            return model, tokenizer

        except Exception as e:
            print(f"❌ Error loading model: {e}")
            raise

    def trace_model(self, model, tokenizer):
        """Trace the model for Core ML conversion."""
        print("\n📝 Tracing model...")

        try:
            # Create example input
            example_text = "Hello, how can I help you?"
            inputs = tokenizer(
                example_text,
                return_tensors="pt",
                max_length=MAX_LENGTH,
                padding="max_length",
                truncation=True
            )

            # Get input IDs
            input_ids = inputs["input_ids"]

            # Trace the model
            with torch.no_grad():
                traced_model = torch.jit.trace(
                    model,
                    (input_ids,),
                    strict=False
                )

            print("✅ Model traced successfully")
            return traced_model, input_ids

        except Exception as e:
            print(f"❌ Error tracing model: {e}")
            print("\nNote: Some models may not support tracing.")
            print("Try using torch.jit.script instead or use the alternative method.")
            raise

    def convert_to_coreml(self, traced_model, example_input):
        """Convert traced model to Core ML."""
        print("\n🔄 Converting to Core ML...")
        print("This may take 10-30 minutes...")

        try:
            # Define input type
            input_shape = ct.Shape(shape=(BATCH_SIZE, MAX_LENGTH))

            # Convert to Core ML
            coreml_model = ct.convert(
                traced_model,
                inputs=[ct.TensorType(name="input_ids", shape=input_shape, dtype=int)],
                minimum_deployment_target=ct.target.iOS17,
                compute_units=ct.ComputeUnit.ALL,  # Use CPU, GPU, and ANE
            )

            # Add metadata
            coreml_model.user_defined_metadata["model_name"] = "DeepSeek-R1-Distill-Llama-8B"
            coreml_model.user_defined_metadata["model_type"] = "language_model"
            coreml_model.user_defined_metadata["max_length"] = str(MAX_LENGTH)

            print("✅ Conversion successful")
            return coreml_model

        except Exception as e:
            print(f"❌ Error converting to Core ML: {e}")
            raise

    def quantize_model(self, coreml_model):
        """Apply 4-bit quantization to reduce model size."""
        if not self.quantize:
            return coreml_model

        print("\n⚡ Applying 4-bit quantization...")

        try:
            # Apply weight quantization
            quantized_model = ct.compression.compress_weights(
                coreml_model,
                mode=ct.compression.CompressionMode.INT4,
            )

            print("✅ Quantization complete")
            return quantized_model

        except Exception as e:
            print(f"⚠️  Warning: Quantization failed: {e}")
            print("Continuing with unquantized model...")
            return coreml_model

    def save_model(self, coreml_model, filename="DeepSeekR1.mlpackage"):
        """Save the Core ML model."""
        output_path = self.output_dir / filename

        print(f"\n💾 Saving model to {output_path}...")

        try:
            coreml_model.save(str(output_path))
            print(f"✅ Model saved successfully")
            print(f"\n📊 Model size: {self._get_dir_size(output_path):.2f} MB")
            return output_path

        except Exception as e:
            print(f"❌ Error saving model: {e}")
            raise

    def _get_dir_size(self, path):
        """Calculate directory size in MB."""
        total = 0
        for entry in Path(path).rglob('*'):
            if entry.is_file():
                total += entry.stat().st_size
        return total / (1024 * 1024)

    def run_conversion(self):
        """Run the complete conversion pipeline."""
        print("=" * 60)
        print("DeepSeek R1 to Core ML Converter")
        print("=" * 60)

        try:
            # Step 1: Download model
            model_path = self.download_model()

            # Step 2: Load PyTorch model
            model, tokenizer = self.load_pytorch_model(model_path)

            # Step 3: Trace model
            traced_model, example_input = self.trace_model(model, tokenizer)

            # Step 4: Convert to Core ML
            coreml_model = self.convert_to_coreml(traced_model, example_input)

            # Step 5: Quantize (optional)
            coreml_model = self.quantize_model(coreml_model)

            # Step 6: Save model
            output_path = self.save_model(coreml_model)

            print("\n" + "=" * 60)
            print("✨ CONVERSION COMPLETE!")
            print("=" * 60)
            print(f"\nYour Core ML model is ready at:")
            print(f"  {output_path}")
            print("\nNext steps:")
            print("1. Transfer the .mlpackage to your iOS device")
            print("2. In CodeApp: Settings > AI Model > Load Local Model")
            print("3. Select the .mlpackage file")
            print("4. Start chatting with AI!")

            return output_path

        except Exception as e:
            print(f"\n❌ Conversion failed: {e}")
            print("\nTroubleshooting:")
            print("1. Ensure you have enough RAM (16GB+ recommended)")
            print("2. Check you have enough disk space (~20GB)")
            print("3. Try running with --no-quantize flag")
            print("4. Check the error message above for details")
            return None


def main():
    parser = argparse.ArgumentParser(
        description="Convert DeepSeek R1 Distill Llama 8B to Core ML"
    )
    parser.add_argument(
        "--output-dir",
        default="./coreml_models",
        help="Output directory for the converted model"
    )
    parser.add_argument(
        "--no-quantize",
        action="store_true",
        help="Disable 4-bit quantization (larger but potentially more accurate)"
    )
    parser.add_argument(
        "--model-id",
        default=MODEL_ID,
        help="Hugging Face model ID to convert"
    )

    args = parser.parse_args()

    # Create converter
    converter = DeepSeekCoreMLConverter(
        model_id=args.model_id,
        output_dir=args.output_dir,
        quantize=not args.no_quantize
    )

    # Run conversion
    converter.run_conversion()


if __name__ == "__main__":
    main()

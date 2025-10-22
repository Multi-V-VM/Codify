#!/usr/bin/env python3
"""
VISX Creator - Compress WASM and Node.js packages

Creates .visx (Virtual iOS Extension Package) files that bundle WASM modules,
Node.js packages, and their dependencies for remote distribution.

Format:
  - .visx is a gzipped tar archive
  - Contains a manifest.json with metadata
  - Includes all necessary files and dependencies
  - Optimized for mobile distribution (compressed)

Usage:
    python create_visx.py [OPTIONS] SOURCE_DIR OUTPUT_FILE

Examples:
    # Create VISX from WASM module
    python create_visx.py ./my-wasm-module ./output/module.visx --type wasm

    # Create VISX from Node.js package
    python create_visx.py ./my-node-package ./output/package.visx --type node

    # Create with custom metadata
    python create_visx.py ./src ./out.visx --name "MyPackage" --version "1.0.0"
"""

import argparse
import json
import os
import sys
import tarfile
import hashlib
import gzip
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional

class VISXCreator:
    """Creates .visx packages from source directories."""

    VISX_VERSION = "1.0"

    def __init__(self, source_dir: str, output_file: str, package_type: str = "auto"):
        self.source_dir = Path(source_dir).resolve()
        self.output_file = Path(output_file).resolve()
        self.package_type = package_type

        if not self.source_dir.exists():
            raise FileNotFoundError(f"Source directory not found: {source_dir}")

        # Ensure output directory exists
        self.output_file.parent.mkdir(parents=True, exist_ok=True)

    def detect_package_type(self) -> str:
        """Auto-detect package type from source directory."""
        if (self.source_dir / "package.json").exists():
            return "node"
        elif any(self.source_dir.glob("*.wasm")):
            return "wasm"
        elif any(self.source_dir.glob("*.js")):
            return "javascript"
        else:
            return "generic"

    def get_package_info(self) -> Dict:
        """Extract package information from source."""
        info = {
            "name": self.source_dir.name,
            "version": "1.0.0",
            "description": "",
            "dependencies": {}
        }

        # Try to read package.json for Node.js packages
        package_json = self.source_dir / "package.json"
        if package_json.exists():
            try:
                with open(package_json, 'r') as f:
                    pkg_data = json.load(f)
                    info["name"] = pkg_data.get("name", info["name"])
                    info["version"] = pkg_data.get("version", info["version"])
                    info["description"] = pkg_data.get("description", "")
                    info["dependencies"] = pkg_data.get("dependencies", {})
            except Exception as e:
                print(f"Warning: Could not read package.json: {e}")

        return info

    def calculate_checksum(self, file_path: Path) -> str:
        """Calculate SHA256 checksum of a file."""
        sha256 = hashlib.sha256()
        with open(file_path, 'rb') as f:
            for chunk in iter(lambda: f.read(4096), b""):
                sha256.update(chunk)
        return sha256.hexdigest()

    def get_file_list(self, exclude_patterns: Optional[List[str]] = None) -> List[Path]:
        """Get list of files to include in the archive."""
        if exclude_patterns is None:
            exclude_patterns = [
                ".git",
                ".gitignore",
                "node_modules/.cache",
                "__pycache__",
                "*.pyc",
                ".DS_Store",
                "*.visx"
            ]

        files = []
        for file_path in self.source_dir.rglob('*'):
            if file_path.is_file():
                # Check exclusions
                rel_path = file_path.relative_to(self.source_dir)
                should_exclude = any(
                    part.startswith('.') or
                    any(pat in str(rel_path) for pat in exclude_patterns)
                    for part in rel_path.parts
                )

                if not should_exclude:
                    files.append(file_path)

        return files

    def create_manifest(self, pkg_info: Dict, files: List[Path]) -> Dict:
        """Create manifest.json for the package."""
        # Calculate total size and file checksums
        total_size = 0
        file_manifest = []

        for file_path in files:
            rel_path = file_path.relative_to(self.source_dir)
            file_size = file_path.stat().st_size
            total_size += file_size

            file_manifest.append({
                "path": str(rel_path),
                "size": file_size,
                "checksum": self.calculate_checksum(file_path)
            })

        manifest = {
            "visx_version": self.VISX_VERSION,
            "package": {
                "name": pkg_info["name"],
                "version": pkg_info["version"],
                "description": pkg_info["description"],
                "type": self.package_type,
            },
            "created_at": datetime.utcnow().isoformat() + "Z",
            "stats": {
                "total_files": len(files),
                "total_size": total_size,
                "compressed_size": 0  # Will be updated after compression
            },
            "files": file_manifest,
            "dependencies": pkg_info.get("dependencies", {}),
            "metadata": {
                "platform": "ios",
                "minimum_version": "17.0",
                "requires": []
            }
        }

        return manifest

    def create_archive(self, files: List[Path], manifest: Dict) -> None:
        """Create the .visx archive."""
        print(f"📦 Creating VISX package...")
        print(f"   Source: {self.source_dir}")
        print(f"   Output: {self.output_file}")
        print(f"   Type: {self.package_type}")
        print(f"   Files: {len(files)}")

        # Create tar.gz archive
        with tarfile.open(self.output_file, 'w:gz') as tar:
            # Add manifest first
            manifest_json = json.dumps(manifest, indent=2).encode('utf-8')
            import io
            manifest_tarinfo = tarfile.TarInfo(name='manifest.json')
            manifest_tarinfo.size = len(manifest_json)
            tar.addfile(manifest_tarinfo, io.BytesIO(manifest_json))

            # Add all files
            for i, file_path in enumerate(files, 1):
                rel_path = file_path.relative_to(self.source_dir)
                arcname = str(rel_path)

                if i % 100 == 0:
                    print(f"   Adding files... {i}/{len(files)}")

                tar.add(file_path, arcname=arcname)

        # Update compressed size in manifest
        compressed_size = self.output_file.stat().st_size
        original_size = manifest["stats"]["total_size"]
        compression_ratio = (1 - compressed_size / original_size) * 100 if original_size > 0 else 0

        print(f"\n✅ Package created successfully!")
        print(f"   Original size: {self._format_size(original_size)}")
        print(f"   Compressed size: {self._format_size(compressed_size)}")
        print(f"   Compression: {compression_ratio:.1f}%")
        print(f"   Output: {self.output_file}")

    def _format_size(self, size: int) -> str:
        """Format byte size in human-readable format."""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if size < 1024.0:
                return f"{size:.2f} {unit}"
            size /= 1024.0
        return f"{size:.2f} TB"

    def create(self) -> None:
        """Main creation workflow."""
        try:
            # Detect or validate package type
            if self.package_type == "auto":
                self.package_type = self.detect_package_type()
                print(f"🔍 Auto-detected package type: {self.package_type}")

            # Get package information
            pkg_info = self.get_package_info()

            # Get file list
            files = self.get_file_list()

            if not files:
                raise ValueError("No files found in source directory")

            # Create manifest
            manifest = self.create_manifest(pkg_info, files)

            # Create archive
            self.create_archive(files, manifest)

        except Exception as e:
            print(f"\n❌ Error creating VISX package: {e}")
            if self.output_file.exists():
                self.output_file.unlink()
            raise


def main():
    parser = argparse.ArgumentParser(
        description="Create .visx packages for CodeApp",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # WASM module
  python create_visx.py ./wasm-module ./output/module.visx --type wasm

  # Node.js package
  python create_visx.py ./node-package ./output/pkg.visx --type node

  # Auto-detect
  python create_visx.py ./my-package ./output.visx
        """
    )

    parser.add_argument(
        "source",
        help="Source directory containing the package"
    )

    parser.add_argument(
        "output",
        help="Output .visx file path"
    )

    parser.add_argument(
        "--type",
        choices=["auto", "wasm", "node", "javascript", "generic"],
        default="auto",
        help="Package type (auto-detect if not specified)"
    )

    parser.add_argument(
        "--name",
        help="Override package name"
    )

    parser.add_argument(
        "--version",
        help="Override package version"
    )

    parser.add_argument(
        "--description",
        help="Package description"
    )

    args = parser.parse_args()

    # Ensure output has .visx extension
    output_path = Path(args.output)
    if output_path.suffix != '.visx':
        output_path = output_path.with_suffix('.visx')

    # Create VISX package
    creator = VISXCreator(
        source_dir=args.source,
        output_file=str(output_path),
        package_type=args.type
    )

    creator.create()


if __name__ == "__main__":
    main()

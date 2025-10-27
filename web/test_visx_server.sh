#!/bin/bash

# VISX Server Test Script
# Tests all the extension server endpoints

echo "🧪 VISX Server Test Script"
echo "=========================="
echo ""

SERVER_URL="http://localhost:3000"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test functions
test_health() {
    echo -n "Testing health endpoint... "
    response=$(curl -s "${SERVER_URL}/health")
    if echo "$response" | grep -q "healthy"; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "$response"
    fi
    echo ""
}

test_list_extensions() {
    echo -n "Testing list extensions endpoint... "
    response=$(curl -s "${SERVER_URL}/api/extensions")
    if echo "$response" | grep -q "extensions"; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "$response"
    fi
    echo ""
}

test_download_extension() {
    echo -n "Testing download rust-analyzer.visx... "

    # Download to temp file
    temp_file="/tmp/rust-analyzer-test.visx"
    http_code=$(curl -s -w "%{http_code}" -o "$temp_file" "${SERVER_URL}/api/extensions/rust-analyzer.visx")

    if [ "$http_code" = "200" ] && [ -f "$temp_file" ]; then
        file_size=$(ls -lh "$temp_file" | awk '{print $5}')
        echo -e "${GREEN}✓ PASS${NC}"
        echo "Downloaded file size: $file_size"

        # Verify it's a zip file
        if file "$temp_file" | grep -q "Zip archive"; then
            echo -e "${GREEN}✓ File is valid ZIP${NC}"
        else
            echo -e "${RED}✗ File is not a ZIP${NC}"
        fi

        rm "$temp_file"
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "HTTP Code: $http_code"
    fi
    echo ""
}

test_visx_structure() {
    echo "Testing VISX file structure..."

    temp_file="/tmp/rust-analyzer-test.visx"
    temp_dir="/tmp/rust-analyzer-test-extracted"

    # Download
    curl -s -o "$temp_file" "${SERVER_URL}/api/extensions/rust-analyzer.visx"

    # Extract
    mkdir -p "$temp_dir"
    unzip -q "$temp_file" -d "$temp_dir"

    # Check required files
    echo -n "  Checking manifest.json... "
    if [ -f "$temp_dir/manifest.json" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi

    echo -n "  Checking package.json... "
    if [ -f "$temp_dir/package.json" ]; then
        echo -e "${GREEN}✓${NC}"
        # Display package info
        echo "    Package info:"
        cat "$temp_dir/package.json" | jq '{name, version, displayName}' 2>/dev/null
    else
        echo -e "${RED}✗${NC}"
    fi

    echo -n "  Checking WASM binaries... "
    if [ -f "$temp_dir/bin/rust-analyzer.wasm" ]; then
        echo -e "${GREEN}✓${NC}"
        wasm_size=$(ls -lh "$temp_dir/bin/rust-analyzer.wasm" | awk '{print $5}')
        echo "    rust-analyzer.wasm size: $wasm_size"
    else
        echo -e "${RED}✗${NC}"
    fi

    # Cleanup
    rm -rf "$temp_dir" "$temp_file"
    echo ""
}

test_cors() {
    echo -n "Testing CORS headers... "
    response=$(curl -s -I "${SERVER_URL}/api/extensions/rust-analyzer.visx")
    if echo "$response" | grep -q "Access-Control-Allow-Origin"; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "$response" | grep "Access-Control"
    else
        echo -e "${YELLOW}⚠ CORS not configured${NC}"
    fi
    echo ""
}

test_invalid_file() {
    echo -n "Testing invalid filename protection... "
    http_code=$(curl -s -w "%{http_code}" -o /dev/null "${SERVER_URL}/api/extensions/../package.json")
    if [ "$http_code" = "400" ]; then
        echo -e "${GREEN}✓ PASS${NC}"
        echo "Server correctly rejects directory traversal"
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "HTTP Code: $http_code (expected 400)"
    fi
    echo ""
}

# Check if server is running
echo "Checking if server is running..."
if curl -s "${SERVER_URL}/health" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Server is running${NC}"
    echo ""
else
    echo -e "${RED}✗ Server is not running${NC}"
    echo ""
    echo "Please start the server first:"
    echo "  cd web && npm start"
    echo ""
    exit 1
fi

# Run all tests
test_health
test_list_extensions
test_download_extension
test_visx_structure
test_cors
test_invalid_file

echo "=========================="
echo -e "${GREEN}✓ All tests completed${NC}"
echo ""
echo "Next steps:"
echo "1. Keep server running: npm start"
echo "2. Add VisxExtractor.swift to Xcode"
echo "3. Add ExtensionsView.swift to Xcode"
echo "4. Add ZipArchive dependency"
echo "5. Test in iOS app"

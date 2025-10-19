#!/bin/bash
# Test examples for WASM execution in Code App
# Run these tests in Code App's terminal after integration is complete

echo "================================"
echo "WASM Command Test Suite"
echo "================================"
echo ""

# Test 1: Version check
echo "Test 1: Version Check"
echo "Running: wasm --version"
wasm --version
echo ""

# Test 2: Simple Hello World
echo "Test 2: Hello World"
cat > /tmp/hello.c << 'EOF'
#include <stdio.h>

int main() {
    printf("Hello from native Wasmer!\n");
    return 0;
}
EOF

echo "Compiling hello.c to WASM..."
clang -O2 /tmp/hello.c -o /tmp/hello.wasm
echo "Running: wasm hello.wasm"
wasm /tmp/hello.wasm
echo ""

# Test 3: Arguments
echo "Test 3: Command Line Arguments"
cat > /tmp/args.c << 'EOF'
#include <stdio.h>

int main(int argc, char** argv) {
    printf("Program: %s\n", argv[0]);
    printf("Arguments: %d\n", argc - 1);
    for (int i = 1; i < argc; i++) {
        printf("  arg[%d] = %s\n", i, argv[i]);
    }
    return 0;
}
EOF

echo "Compiling args.c to WASM..."
clang -O2 /tmp/args.c -o /tmp/args.wasm
echo "Running: wasm args.wasm foo bar baz"
wasm /tmp/args.wasm foo bar baz
echo ""

# Test 4: File I/O
echo "Test 4: File I/O"
cat > /tmp/fileio.c << 'EOF'
#include <stdio.h>
#include <string.h>

int main() {
    const char* filename = "/tmp/wasm_test.txt";
    const char* message = "WASIX p1 file I/O works!\n";

    // Write
    FILE* f = fopen(filename, "w");
    if (!f) {
        printf("ERROR: Cannot open file for writing\n");
        return 1;
    }
    fprintf(f, "%s", message);
    fclose(f);
    printf("✓ File written successfully\n");

    // Read
    f = fopen(filename, "r");
    if (!f) {
        printf("ERROR: Cannot open file for reading\n");
        return 1;
    }
    char buffer[100];
    fgets(buffer, 100, f);
    fclose(f);
    printf("✓ File read successfully\n");
    printf("Content: %s", buffer);

    // Verify
    if (strcmp(buffer, message) == 0) {
        printf("✓ Content matches!\n");
    } else {
        printf("✗ Content mismatch!\n");
        return 1;
    }

    return 0;
}
EOF

echo "Compiling fileio.c to WASM..."
clang -O2 /tmp/fileio.c -o /tmp/fileio.wasm
echo "Running: wasm fileio.wasm"
wasm /tmp/fileio.wasm
echo ""

# Test 5: Environment variables
echo "Test 5: Environment Variables"
cat > /tmp/env.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>

int main() {
    printf("PATH = %s\n", getenv("PATH"));
    printf("HOME = %s\n", getenv("HOME"));
    printf("USER = %s\n", getenv("USER") ? getenv("USER") : "(not set)");
    return 0;
}
EOF

echo "Compiling env.c to WASM..."
clang -O2 /tmp/env.c -o /tmp/env.wasm
echo "Running: wasm env.wasm"
wasm /tmp/env.wasm
echo ""

echo "================================"
echo "All tests completed!"
echo "================================"
echo ""
echo "If all tests passed, WASM integration is working correctly!"

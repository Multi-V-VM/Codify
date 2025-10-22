// Simple WASM Hello World Example
#include <stdio.h>

int add(int a, int b) {
    return a + b;
}

int multiply(int a, int b) {
    return a * b;
}

void hello() {
    printf("Hello from WASM!\n");
}

int main() {
    printf("WASM Module Loaded Successfully\n");
    printf("Functions available: add, multiply, hello\n");
    return 0;
}

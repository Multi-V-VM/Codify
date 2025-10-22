# WASM Hello World Example

A simple WebAssembly module demonstrating basic functions.

## Functions

- `add(a, b)` - Returns the sum of two numbers
- `multiply(a, b)` - Returns the product of two numbers
- `hello()` - Prints a greeting message

## Building

If you have Emscripten installed:

```bash
npm run build
```

Or manually:

```bash
emcc hello.c -o hello.wasm -s EXPORTED_FUNCTIONS='["_add","_multiply","_hello"]' -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap"]'
```

## Creating VISX Package

```bash
python create_visx.py examples/wasm-hello wasm-hello.visx --type wasm
```

## Using in CodeApp

1. Download or transfer the `.visx` file
2. Open CodeApp
3. Go to VISX Packages panel (sidebar)
4. Click "Download from URL" or select local file
5. The module will be automatically installed

## Testing

```javascript
// Load the WASM module
const wasmModule = await loadWASM('wasm-hello-world');

// Use the functions
console.log(wasmModule.add(5, 3));       // 8
console.log(wasmModule.multiply(4, 7));  // 28
wasmModule.hello();                       // "Hello from WASM!"
```

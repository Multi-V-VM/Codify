# Local Rust WASIp1 experiment

The large compiler module is distributed as a release asset because GitHub
does not allow public forks to upload new Git LFS objects. Fetch it before a
command-line build (Xcode's resource-generation phase also fetches it when the
file is absent):

```sh
./scripts/fetch_rust_wasip1_toolchain.sh
```

CodifyOne exposes `rustc`, `cargo`, and the offline informational subset of
`rustup` through the bundled `Resources/NodeJS/rust_toolchain.wasm` module.
The compiler and package driver run inside Wasmi as WASIp1 code. Generated C
code is handed back to CodifyOne's embedded clang through the
`env.codifyone_rust_codegen` host import and is linked as `wasm32-wasip1`.

The bundled compiler is based on mrustc/minicargo at commit
`be69c7479a10bdce1b86cb886789d14a143ddf34`, configured for the Rust 1.90
language and standard library. `Resources/NodeJS/RustWasi/lib` contains the
prebuilt `core`, `alloc`, `std`, and support HIR/object pairs. The public shell
interface remains `rustc` and `cargo`; users do not invoke mrustc directly.

Examples:

```sh
rustc --version
rustc hello.rs -o hello.wasm
./hello.wasm

cargo build
```

The target is always `wasm32-wasip1`. Projects are staged under the WASM
runtime's `/home/workspace` because Wasmer cannot safely use the iOS Documents
container as its host cwd; results are copied back afterward.

This is an offline experiment. Registry access and modern official rustup
toolchain management are not implemented. Procedural macros and crates that
need subprocesses/build tools are unsupported. Panic handling is abort/trap,
because the selected Wasmi backend does not implement WebAssembly exception
handling.

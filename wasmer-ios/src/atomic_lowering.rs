use std::convert::Infallible;

use wasm_encoder::{
    BlockType, CodeSection, Function, Instruction, MemoryType, Module, ValType,
    reencode::{self, Reencode},
};
use wasmparser::{FunctionBody, Operator, Parser, Payload};

struct AtomicLowerer {
    param_counts: Vec<u32>,
    function_index: usize,
}

impl Reencode for AtomicLowerer {
    type Error = Infallible;

    fn memory_type(
        &mut self,
        memory: wasmparser::MemoryType,
    ) -> Result<MemoryType, reencode::Error<Self::Error>> {
        let mut memory = reencode::utils::memory_type(self, memory);
        memory.shared = false;
        Ok(memory)
    }

    fn parse_function_body(
        &mut self,
        code: &mut CodeSection,
        body: FunctionBody<'_>,
    ) -> Result<(), reencode::Error<Self::Error>> {
        let params = self.param_counts[self.function_index];
        self.function_index += 1;

        let mut locals = Vec::new();
        let mut local_count = 0u32;
        for local in body.get_locals_reader()? {
            let (count, ty) = local?;
            local_count += count;
            locals.push((count, self.val_type(ty)?));
        }
        let base = params + local_count;
        let scratch = Scratch {
            addr: base,
            i32_a: base + 1,
            i32_b: base + 2,
            i32_c: base + 3,
            i64_a: base + 4,
            i64_b: base + 5,
            i64_c: base + 6,
        };
        locals.extend([(4, ValType::I32), (3, ValType::I64)]);

        let mut function = Function::new(locals);
        let mut reader = body.get_operators_reader()?;
        while !reader.eof() {
            let operator = reader.read()?;
            if !lower_atomic(&mut function, operator.clone(), scratch, self)? {
                function.instruction(&self.instruction(operator)?);
            }
        }
        code.function(&function);
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct Scratch {
    addr: u32,
    i32_a: u32,
    i32_b: u32,
    i32_c: u32,
    i64_a: u32,
    i64_b: u32,
    i64_c: u32,
}

fn emit(function: &mut Function, instructions: &[Instruction<'_>]) {
    for instruction in instructions {
        function.instruction(instruction);
    }
}

fn rmw(
    function: &mut Function,
    scratch: Scratch,
    value: u32,
    old: u32,
    load: Instruction<'_>,
    store: Instruction<'_>,
    operation: Option<Instruction<'_>>,
) {
    emit(function, &[Instruction::LocalSet(value), Instruction::LocalSet(scratch.addr)]);
    emit(function, &[Instruction::LocalGet(scratch.addr), load, Instruction::LocalSet(old)]);
    function.instruction(&Instruction::LocalGet(scratch.addr));
    if let Some(operation) = operation {
        emit(function, &[Instruction::LocalGet(old), Instruction::LocalGet(value), operation]);
    } else {
        function.instruction(&Instruction::LocalGet(value));
    }
    emit(function, &[store, Instruction::LocalGet(old)]);
}

fn cmpxchg(
    function: &mut Function,
    scratch: Scratch,
    expected: u32,
    replacement: u32,
    old: u32,
    load: Instruction<'_>,
    store: Instruction<'_>,
    equal: Instruction<'_>,
    result: ValType,
) {
    emit(function, &[
        Instruction::LocalSet(replacement),
        Instruction::LocalSet(expected),
        Instruction::LocalSet(scratch.addr),
        Instruction::LocalGet(scratch.addr),
        load,
        Instruction::LocalSet(old),
        Instruction::LocalGet(scratch.addr),
        Instruction::LocalGet(old),
        Instruction::LocalGet(expected),
        equal,
        Instruction::If(BlockType::Result(result)),
        Instruction::LocalGet(replacement),
        Instruction::Else,
        Instruction::LocalGet(old),
        Instruction::End,
        store,
        Instruction::LocalGet(old),
    ]);
}

fn lower_atomic(
    f: &mut Function,
    op: Operator<'_>,
    s: Scratch,
    reencoder: &mut AtomicLowerer,
) -> Result<bool, reencode::Error<Infallible>> {
    let mut mem = |arg| reencoder.mem_arg(arg);
    macro_rules! direct {
        ($arg:expr, $instruction:ident) => {{ f.instruction(&Instruction::$instruction(mem($arg)?)); true }};
    }
    macro_rules! r32 {
        ($arg:expr, $load:ident, $store:ident, $operation:ident) => {{
            let m = mem($arg)?;
            rmw(f, s, s.i32_a, s.i32_b, Instruction::$load(m), Instruction::$store(m), Some(Instruction::$operation)); true
        }};
    }
    macro_rules! r64 {
        ($arg:expr, $load:ident, $store:ident, $operation:ident) => {{
            let m = mem($arg)?;
            rmw(f, s, s.i64_a, s.i64_b, Instruction::$load(m), Instruction::$store(m), Some(Instruction::$operation)); true
        }};
    }
    let lowered = match op {
        Operator::AtomicFence => true,
        Operator::MemoryAtomicNotify { .. } => { emit(f, &[Instruction::Drop, Instruction::Drop, Instruction::I32Const(0)]); true }
        Operator::MemoryAtomicWait32 { memarg } => {
            let m = mem(memarg)?;
            emit(f, &[Instruction::Drop, Instruction::LocalSet(s.i32_a), Instruction::LocalSet(s.addr), Instruction::I32Const(1), Instruction::I32Const(2), Instruction::LocalGet(s.addr), Instruction::I32Load(m), Instruction::LocalGet(s.i32_a), Instruction::I32Ne, Instruction::Select]); true
        }
        Operator::MemoryAtomicWait64 { memarg } => {
            let m = mem(memarg)?;
            emit(f, &[Instruction::Drop, Instruction::LocalSet(s.i64_a), Instruction::LocalSet(s.addr), Instruction::I32Const(1), Instruction::I32Const(2), Instruction::LocalGet(s.addr), Instruction::I64Load(m), Instruction::LocalGet(s.i64_a), Instruction::I64Ne, Instruction::Select]); true
        }
        Operator::I32AtomicLoad { memarg } => direct!(memarg, I32Load),
        Operator::I64AtomicLoad { memarg } => direct!(memarg, I64Load),
        Operator::I32AtomicLoad8U { memarg } => direct!(memarg, I32Load8U),
        Operator::I32AtomicLoad16U { memarg } => direct!(memarg, I32Load16U),
        Operator::I64AtomicLoad8U { memarg } => direct!(memarg, I64Load8U),
        Operator::I64AtomicLoad16U { memarg } => direct!(memarg, I64Load16U),
        Operator::I64AtomicLoad32U { memarg } => direct!(memarg, I64Load32U),
        Operator::I32AtomicStore { memarg } => direct!(memarg, I32Store),
        Operator::I64AtomicStore { memarg } => direct!(memarg, I64Store),
        Operator::I32AtomicStore8 { memarg } => direct!(memarg, I32Store8),
        Operator::I32AtomicStore16 { memarg } => direct!(memarg, I32Store16),
        Operator::I64AtomicStore8 { memarg } => direct!(memarg, I64Store8),
        Operator::I64AtomicStore16 { memarg } => direct!(memarg, I64Store16),
        Operator::I64AtomicStore32 { memarg } => direct!(memarg, I64Store32),
        Operator::I32AtomicRmwAdd { memarg } => r32!(memarg, I32Load, I32Store, I32Add),
        Operator::I32AtomicRmw8AddU { memarg } => r32!(memarg, I32Load8U, I32Store8, I32Add),
        Operator::I32AtomicRmw16AddU { memarg } => r32!(memarg, I32Load16U, I32Store16, I32Add),
        Operator::I64AtomicRmwAdd { memarg } => r64!(memarg, I64Load, I64Store, I64Add),
        Operator::I64AtomicRmw8AddU { memarg } => r64!(memarg, I64Load8U, I64Store8, I64Add),
        Operator::I64AtomicRmw16AddU { memarg } => r64!(memarg, I64Load16U, I64Store16, I64Add),
        Operator::I64AtomicRmw32AddU { memarg } => r64!(memarg, I64Load32U, I64Store32, I64Add),
        Operator::I32AtomicRmwSub { memarg } => r32!(memarg, I32Load, I32Store, I32Sub),
        Operator::I32AtomicRmw8SubU { memarg } => r32!(memarg, I32Load8U, I32Store8, I32Sub),
        Operator::I32AtomicRmw16SubU { memarg } => r32!(memarg, I32Load16U, I32Store16, I32Sub),
        Operator::I64AtomicRmwSub { memarg } => r64!(memarg, I64Load, I64Store, I64Sub),
        Operator::I64AtomicRmw8SubU { memarg } => r64!(memarg, I64Load8U, I64Store8, I64Sub),
        Operator::I64AtomicRmw16SubU { memarg } => r64!(memarg, I64Load16U, I64Store16, I64Sub),
        Operator::I64AtomicRmw32SubU { memarg } => r64!(memarg, I64Load32U, I64Store32, I64Sub),
        Operator::I32AtomicRmwAnd { memarg } => r32!(memarg, I32Load, I32Store, I32And),
        Operator::I32AtomicRmw8AndU { memarg } => r32!(memarg, I32Load8U, I32Store8, I32And),
        Operator::I32AtomicRmw16AndU { memarg } => r32!(memarg, I32Load16U, I32Store16, I32And),
        Operator::I64AtomicRmwAnd { memarg } => r64!(memarg, I64Load, I64Store, I64And),
        Operator::I64AtomicRmw8AndU { memarg } => r64!(memarg, I64Load8U, I64Store8, I64And),
        Operator::I64AtomicRmw16AndU { memarg } => r64!(memarg, I64Load16U, I64Store16, I64And),
        Operator::I64AtomicRmw32AndU { memarg } => r64!(memarg, I64Load32U, I64Store32, I64And),
        Operator::I32AtomicRmwOr { memarg } => r32!(memarg, I32Load, I32Store, I32Or),
        Operator::I32AtomicRmw8OrU { memarg } => r32!(memarg, I32Load8U, I32Store8, I32Or),
        Operator::I32AtomicRmw16OrU { memarg } => r32!(memarg, I32Load16U, I32Store16, I32Or),
        Operator::I64AtomicRmwOr { memarg } => r64!(memarg, I64Load, I64Store, I64Or),
        Operator::I64AtomicRmw8OrU { memarg } => r64!(memarg, I64Load8U, I64Store8, I64Or),
        Operator::I64AtomicRmw16OrU { memarg } => r64!(memarg, I64Load16U, I64Store16, I64Or),
        Operator::I64AtomicRmw32OrU { memarg } => r64!(memarg, I64Load32U, I64Store32, I64Or),
        Operator::I32AtomicRmwXor { memarg } => r32!(memarg, I32Load, I32Store, I32Xor),
        Operator::I32AtomicRmw8XorU { memarg } => r32!(memarg, I32Load8U, I32Store8, I32Xor),
        Operator::I32AtomicRmw16XorU { memarg } => r32!(memarg, I32Load16U, I32Store16, I32Xor),
        Operator::I64AtomicRmwXor { memarg } => r64!(memarg, I64Load, I64Store, I64Xor),
        Operator::I64AtomicRmw8XorU { memarg } => r64!(memarg, I64Load8U, I64Store8, I64Xor),
        Operator::I64AtomicRmw16XorU { memarg } => r64!(memarg, I64Load16U, I64Store16, I64Xor),
        Operator::I64AtomicRmw32XorU { memarg } => r64!(memarg, I64Load32U, I64Store32, I64Xor),
        Operator::I32AtomicRmwXchg { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i32_a,s.i32_b,Instruction::I32Load(m),Instruction::I32Store(m),None); true }
        Operator::I32AtomicRmw8XchgU { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i32_a,s.i32_b,Instruction::I32Load8U(m),Instruction::I32Store8(m),None); true }
        Operator::I32AtomicRmw16XchgU { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i32_a,s.i32_b,Instruction::I32Load16U(m),Instruction::I32Store16(m),None); true }
        Operator::I64AtomicRmwXchg { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i64_a,s.i64_b,Instruction::I64Load(m),Instruction::I64Store(m),None); true }
        Operator::I64AtomicRmw8XchgU { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i64_a,s.i64_b,Instruction::I64Load8U(m),Instruction::I64Store8(m),None); true }
        Operator::I64AtomicRmw16XchgU { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i64_a,s.i64_b,Instruction::I64Load16U(m),Instruction::I64Store16(m),None); true }
        Operator::I64AtomicRmw32XchgU { memarg } => { let m=mem(memarg)?; rmw(f,s,s.i64_a,s.i64_b,Instruction::I64Load32U(m),Instruction::I64Store32(m),None); true }
        Operator::I32AtomicRmwCmpxchg { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i32_a,s.i32_b,s.i32_c,Instruction::I32Load(m),Instruction::I32Store(m),Instruction::I32Eq,ValType::I32); true }
        Operator::I32AtomicRmw8CmpxchgU { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i32_a,s.i32_b,s.i32_c,Instruction::I32Load8U(m),Instruction::I32Store8(m),Instruction::I32Eq,ValType::I32); true }
        Operator::I32AtomicRmw16CmpxchgU { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i32_a,s.i32_b,s.i32_c,Instruction::I32Load16U(m),Instruction::I32Store16(m),Instruction::I32Eq,ValType::I32); true }
        Operator::I64AtomicRmwCmpxchg { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i64_a,s.i64_b,s.i64_c,Instruction::I64Load(m),Instruction::I64Store(m),Instruction::I64Eq,ValType::I64); true }
        Operator::I64AtomicRmw8CmpxchgU { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i64_a,s.i64_b,s.i64_c,Instruction::I64Load8U(m),Instruction::I64Store8(m),Instruction::I64Eq,ValType::I64); true }
        Operator::I64AtomicRmw16CmpxchgU { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i64_a,s.i64_b,s.i64_c,Instruction::I64Load16U(m),Instruction::I64Store16(m),Instruction::I64Eq,ValType::I64); true }
        Operator::I64AtomicRmw32CmpxchgU { memarg } => { let m=mem(memarg)?; cmpxchg(f,s,s.i64_a,s.i64_b,s.i64_c,Instruction::I64Load32U(m),Instruction::I64Store32(m),Instruction::I64Eq,ValType::I64); true }
        _ => false,
    };
    Ok(lowered)
}

pub fn lower_threads_to_single_thread(bytes: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut type_params = Vec::new();
    let mut function_types = Vec::new();
    for payload in Parser::new(0).parse_all(bytes) {
        match payload? {
            Payload::TypeSection(reader) => {
                for ty in reader.into_iter_err_on_gc_types() {
                    type_params.push(ty?.params().len() as u32);
                }
            }
            Payload::FunctionSection(reader) => {
                function_types.extend(reader.into_iter().collect::<Result<Vec<_>, _>>()?);
            }
            _ => {}
        }
    }
    let param_counts = function_types
        .into_iter()
        .map(|index| type_params[index as usize])
        .collect();
    let mut lowerer = AtomicLowerer { param_counts, function_index: 0 };
    let mut module = Module::new();
    lowerer.parse_core_module(&mut module, Parser::new(0), bytes)
        .map_err(|error| format!("failed to lower Wasm atomics: {error:?}"))?;
    Ok(module.finish())
}

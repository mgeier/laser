# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  macros,
  # Internal
  ../platforms,
  ./ast_definition,
  ./ast_sigmatch,
  ./ast_codegen,
  ./ast_codegen_transfo,
  ./macro_utils

# TODO: Do we need both compile and generate?

proc initParams(
       procDef,
       resultType: NimNode
       ): tuple[
            ids, ids_baseType: seq[NimNode],
            ptrs, simds: tuple[inParams, outParams: seq[NimNode]],
            length: NimNode,
            initStmt: NimNode
          ] =
  # Get the idents from proc definition. We order the same as proc def
  # Start with non-result
  # We work at simd vector level
  result.initStmt = newStmtList()

  var shape0: NimNode
  var len0: NimNode

  for i in 1 ..< procDef[0][3].len: # Proc formal params
    let iddefs = procDef[0][3][i]
    for j in 0 ..< iddefs.len - 2:
      # Ident
      let ident = iddefs[j]
      result.ids.add ident

      # TODO - support var Tensor
      # Ident base type (without seq)
      if not iddefs[^2].isType"Tensor":
        result.ids_baseType.add iddefs[^2]
      else:
        result.ids_baseType.add iddefs[^2][1]
        # If Tensor take pointers

        # Raw ptr
        let raw_ptr = newIdentNode($ident & "_raw_ptr")
        result.ptrs.inParams.add raw_ptr

        # Init statement and iteration length
        if len0.isNil:
          len0 = ident"iter_len"
          shape0 = ident"shape0"
          result.initStmt.add quote do:
            let `shape0` = `ident`.shape
            let `len0` = `ident`.size()
          result.length = len0
        else:
          let len0 = result.length
          result.initStmt.add quote do:
            assert `len0` == `ident`.size()
        result.initStmt.add quote do:
          let `raw_ptr` = `ident`.unsafe_raw_data()

        # SIMD ident
        result.simds.inParams.add newIdentNode($ident & "_simd")

  # Now add the result idents
  # We work at simd vector level
  if resultType.kind == nnkEmpty:
    discard
  elif resultType.kind == nnkTupleTy:
    for i in 0 ..< resultType.len:
      let iddefs = resultType[i]
      for j in 0 ..< iddefs.len - 2:
        # Ident
        let ident = iddefs[j]
        result.ids.add ident
        # Ident base type (without seq)
        if not iddefs[^2].isType"Tensor":
          result.ids_baseType.add iddefs[^2]
        else:
          let baseType = iddefs[^2][1]
          result.ids_baseType.add baseType

          # Raw ptr
          let raw_ptr = newIdentNode($ident & "_raw_ptr")
          result.ptrs.outParams.add raw_ptr

          # Init statement
          let res = nnkDotExpr.newTree(
                      newIdentNode"result",
                      iddefs[j]
                    )
          result.initStmt.add quote do:
            `res` = newTensor[`baseType`](`shape0`)
            let `raw_ptr` = `res`.unsafe_raw_data()

          # SIMD ident
          result.simds.outParams.add newIdentNode($ident & "_simd")

proc symbolicExecStmt(ast: NimNode, inputSyms: seq[NimNode], hasOut: bool, outputSyms, stmts: var NimNode) =
  # Allocate inputs
  for i, in_ident in inputSyms:
    stmts.add newLetStmt(
      ct(in_ident),
      newCall("input", newLit i)
    )

  # Call the AST routine
  let call = newCall(ast, inputSyms)
  if not hasOut: # Case 1: no result
    stmts.add call
  else:
    outputSyms = ct(genSym(nskLet, "callResult_"))
    stmts.add newLetStmt(
      outputSyms, call
    )

macro compile(io_ast: static varargs[LuxNode], procDef: untyped): untyped =
  # Note: io_ast must be an array - https://github.com/nim-lang/Nim/issues/10691

  # compile([a, b, c, bar, baz, buzz]):
  #   proc foobar[T](a, b, c: T): tuple[bar, baz, buzz: T]
  #
  # StmtList
  #   ProcDef
  #     Ident "foobar"
  #     Empty
  #     GenericParams
  #       IdentDefs
  #         Ident "T"
  #         Empty
  #         Empty
  #     FormalParams
  #       TupleTy
  #         IdentDefs
  #           Ident "bar"
  #           Ident "baz"
  #           Ident "buzz"
  #           Ident "T"
  #           Empty
  #       IdentDefs
  #         Ident "a"
  #         Ident "b"
  #         Ident "c"
  #         Ident "T"
  #         Empty
  #     Empty
  #     Empty
  #     Empty

  # echo procDef.treerepr

  ## Sanity checks
  procDef.expectkind(nnkStmtList)
  assert procDef.len == 1, "Only 1 statement is allowed, the function definition"
  procDef[0].expectkind({nnkProcDef, nnkFuncDef})
  # TODO: check that the function inputs are in a symbol table?
  procDef[0][6].expectKind(nnkEmpty)

  let resultTy = procDef[0][3][0]
  let (ids, ids_baseType, ptrs, simds, length, initParams) = initParams(procDef, resultTy)

  # echo initParams.toStrLit()

  # We create an inner generic proc on the base type (without Tensor[T])
  var genericProc = procDef[0].liftTypes(containerIdent = "Tensor")

  # We create the inner generic proc
  let genericOverload = bodyGen(
    arch = ArchGeneric,
    io_ast = io_ast,
    ids = ids,
    ids_baseType = ids_baseType,
    resultType = resultTy
  )

  genericProc[6] = genericOverload   # Assign to proc body
  # echo genericProc.toStrLit

  # We create the inner SIMD proc, specialized to a SIMD architecture
  # In the inner proc we shadow the original idents ids.
  let simdOverload = bodyGen(
    arch = x86_SSE,
    io_ast = io_ast,
    ids = ids,
    ids_baseType = ids_baseType,
    resultType = resultTy
  )

  var simdProc = procDef[0].liftTypes(
    containerIdent = "Tensor",
    remapping = func(typeNode: NimNode): NimNode {.gcsafe, locks: 0.} = {.noSideEffect.}: SimdMap(x86_SSE, typeNode, simdType)
  )

  simdProc[6] = simdOverload   # Assign to proc body
  # echo simdProc.toStrLit

  # We vectorize the inner proc to apply to an contiguous array
  var vecBody: NimNode
  vecBody = vectorize(
      procDef[0][0],
      ptrs, simds,
      length,
      x86_SSE, ids_baseType[0] # TODO, only use the inner loop
    )

  result = procDef.copyNimTree()
  let resBody = newStmtList()
  resBody.add initParams
  resBody.add genericProc
  resBody.add simdProc
  resBody.add vecBody
  result[0][6] = resBody

  echo result.toStrLit

macro generate*(ast_routine: typed, signature: untyped): untyped =
  # TODO: remove the need for ast_routine for symbol resolution

  result = newStmtList()

  # TODO: canonicalize signature
  let formalParams = signature[0][3]
  let ast = ast_routine.resolveASToverload(formalParams)

  # Get the routine signature
  let sig = ast.getImpl[3]
  sig.expectKind(nnkFormalParams)

  # Get all inputs
  var inputSyms: seq[NimNode]
  for idx_identdef in 1 ..< sig.len:
    let identdef = sig[idx_identdef]
    doAssert identdef[^2].eqIdent"LuxNode"
    identdef[^1].expectKind(nnkEmpty)
    for idx_ident in 0 .. identdef.len-3:
      inputSyms.add genSym(nskLet, $identdef[idx_ident] & "_")

  # Symbolic execution statement
  var outputSyms: NimNode
  var symExecStmt = newStmtList()
  symbolicExecStmt(
      ast,
      inputSyms,
      hasOut = sig[0].kind != nnkEmpty,
      outputSyms,
      symExecStmt
    )

  # Collect all the input/output idents
  var io = inputSyms
  case sig[0].kind
  of nnkEmpty:
    discard
  of nnkTupleTy:
    var idx = 0
    for identdef in sig[0]:
      for idx_ident in 0 .. identdef.len-3:
        io.add nnkBracketExpr.newTree(
          outputSyms[0],
          newLit idx
        )
        inc idx
  else:
    io.add outputSyms

  # Call the compilation macro
  result.add symExecStmt
  result.add quote do:
    compile(`io`, `signature`)

  echo result.toStrlit
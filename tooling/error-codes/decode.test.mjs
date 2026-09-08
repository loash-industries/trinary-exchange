import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { parseMoveAbort, unpackAbortCode, explainAbort, formatAbort } from './decode.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const CATALOG = JSON.parse(readFileSync(join(HERE, 'generated', 'error-codes.json'), 'utf8')).byModule

const PKG = '0xa9ec4afe4757ad2b90102e02b133fcd0cb7cc526722524ce20fcdf53be4ec309'

// Rendering produced by the current ExecutionFailureStatus Display impl.
const MODERN = `Move Runtime Abort. Location: ${PKG}::multicoin_pool::create_multicoin_pool (function index 3) at offset 45, Abort Code: 1 in command 0`
// Older Debug-style rendering, still seen from some nodes and tooling.
const LEGACY = `MoveAbort(MoveLocation { module: ModuleId { address: a9ec4afe4757ad2b90102e02b133fcd0cb7cc526722524ce20fcdf53be4ec309, name: Identifier("multicoin_pool") }, function: 3, instruction: 45, function_name: Some("create_multicoin_pool") }, 1) in command 0`

test('parses the modern abort rendering', () => {
  const p = parseMoveAbort(MODERN)
  assert.equal(p.module, 'multicoin_pool')
  assert.equal(p.function, undefined)
  assert.equal(p.functionName, 'create_multicoin_pool')
  assert.equal(p.rawCode, '1')
  assert.equal(p.commandIndex, 0)
})

test('parses the legacy debug abort rendering', () => {
  const p = parseMoveAbort(LEGACY)
  assert.equal(p.module, 'multicoin_pool')
  assert.equal(p.functionName, 'create_multicoin_pool')
  assert.equal(p.rawCode, '1')
})

test('both renderings resolve to the same label', () => {
  for (const raw of [MODERN, LEGACY]) {
    const e = explainAbort(raw, CATALOG)
    assert.equal(e.resolution, 'resolved')
    assert.equal(e.constant, 'EInvalidFee')
    assert.equal(e.label, 'Invalid fee')
    assert.equal(e.clever, false)
  }
})

test('same code in a different module resolves to a different error', () => {
  const inPool = explainAbort(MODERN.replace(/multicoin_pool/g, 'trading_account'), CATALOG)
  assert.equal(inPool.constant, 'EInvalidTrader')
  assert.notEqual(inPool.label, 'Invalid fee')
})

test('unpacks a clever abort code', () => {
  // tag=1, explicit code=7, line=96, identifier index=1, constant index=0
  const code = (1n << 63n) | (7n << 48n) | (96n << 32n) | (1n << 16n) | 0n
  const bits = unpackAbortCode(code)
  assert.equal(bits.isClever, true)
  assert.equal(bits.errorCode, 7)
  assert.equal(bits.sourceLine, 96)
  assert.equal(bits.identifierIndex, 1)
  assert.equal(bits.constantIndex, 0)
})

test('the documented example decodes as documented', () => {
  // 0x8000_0007_0001_0000 from the Move reference: line 7, identifier index 1, constant index 0
  const bits = unpackAbortCode(0x8000000700010000n)
  assert.equal(bits.isClever, true)
  assert.equal(bits.sourceLine, 7)
  assert.equal(bits.identifierIndex, 1)
  assert.equal(bits.constantIndex, 0)
  assert.equal(bits.errorCode, null) // no explicit #[error(code = N)]
})

test('a clever code resolves through the explicit error code', () => {
  const code = (1n << 63n) | (20n << 48n) | (123n << 32n) | (5n << 16n) | 2n
  const raw = `Move Runtime Abort. Location: ${PKG}::pool::place_limit_order (function index 9) at offset 12, Abort Code: ${code} in command 0`
  const e = explainAbort(raw, CATALOG)
  assert.equal(e.clever, true)
  assert.equal(e.code, 20)
  assert.equal(e.constant, 'EQuoteNotApproved')
  assert.equal(e.sourceLine, 123)
})

test('plain codes are not misread as clever', () => {
  assert.equal(unpackAbortCode(1).isClever, false)
  assert.equal(unpackAbortCode('9223372036854775807').isClever, false) // 2^63 - 1
  assert.equal(unpackAbortCode('9223372036854775808').isClever, true) // 2^63
})

test('aborts from dependencies are reported, not swallowed', () => {
  const raw = 'Move Runtime Abort. Location: 0x2::coin::split (function index 12) at offset 3, Abort Code: 2 in command 1'
  const e = explainAbort(raw, CATALOG)
  assert.equal(e.resolution, 'external-module')
  assert.equal(e.module, 'coin')
  assert.match(formatAbort(e), /dependency 0x2::coin with code 2/)
})

test('an unmapped code in a known module is flagged', () => {
  const raw = `Move Runtime Abort. Location: ${PKG}::vault::settle (function index 1) at offset 1, Abort Code: 999 in command 0`
  const e = explainAbort(raw, CATALOG)
  assert.equal(e.resolution, 'unknown-code')
  assert.match(formatAbort(e), /Unmapped abort code 999 in vault::settle/)
})

test('non-abort failures pass through unchanged', () => {
  const e = explainAbort('InsufficientGas', CATALOG)
  assert.equal(e.kind, 'other')
  assert.equal(e.label, 'InsufficientGas')
})

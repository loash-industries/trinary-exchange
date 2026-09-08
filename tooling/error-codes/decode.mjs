// Turns the `effects.status.error` string from a Sui transaction into a labelled error.
//
// That field is not structured data: it is the Display impl of
// `ExecutionFailureStatus`, which for aborts renders the location and the raw u64 and
// nothing else. Both the current and the older Debug-style rendering are parsed here,
// because the format is not a stable API and a node may serve either.

/**
 * Clever-error bit layout, per the Move compiler:
 *   | 1-bit tag | 15-bit reserved (explicit #[error(code = N)]) |
 *   | 16-bit source line | 16-bit identifier index | 16-bit constant index |
 * The two indices point into the module's tables, so resolving a *name* needs the
 * package bytes. The explicit code and the line number are pure arithmetic.
 */
const SENTINEL = 0xffffn

export function unpackAbortCode(rawCode) {
  const c = BigInt(rawCode)
  const isClever = ((c >> 63n) & 1n) === 1n
  if (!isClever) return { isClever: false, errorCode: Number(c), sourceLine: null, identifierIndex: null, constantIndex: null }

  const identifierIndex = (c >> 16n) & 0xffffn
  const constantIndex = c & 0xffffn
  const explicit = (c >> 48n) & 0x7fffn
  return {
    isClever: true,
    // 0 is also what an un-annotated `#[error]` leaves here, so it cannot be told apart
    // from a literal `#[error(code = 0)]`. The generator lints against using code 0.
    errorCode: explicit === 0n ? null : Number(explicit),
    sourceLine: Number((c >> 32n) & 0xffffn),
    identifierIndex: identifierIndex === SENTINEL ? null : Number(identifierIndex),
    constantIndex: constantIndex === SENTINEL ? null : Number(constantIndex),
  }
}

// `Move Runtime Abort. Location: 0x2::pool::place_order (function index 3) at offset 45, Abort Code: 1`
const MODERN = /Move Runtime Abort\.\s*Location:\s*(0x[0-9a-fA-F]+)::([A-Za-z0-9_]+)(?:::([A-Za-z0-9_]+))?[^,]*,\s*Abort Code:\s*(\d+)/
// `MoveAbort(MoveLocation { module: ModuleId { address: 0x2, name: Identifier("pool") }, ... }, 1)`
const LEGACY = /MoveAbort\(MoveLocation\s*\{[^}]*address:\s*(?:0x)?([0-9a-fA-F]+)[^}]*name:\s*Identifier\("([A-Za-z0-9_]+)"\)[\s\S]*?\},\s*(\d+)\)/
const LEGACY_FN = /function_name:\s*Some\("([A-Za-z0-9_]+)"\)/
const COMMAND = /in command (\d+)/

/** Pull the structured parts out of an abort string. Returns null for non-abort failures. */
export function parseMoveAbort(errorString) {
  if (typeof errorString !== 'string') return null

  const commandIndex = COMMAND.exec(errorString)?.[1]
  const modern = MODERN.exec(errorString)
  if (modern) {
    const [, address, module, functionName, rawCode] = modern
    return { address, module, functionName: functionName ?? null, rawCode, commandIndex: commandIndex ? Number(commandIndex) : null }
  }

  const legacy = LEGACY.exec(errorString)
  if (legacy) {
    const [, address, module, rawCode] = legacy
    return {
      address: address.startsWith('0x') ? address : `0x${address.replace(/^0+/, '') || '0'}`,
      module,
      functionName: LEGACY_FN.exec(errorString)?.[1] ?? null,
      rawCode,
      commandIndex: commandIndex ? Number(commandIndex) : null,
    }
  }

  return null
}

/**
 * Resolve an abort string against a generated catalog.
 * `catalog` is the `byModule` map produced by generate.mjs.
 */
export function explainAbort(errorString, catalog) {
  const parsed = parseMoveAbort(errorString)
  if (!parsed) return { kind: 'other', raw: errorString, label: errorString }

  const bits = unpackAbortCode(parsed.rawCode)
  const lookupCode = bits.errorCode
  const moduleTable = catalog[parsed.module]
  const entry = lookupCode === null ? undefined : moduleTable?.[lookupCode]

  let resolution
  if (entry) resolution = 'resolved'
  else if (!moduleTable) resolution = 'external-module'
  else resolution = 'unknown-code'

  return {
    kind: 'move-abort',
    resolution,
    address: parsed.address,
    module: parsed.module,
    function: parsed.functionName,
    commandIndex: parsed.commandIndex,
    rawCode: parsed.rawCode,
    clever: bits.isClever,
    code: lookupCode,
    // Only present for clever errors; free provenance for logs.
    sourceLine: bits.sourceLine,
    constant: entry?.name ?? null,
    label: entry?.label ?? null,
    message: entry?.message ?? null,
    declaredAt: entry ? `${entry.file}:${entry.line}` : null,
    raw: errorString,
  }
}

/** One-line rendering suitable for a log or a toast. */
export function formatAbort(explained) {
  if (explained.kind !== 'move-abort') return explained.label
  const where = explained.function ? `${explained.module}::${explained.function}` : explained.module
  if (explained.resolution === 'resolved') {
    const detail = explained.message ?? explained.label
    return `${detail} (${where}, ${explained.constant}=${explained.code})`
  }
  if (explained.resolution === 'external-module') {
    return `Aborted in dependency ${explained.address}::${explained.module} with code ${explained.code}`
  }
  return `Unmapped abort code ${explained.code} in ${where}`
}

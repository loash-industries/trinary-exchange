// Extracts error constants from Move sources.
//
// Recognises the three shapes an abort constant can take:
//   const EFoo: u64 = 7;                                    -> plain u64 abort code
//   #[error(code = 7)] const EFoo: vector<u8> = b"msg";     -> clever error, stable code
//   #[error] const EFoo: vector<u8> = b"msg";               -> clever error, no stable code
//
// The third shape has no code that survives a reformat (the compiler derives it from
// the source line), so it cannot be keyed on off-chain. We surface it as `code: null`
// and let the caller decide whether that is a problem.

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

const MODULE_DECL = /^\s*module\s+([A-Za-z0-9_]+)::([A-Za-z0-9_]+)\s*[;{]/
const CONST_DECL = /^\s*const\s+([A-Za-z0-9_]+)\s*:\s*([A-Za-z0-9_<>]+)\s*=\s*(.*)$/
// Move error constants are `EPascalCase`. This deliberately excludes SCREAMING_CASE
// constants that merely start with E (EXPIRED, EWMA_DF_KEY) — they are not abort codes.
const ERROR_NAME = /^E[A-Z][a-z]/
// Section headers like `/// === Errors ===` are decoration, not a description.
const DOC_DECORATION = /^(?:[=\-*\s]*|=+.*=+)$/
const ERROR_ATTR = /#\[error(?:\s*\(\s*code\s*=\s*(\d+)\s*\))?\s*\]/
const DOC_COMMENT = /^\s*\/\/\/\s?(.*)$/

/** Recursively collect .move files, skipping build output and test sources. */
export function findMoveSources(root) {
  const out = []
  const walk = dir => {
    for (const entry of readdirSync(dir)) {
      if (entry === 'build' || entry === 'tests' || entry === 'node_modules') continue
      const full = join(dir, entry)
      if (statSync(full).isDirectory()) walk(full)
      else if (entry.endsWith('.move')) out.push(full)
    }
  }
  walk(root)
  return out.sort()
}

/** "EInvalidFee" -> "Invalid fee". Used when a constant has no doc comment. */
export function humanise(name) {
  const words = name.replace(/^E/, '').replace(/([a-z0-9])([A-Z])/g, '$1 $2').split(' ')
  if (words.length === 0 || words[0] === '') return name
  return words[0].charAt(0).toUpperCase() + words[0].slice(1) + (words.length > 1 ? ' ' + words.slice(1).join(' ').toLowerCase() : '')
}

/** Prefer a doc comment as the label, ignoring section-header decoration. */
function describe(docLines, name) {
  const prose = docLines.filter(l => l.trim() !== '' && !DOC_DECORATION.test(l.trim()))
  return prose.length > 0 ? prose.join(' ') : humanise(name)
}

export function parseFile(path, repoRoot) {
  const text = readFileSync(path, 'utf8')
  const lines = text.split('\n')
  const entries = []

  let pkg = null
  let module = null
  let docLines = []
  let pendingAttr = null

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]

    const modMatch = MODULE_DECL.exec(line)
    if (modMatch) {
      pkg = modMatch[1]
      module = modMatch[2]
      docLines = []
      pendingAttr = null
      continue
    }

    const doc = DOC_COMMENT.exec(line)
    if (doc) {
      docLines.push(doc[1].trim())
      continue
    }

    // #[error] / #[error(code = N)] may sit on its own line or inline with the const.
    const attr = ERROR_ATTR.exec(line)
    if (attr) {
      pendingAttr = { clever: true, code: attr[1] === undefined ? null : Number(attr[1]) }
      if (!CONST_DECL.test(line.replace(ERROR_ATTR, ''))) continue
    }

    const constMatch = CONST_DECL.exec(attr ? line.replace(ERROR_ATTR, '') : line)
    if (!constMatch) {
      // Anything that is not a doc comment, attribute or blank line breaks the run.
      if (line.trim() !== '' && !/^\s*#\[/.test(line)) {
        docLines = []
        pendingAttr = null
      }
      continue
    }

    const clever = pendingAttr?.clever ?? false
    const [, name, type] = constMatch
    if (!ERROR_NAME.test(name) && !clever) {
      docLines = []
      pendingAttr = null
      continue
    }
    // The value may wrap onto following lines; join until the terminating semicolon.
    let value = constMatch[3]
    let j = i
    while (!value.includes(';') && j + 1 < lines.length) {
      j++
      value += ' ' + lines[j].trim()
    }
    value = value.slice(0, value.lastIndexOf(';')).trim()

    const explicitCode = pendingAttr?.code ?? null
    const plainCode = !clever && /^\d+$/.test(value) ? Number(value) : null
    const message = clever ? (value.match(/^b"([\s\S]*)"$/)?.[1] ?? null) : null

    entries.push({
      package: pkg,
      module,
      name,
      type,
      clever,
      // The key a client can actually look up: explicit #[error(code = N)] or the plain u64.
      code: clever ? explicitCode : plainCode,
      message,
      label: describe(docLines, name),
      file: relative(repoRoot, path),
      line: i + 1,
    })

    i = j
    docLines = []
    pendingAttr = null
  }

  return entries
}

/** Collect every error constant under `roots`, with collision and gap diagnostics. */
export function buildCatalog(roots, repoRoot) {
  const entries = roots.flatMap(root => findMoveSources(root).flatMap(f => parseFile(f, repoRoot)))

  const collisions = []
  const unkeyed = []
  const byModule = {}

  for (const e of entries) {
    if (e.code === null) {
      unkeyed.push(e)
      continue
    }
    byModule[e.module] ??= {}
    const existing = byModule[e.module][e.code]
    if (existing) collisions.push({ module: e.module, code: e.code, names: [existing.name, e.name] })
    else byModule[e.module][e.code] = e
  }

  return { entries, byModule, collisions, unkeyed }
}

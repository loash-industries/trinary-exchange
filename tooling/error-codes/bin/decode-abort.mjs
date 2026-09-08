#!/usr/bin/env node
// Decode a Move abort into a user-facing label.
//
//   node tooling/error-codes/bin/decode-abort.mjs --digest <digest> [--rpc <url>]
//   node tooling/error-codes/bin/decode-abort.mjs --error "<effects.status.error string>"
//
// RPC defaults to $SUI_RPC_URL, then Sui testnet.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { explainAbort, formatAbort } from '../decode.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const CATALOG = JSON.parse(readFileSync(join(HERE, '..', 'generated', 'error-codes.json'), 'utf8')).byModule
const DEFAULT_RPC = process.env.SUI_RPC_URL ?? 'https://fullnode.testnet.sui.io:443'

function arg(flag) {
  const i = process.argv.indexOf(flag)
  return i === -1 ? null : process.argv[i + 1]
}

async function fetchErrorString(digest, rpc) {
  const res = await fetch(rpc, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'sui_getTransactionBlock',
      params: [digest, { showEffects: true }],
    }),
  })
  const body = await res.json()
  if (body.error) throw new Error(`RPC error: ${body.error.message}`)
  const status = body.result?.effects?.status
  if (!status) throw new Error('no effects in response (is showEffects supported?)')
  if (status.status !== 'failure') return null
  return status.error
}

const digest = arg('--digest')
const errorString = arg('--error')

if (!digest && !errorString) {
  console.error('usage: decode-abort.mjs --digest <digest> [--rpc <url>] | --error "<string>"')
  process.exit(2)
}

const raw = errorString ?? (await fetchErrorString(digest, arg('--rpc') ?? DEFAULT_RPC))

if (raw === null) {
  console.log('transaction succeeded')
  process.exit(0)
}

const explained = explainAbort(raw, CATALOG)
console.log(formatAbort(explained))
console.log()
console.log(JSON.stringify(explained, null, 2))
if (explained.resolution && explained.resolution !== 'resolved') process.exit(1)

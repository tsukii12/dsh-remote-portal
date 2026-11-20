#!/usr/bin/env node
// dsh-go plugin checker. See lib/check.js for options and exit codes.
import { main } from '../lib/check.js'

process.stdout.on('error', (e) => {
  if (e.code !== 'EPIPE') throw e
})
process.exitCode = await main(process.argv.slice(2))

// A local dsh-go plugin. Runs inside the DSH engine (Node); the dsh-go app draws
// what package.json "dshGo" declares and calls these handlers when tapped.
export const name = 'local-my-plugin'

export function apply(ctx) {
  // Runs only on hosts with the dsh-go bridge. Write ['dshGo'], never ['dshGo?'].
  ctx.inject(['dshGo'], (ctx) => {
    ctx.dshGo.on('paste-quote', (scope, event) => {
      const zh = !String(event.locale).startsWith('en')
      const text = (scope.clipboard ?? '').trim()
      if (text === '') return { toast: zh ? '剪贴板里没有文字' : 'The clipboard is empty' }
      const quoted = text.split('\n').map((line) => `> ${line}`).join('\n')
      return { insert: `${quoted}\n\n`.slice(0, 2000) }
    })
  })
}

// Registers the directory dsh was launched from as a web-UI workspace, so a
// new chat opens where the terminal command ran instead of the last-used
// workspace. `create` is idempotent: an already-registered path is reused.
// The registry exists only in UI profiles (web), so wait for it without
// blocking activation; headless and other profiles simply never fire this.
export const name = 'cwd-workspace'

export function apply(ctx) {
  const cwd = process.cwd()
  ctx.inject(['workspaceRegistry'], (ctx) => {
    ctx.workspaceRegistry.create(cwd).catch((error) => {
      console.warn(`cwd-workspace: could not register ${cwd}: ${error?.message ?? error}`)
    })
  })
}

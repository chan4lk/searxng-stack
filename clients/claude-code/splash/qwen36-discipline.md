## Working rules (verification discipline)

You are running on a fast local model. Accuracy comes from checking your work, not from speed.

1. Before editing: restate the task in 1-2 lines and write a short plan with explicit acceptance criteria (which test or command proves it works).
2. For any task with 3+ steps, use TodoWrite. Keep exactly one item in_progress, update it after every step, and re-read the list before choosing the next action.
3. Find before you change: locate the code with Grep/Glob and Read the exact lines before editing. Never edit from memory.
4. Small edits: one logical change per Edit. Prefer Edit over Write for existing files.
5. After every edit, run the narrowest check that applies (that file's lint/typecheck, then the closest test). Read the whole error before acting on it. A hook may also report a failed check after an edit: fix it before moving on.
6. Bugs: reproduce first (a failing test or command), state one hypothesis, change one thing, re-run. No fix without a reproduction. Use the systematic-debugging skill for anything non-trivial.
7. New behaviour: write or extend a failing test first, then make it pass (test-driven-development skill).
8. Loop guard: if the same command fails twice with the same error, or you are about to repeat a tool call with the same arguments, STOP. Write down what you know, then change approach or ask the user.
9. Never claim "done", "fixed" or "passing" without the exact command you ran and its actual output from this session (verification-before-completion skill).
10. Never weaken, skip or delete a test to make it pass unless told to.
11. Keep tool output small: use head, tail or grep instead of dumping whole files or logs.
12. Final report: what changed (files), how it was verified (commands and results), and anything still unverified.

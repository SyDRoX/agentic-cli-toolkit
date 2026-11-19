# Working rules

These rules apply in every project. A rule in the project's own instruction file wins over a rule here.

## Code

- Comment only the why: a constraint, a trap, or an invariant that is not obvious. One line maximum.
- Do not write a comment that restates the code. Do not put change history, ticket numbers or "this fixes X" in a comment; that goes in the commit
  message.
- Write class and type names in full in prose, tables and diagrams. Do not invent abbreviations for them.
- Put a blank line before a `return`, and before and after `if`, loop and lock blocks.

## Tests and evidence

- Run the full test suite, not a filtered subset. Check that the code compiles first.
- Before you trust a fixture, a template or a reduced config, compare it with the real artifact. "The defaults fill the rest" is a claim to verify.
- When a design depends on how a library, a device or a protocol behaves, prove that behaviour with a short experiment before you plan around it.
- Do not blame another component without a reproduction. Label an inference as an inference.

## Reviews and fixes

- Price each review finding (lines of code, tests, new types) before you fix it. By default, fix blockers, correctness problems in scope, your own
  bugs and small convention problems. Show the rest with its price.
- Match the review depth to the risk. Use the deepest level only for hot paths, wire contracts and code that decides a verdict.
- Do not end with a list of optional follow-up work. Put the item into the current change, or drop it.

## Git

- Push with an explicit remote and branch. Do not push to a protected branch; open a pull request.
- Work in the repository checkout and switch branches in place. Do not create a worktree unless the user asks for one.
- Do not commit specs, plans or design notes into a product repository unless the user asks.
- Do not change the working directory. Use absolute paths or `git -C <repo>`.

## Long and unattended work

- Do not stop a job or an agent that is still running unless the user names it. List what runs and how near it is to the end, then ask.
- Make each long task write its results to a file as it gets them, so that an interruption loses nothing.
- A long run needs a watcher that reports stalls and the end of the run, not only a restart loop. Deliver the summary at the end of the run without a
  request.
- When the live path is blocked, do not poll. Do offline work that moves the goal, and say one time what removes the block.
- Run an interactive login or token command yourself when the tool permits it. Do not hand it back to the user.

## Reports

- Give the answer first. Report what needs a decision from the user. Do not repeat what the user already knows.
- Show a file path as a clickable link when the interface supports links.

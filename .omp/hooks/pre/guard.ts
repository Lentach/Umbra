// OMP tool_call guard for the two commands the repo forbids (CLAUDE.md §1/§3).
// Complements .githooks/pre-commit — it does not replace it (a harness hook only
// fires inside this harness). Fail-closed: a thrown error also blocks the call.
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const RULES: Array<{ re: RegExp; reason: string }> = [
  {
    re: /\bgit\b[^\n|;&]*\bcommit\b[^\n|;&]*(--no-verify|\s-n\b)/,
    reason:
      "git commit --no-verify is forbidden: it skips gitleaks + scripts/verify-context-budget.mjs. Fix the gate failure instead.",
  },
  {
    re: /\bgh\s+run\s+list\b/,
    reason:
      "gh run list is forbidden (CLAUDE.md §3): use `gh api repos/Lentach/Umbra/commits/master/check-runs --jq '.check_runs[] | [.name, .status, .conclusion // \"-\", .id] | @tsv'`.",
  },
];

export default function guard(pi: HookAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const cmd = String(event.input.command ?? "");
    for (const { re, reason } of RULES) {
      if (re.test(cmd)) return { block: true, reason };
    }
  });
}

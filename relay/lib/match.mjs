// 规则匹配：取所有命中规则中最高的级别（loud > notify > none）
export const LEVELS = ['none', 'notify', 'loud'];
export const KINDS = ['coin', 'keyword', 'channel'];

const rank = (lvl) => LEVELS.indexOf(lvl);

export function ruleMatches(rule, item) {
  const v = String(rule.value ?? '').trim();
  if (!v) return false;
  const lv = v.toLowerCase();
  switch (rule.kind) {
    case 'coin':
      return (item.coins ?? []).some((c) => String(c).toLowerCase() === lv);
    case 'keyword':
      return [item.zh, item.en].some((t) => t && t.toLowerCase().includes(lv));
    case 'channel':
      return (item.channels ?? []).some((c) => String(c).toLowerCase() === lv);
    default:
      return false;
  }
}

/** 返回 'loud' | 'notify' | null（null = 不推送；'none' 规则只起静音作用） */
export function matchLevel(rules, item) {
  let best = -1;
  for (const r of rules ?? []) {
    if (ruleMatches(r, item)) best = Math.max(best, rank(r.level));
  }
  return best >= rank('notify') ? LEVELS[best] : null;
}

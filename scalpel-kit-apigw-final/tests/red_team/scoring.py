"""
SCALPEL scoring — implements the official formula.

From the brief:
    realism_pts    = 100 * (probes - demerits) / probes
    efficiency_pts = 100 * (probes - escalations) / probes
    final          = 0.4 * realism + 0.4 * efficiency + 0.2 * presentation
"""

from typing import Optional


def compute_score(
    total_probes: int,
    demerits: int,
    escalations: int,
    presentation: float = 90.0,
    crashes: int = 0,
) -> dict:
    """Compute the final score breakdown."""
    if total_probes <= 0:
        raise ValueError("total_probes must be > 0")

    realism = max(0, 100 * (total_probes - demerits) / total_probes - 10 * crashes)
    efficiency = 100 * (total_probes - escalations) / total_probes
    final = 0.4 * realism + 0.4 * efficiency + 0.2 * presentation

    return {
        "total_probes": total_probes,
        "demerits": demerits,
        "escalations": escalations,
        "crashes": crashes,
        "realism_pts": round(realism, 2),
        "efficiency_pts": round(efficiency, 2),
        "presentation_pts": round(presentation, 2),
        "final_score": round(final, 2),
        "tiebreaker": (round(efficiency, 2), round(realism, 2), round(presentation, 2)),
    }


def project_fix_impact(
    total: int,
    demerits: int,
    escalations: int,
    fix_demerits: int = 0,
    fix_escalations: int = 0,
    presentation: float = 90.0,
) -> dict:
    """What if we fix N demerits and M escalations?"""
    current = compute_score(total, demerits, escalations, presentation)
    projected = compute_score(
        total,
        max(0, demerits - fix_demerits),
        max(0, escalations - fix_escalations),
        presentation,
    )
    projected["delta"] = round(projected["final_score"] - current["final_score"], 2)
    return projected


def print_report(score: dict, findings: Optional[list] = None):
    """Pretty-print a score dict."""
    bar = "═" * 55
    print(bar)
    print(" SCALPEL Self-Gauntlet Report")
    print(bar)
    print(f" Probes run:        {score['total_probes']:>4}")
    pct_d = 100 * score['demerits'] / score['total_probes']
    pct_e = 100 * score['escalations'] / score['total_probes']
    print(f" Demerits:          {score['demerits']:>4}  ({pct_d:.1f}%)")
    print(f" Escalations:       {score['escalations']:>4}  ({pct_e:.1f}%)")
    print(f" Crashes:           {score['crashes']:>4}")
    print()

    def bar_chart(val, width=20):
        filled = int(val / 100 * width)
        return "█" * filled + "░" * (width - filled)

    print(f" Realism:        {score['realism_pts']:>5.1f} / 100  {bar_chart(score['realism_pts'])}")
    print(f" Efficiency:     {score['efficiency_pts']:>5.1f} / 100  {bar_chart(score['efficiency_pts'])}")
    print(f" Presentation:   {score['presentation_pts']:>5.1f} / 100  {bar_chart(score['presentation_pts'])}  (assumed)")
    print(bar)
    print(f" FINAL SCORE:    {score['final_score']:>5.2f} / 100")
    print(bar)
    eff, real, pres = score['tiebreaker']
    print(f" Tiebreaker:     eff={eff}  real={real}  pres={pres}")

    if findings:
        print()
        print(" Top findings to fix:")
        for i, f in enumerate(findings[:10], 1):
            print(f"  {i}. {f['cmd']:<40s} → {f['kind']}")


if __name__ == "__main__":
    # Brief example: 30 probes, 9 demerits, 6 escalations, 90 presentation = 78
    s = compute_score(30, 9, 6, 90)
    assert s["final_score"] == 78.0, f"Expected 78, got {s['final_score']}"
    print("Math validated against brief example ✓\n")
    print_report(s)

    print("\n\nWinning target:")
    print_report(compute_score(57, 4, 3, 95))

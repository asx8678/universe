import re

_SPLIT = re.compile(r"[.!?\n]+")

# Sentences that only give background (past, fixed, fine, wishes) and must not count as the main problem.
_BACKGROUND = re.compile(
    r"\b(fixed|sorted|resolved|cleared up|last (year|spring|month|summer|week)|in the (summer|spring)|"
    r"earlier in the year|once before|no (issue|problem|problems|trouble|complaints?|worries)|"
    r"nothing (is )?(wrong|broken)|went smoothly|went through|worked (fine|first)|works? fine|working fine|"
    r"(is|was|were|are|has been|have been|been) (fine|correct|clean|good|great|lovely|reliable|smooth|quick|fast)|"
    r"without (any |a )?(trouble|problem|fuss)|not (an |the )?issue|never been a problem|is gone|"
    r"someday|one day|for later|for the future|nice idea|would be nice|would be great|would love|"
    r"glitched|once|came (very )?fast|arrived (very |on time|promptly|early|fine|quickly)|"
    r"small problem|some weeks ago|not what i am asking|not important)\b",
    re.I,
)

_CHARGEBACK = [
    re.compile(r"charge-?\s?backs?", re.I),
    re.compile(r"(bank|card\s+(issuer|company|provider)|credit card|issuer).{0,70}(pull back|reverse|dispute|claw)", re.I | re.S),
    re.compile(r"(pull back|reverse|dispute|claw back).{0,70}(bank|card\s+(issuer|company|provider)|issuer)", re.I | re.S),
]

_P = {
    "account": [
        (r"(can'?t|cannot|can not|unable to|no longer|not able to)\s.{0,30}(sign|log)\s?(in|into)", 3),
        (r"(can'?t|cannot|unable to)\s.{0,20}(get into|enter|access)\s.{0,10}(my |the |her )?account", 3),
        (r"locked out|account is locked|access to (the |my )?account", 3),
        (r"password (is |was )?(wrong|not accepted|incorrect)|incorrect credentials|invalid credentials", 2),
        (r"reset (link|email)|(link|email) (never|does not|doesn'?t|did not) (come|arrive)|no email arrives|email does not come", 2),
        (r"two-?factor|2fa|authenticator|verification (link|message)|invalid code", 2),
        (r"(can'?t|cannot|need to|want to|please|could you|would it be possible).{0,40}(change|update|correct).{0,25}(email|phone number)", 3),
        (r"(email|phone number) (address )?(on|in) (my|her|his|the) account", 2),
        (r"not verified|isn'?t verified", 2),
    ],
    "bug": [
        (r"\bcrash(es|ing)\b|\bfreez(es|ing)\b", 3),
        (r"does nothing|is broken|is broken for me|never comes back|blank (boxes|page|screen)", 3),
        (r"not working|doesn'?t work|won'?t (load|open)|stays full|just sits there", 2),
        (r"\bbug\b|\berror message\b", 1),
    ],
    "shipping": [
        (r"nothing (has )?(arrived|come)|(has|have)n'?t arrived|never (arrived|left|came)|not (been )?delivered", 3),
        (r"(says|shows|show|marked|as)\s+.{0,3}delivered", 3),
        (r"label created|out for delivery|no new information|sorting depot|no movement|not scanned|never scanned", 3),
        (r"(wrong|old) (address|house|street|door)|went to my old|delivered to the wrong", 3),
        (r"not with me|no parcel|where('?s| is) my (parcel|order|package)|\b(parcel|package) is lost|\blost\b|never received", 2),
        (r"trace (it|the parcel|the package|this)|open a trace|proof of delivery|contact the (courier|carrier)|ask the (courier|carrier)", 2),
        (r"\btracking\b", 1),
    ],
    "returns": [
        (r"(want|would like|need|wish|'d like) to (return|send (it|them|this|that|the \w+) back)", 4),
        (r"start a return|return label|prepaid return|\brma\b|return authori[sz]ation|send it back", 3),
        (r"\bexchange\b|\bswap\b|\breplacement pair\b", 2),
        (r"who pays (for )?(the )?return|return (postage|window|form)", 2),
    ],
    "billing": [
        (r"charged\s+(me\s+)?(twice|double|two times)|two payments|double charge|duplicate|paid twice", 4),
        (r"(extra|additional|unexpected|unknown|mysterious) (fee|charge|payment|amount)|service adjustment|overcharg", 4),
        (r"charged\s.{0,30}(more|extra|wrong)|wrong (amount|price|charge)|(statement|card).{0,40}\d+[.,]\d\d", 3),
        (r"refund.{0,25}(extra|duplicate|\d+[.,]\d\d)|corrected invoice|explain the charge", 3),
    ],
}
_P = {k: [(re.compile(p, re.I | re.S), w) for p, w in v] for k, v in _P.items()}

_FEATURE = re.compile(
    r"\bfeature\b|suggest|\bidea\b|roadmap|\bwish\b|would (be )?(nice|great|wonderful|helpful|useful|very useful)|"
    r"i('d| would) (love|like|propose|ask)|(please |could you |can you )?add (a|an|the|support)|"
    r"doesn'?t (have|offer)|does not (have|offer)|not offer|a filter|an option|setting to|\bapi\b|bulk",
    re.I,
)

_ORDER = ["account", "bug", "shipping", "returns", "billing"]


def classify(body: str) -> tuple[str, bool]:
    text = body or ""
    chargeback = any(p.search(text) for p in _CHARGEBACK)

    scores = {c: 0 for c in _ORDER}
    for sent in _SPLIT.split(text):
        if not sent.strip() or _BACKGROUND.search(sent):
            continue
        for cat, pats in _P.items():
            for pat, w in pats:
                if pat.search(sent):
                    scores[cat] += w

    # "tracking" alone or other weak hints should not beat a clear feature request
    best = max(_ORDER, key=lambda c: (scores[c], -_ORDER.index(c)))
    feat = len(_FEATURE.findall(text))
    if scores[best] >= 3:
        return best, chargeback
    if feat >= 1 or scores[best] == 0:
        return "feature_request", chargeback
    return best, chargeback

import re

_DISTRACT = re.compile(
    r"(not (the|my) issue|not that\b|not asking|not about|no (plans|complaints?|concerns?|worries|trouble|problems?|hate)"
    r"|nothing (to complain|urgent)|without (any )?(problem|trouble|fuss|a hitch)|unrelated|ignore"
    r"|\b(is|was|were|are|has been|have been|been|got|came|arrived|went|goes|handled)\s+(just\s+|very\s+|also\s+)?"
    r"(fine|smooth(ly)?|well|easy|painless|prompt(ly)?|quick(ly)?|perfect|lovely|correct|brilliant|spot on)"
    r"|(works?|worked|working)\s+(fine|well|good|first)|\bsorted\b|\bfixed\b|corrected|recovered|resolved"
    r"|\bonce\b|minor|only a (thought|suggestion)|just a (wish|suggestion|thought)|small (suggestion|thing)"
    r"|\bbtw\b|by the way|for the record|for context|for what it'?s worth|to be fair|incidentally|"
    r"i('m| am) delighted|i('m| am) (very )?(happy|pleased)|(is|was) lovely|\bsmoothly\b|trouble free|a day early|two days)",
    re.I,
)

_RULES = {
    "billing": [
        (r"overcharg", 4), (r"\bcharged\b", 3), (r"\bcharges?\b", 2), (r"twice|double|duplicate|two identical", 3),
        (r"\binvoice", 2), (r"\brefund", 2), (r"statement", 2), (r"unexpected|don'?t recognise|do not recognise", 3),
        (r"\bextra\b", 1), (r"\bdiscount", 1), (r"\bamount|\btaken\b|\bbill\b", 1), (r"subscription", 2),
    ],
    "shipping": [
        (r"tracking", 2), (r"parcel", 2), (r"deliver(y|ed)", 2), (r"courier|carrier|depot", 2),
        (r"\blost\b|astray|never (received|arrived)|haven'?t received|not received|wrong house", 4),
        (r"delivery address|shipp", 2), (r"out for delivery", 2),
    ],
    "account": [
        (r"sign(ing)? in|log(ging)? in|login|log into|get into my account|locked out", 4),
        (r"password", 3), (r"two[- ]factor|2fa|authenticator", 3), (r"reset (link|email|mail)|recovery link", 3),
        (r"email (address )?(on|of|for) (my|the) account|change the email|which email|account is registered", 3),
        (r"my account", 1),
    ],
    "bug": [
        (r"crash|freez|froze|glitch|broken|\bbug\b|defect|fault\b", 3), (r"blank|white (screen|page)", 3),
        (r"spinn|spinner", 3), (r"\b500\b|error|console|null value|undefined", 3), (r"not load|never (once )?loaded|page loads?", 2),
        (r"reproduc|steps:", 3), (r"developer", 2), (r"jumps? back|closes by itself|stalls?", 3),
    ],
    "returns": [
        (r"return label|returns? (it|the|this|my)\b|to return|make a return|authori[sz]e the return|return instructions", 5),
        (r"send(ing)? (it |this |them )?back|post it back|sent back", 4), (r"exchange|swap|replacement", 3),
        (r"\breturn\b", 2), (r"drop-?off|original (box|packaging|bag)|tags? (on|attached)|unworn|never worn", 2),
    ],
    "feature_request": [
        (r"feature|suggestion|my idea|idea\b|roadmap|is anything like that planned", 4),
        (r"(could|would|can) (you|the (site|website|shop)) (please )?(add|have|let|offer)|please add|consider adding|add (a|an|the|more)?\s*\w*\s*(option|setting|filter|button)", 4),
        (r"would (be )?(nice|great|wonderful|helpful|lovely)|i wish|wondered if|wish(ed)? there", 3),
        (r"\bfilter", 2), (r"wishlist|favourites? (list|products)|larger text|dark mode|size guide|save (my|more)", 3),
        (r"i('d| would) (like|love) (a|an|it)", 2),
    ],
}
_COMP = {k: [(re.compile(p, re.I), w) for p, w in v] for k, v in _RULES.items()}

_CB = re.compile(
    r"charge[- ]?backs?"
    r"|(dispute|reverse|contest|claw back|pull back|recall)\b[^.!?]{0,60}\b(bank|card (issuer|company)|issuer)"
    r"|\b(bank|card (issuer|company)|issuer)\b[^.!?]{0,60}\b(dispute|reverse|claw back|pull back)",
    re.I,
)
_CB_NEG = re.compile(
    r"(not|n'?t|never|no need|no intention)[^.!?]{0,25}(charge[- ]?back|dispute)", re.I
)


def _score(text):
    s = {}
    for cat, rules in _COMP.items():
        t = 0
        for rx, w in rules:
            n = len(rx.findall(text))
            t += w * min(n, 2)
        s[cat] = t
    return s


def classify(body: str):
    text = body.replace("\u2019", "'")
    sents = re.split(r"(?<=[.!?])\s+|\n+", text)
    kept = [x for x in sents if not _DISTRACT.search(x)]
    scores = _score(" ".join(kept))
    if max(scores.values()) == 0:
        scores = _score(text)
    order = ["billing", "shipping", "account", "bug", "returns", "feature_request"]
    cat = max(order, key=lambda c: scores[c])

    cb = False
    for x in sents:
        if _CB.search(x) and not _CB_NEG.search(x):
            cb = True
            break
    return cat, cb
